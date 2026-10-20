import Foundation
import CoreBluetooth
import Combine
// MARK: - Connection

@MainActor
final class RingConnection: NSObject, ObservableObject {

    enum State: Equatable {
        case poweredOff, idle, scanning, connecting, connected
        case failed(String)

        var label: String {
            switch self {
            case .poweredOff:    return "Bluetooth off"
            case .idle:          return "Not connected"
            case .scanning:      return "Looking for ring…"
            case .connecting:    return "Waiting for ring…"
            case .connected:     return "Connected"
            case .failed(let m): return "Failed: \(m)"
            }
        }
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
        let isOutgoing: Bool
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var battery: BatteryState?
    @Published private(set) var log: [LogLine] = []
    /// What the ring is currently logging on its own, keyed by kind.
    @Published private(set) var monitoring: [String: MonitoringSetting] = [:]

    var onRealtimeSample: ((RealtimeSample) -> Void)?
    var onBigDataMessage: ((UInt8, [UInt8]) -> Void)?
    var onHistory: ((HistorySeries) -> Void)?
    var onSteps: ((StepsReply) -> Void)?
    var onHeartRateLog: ((HeartRateLogReply) -> Void)?
    /// Fires once the ring is connected and ready for commands.
    var onReady: (() -> Void)?
    /// Fires for any packet from the ring — in the background, each one is a
    /// brief chance to run.
    var onActivity: (() -> Void)?

    /// When the last big-data notification arrived, and which message types
    /// have come in since the last request — so a sync can wait for a reply
    /// to finish instead of guessing.
    private(set) var lastBigDataActivity = Date.distantPast
    private(set) var bigDataTypesReceived: Set<UInt8> = []

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var uartWrite: CBCharacteristic?
    private var bigDataWrite: CBCharacteristic?
    private let framer = BigDataFramer()
    private let history = HistoryAssembler()
    private let steps = StepsAssembler()
    private let heartRateLog = HeartRateLogAssembler()
    private var scanTimeout: Task<Void, Never>?

    private var knownID: UUID? {
        get { UserDefaults.standard.string(forKey: "ringPeripheralID").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "ringPeripheralID") }
    }

    static let restoreID = "com.aniketh.RingApp.central"

    override init() {
        super.init()
        // State restoration: if iOS ends the app in the background, it keeps
        // the pending connection and relaunches the app when the ring comes
        // back, instead of the connection dying with the process.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID])
    }

    // MARK: Public

    var isConnected: Bool { state == .connected }

    /// Connect unless a connection is already up or pending.
    func connectIfNeeded() {
        if let p = peripheral, p.state == .connected || p.state == .connecting { return }
        connect()
    }

    func connect() {
        guard central.state == .poweredOn else { state = .poweredOff; return }
        if let p = peripheral, p.state == .connected || p.state == .connecting { return }

        // Paired before: go straight to the handle, no scan at all.
        if let id = knownID,
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            note("reconnecting to saved ring")
            attach(known); return
        }
        let service = CBUUID(string: RingUUID.uartService)
        if let live = central.retrieveConnectedPeripherals(withServices: [service]).first {
            note("ring already held by iOS")
            attach(live); return
        }

        // First pair only. The scan is unfiltered because this ring does not
        // advertise its service UUIDs — a filtered scan never sees it, which is
        // why it only appeared after QRing had connected once.
        note("scanning")
        state = .scanning
        central.scanForPeripherals(withServices: nil)

        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.state == .scanning else { return }
            self.central.stopScan()
            self.state = .failed("ring not found — close QRing and try again")
            self.note("scan timed out")
        }
    }

    func forget() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        knownID = nil
        peripheral = nil
        state = .idle
    }

    func send(_ data: Data) {
        guard let p = peripheral, let ch = uartWrite else { return }
        note(hex(data), outgoing: true)
        p.writeValue(data, for: ch, type: .withoutResponse)
    }

    func send(_ command: UARTCommand, payload: [UInt8] = []) {
        send(UARTPacket.make(command, payload: payload))
    }

    func syncTime()       { send(.setTime, payload: UARTPacket.setTimePayload()) }
    func requestBattery() { send(.battery) }

    /// Pull the ring's own logged HRV series. No live capture needed — this is
    /// what makes overnight streaming optional.
    func requestHRVHistory(dayOffset: Int = 0) {
        history.reset()
        send(.hrvHistory, payload: historyRequest(dayOffset))
    }

    func requestStressHistory(dayOffset: Int = 0) {
        history.reset()
        send(.stressHistory, payload: historyRequest(dayOffset))
    }

    /// The same shape the steps request uses; the ring ignores the tail but
    /// this is what the validated client sends.
    private func historyRequest(_ dayOffset: Int) -> [UInt8] {
        [UInt8(max(0, min(6, dayOffset))), 0x0F, 0x00, 0x5F, 0x01]
    }

    /// One day of the ring's 5-minute heart rate log.
    func requestHeartRateLog(daysAgo: Int = 0) {
        guard let midnight = DayKey.midnight(daysAgo: daysAgo) else { return }
        heartRateLog.begin(day: midnight)
        let stamp = UInt32(midnight.timeIntervalSince1970)
        send(.heartRateLog, payload: [UInt8(stamp & 0xFF), UInt8(stamp >> 8 & 0xFF),
                                      UInt8(stamp >> 16 & 0xFF), UInt8(stamp >> 24 & 0xFF)])
    }

    /// One day of 15-minute step buckets.
    func requestSteps(dayOffset: Int = 0) {
        steps.reset()
        send(.steps, payload: [UInt8(max(0, min(6, dayOffset))), 0x0F, 0x00, 0x5F, 0x01])
    }

    /// Hands over a reply whose last row never arrived.
    func finishSteps() {
        if let partial = steps.drain() { onSteps?(partial) }
    }

    /// Logging interval for the ring's internal heart-rate log, 1–255 minutes.
    /// Defaults to 5; lowering it gives finer data at some battery cost.
    func setHeartRateLogInterval(minutes: Int) {
        send(.hrLogSettings, payload: [0x02, 0x01, UInt8(max(1, min(255, minutes)))])
    }

    /// Read what the ring is currently logging. Replies land on `onSetting`.
    func readMonitoring(_ kind: MonitoringKind) {
        send(kind.command, payload: [0x01])
    }

    func readAllMonitoring() {
        for kind in MonitoringKind.allCases { readMonitoring(kind) }
    }

    /// Change what the ring logs on its own. These persist on the ring, so the
    /// history commands return data whether or not this app ever connects.
    func setMonitoring(_ kind: MonitoringKind, enabled: Bool, intervalMinutes: Int) {
        send(kind.command,
             payload: [0x02, enabled ? 1 : 0, UInt8(max(1, min(255, intervalMinutes)))])
        // Read back so the UI reflects what the ring actually accepted rather
        // than what we asked for — these command IDs are inferred for all but HR.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.readMonitoring(kind)
        }
    }

    func startRealtime(_ s: RealtimeSubtype) {
        send(.realtimeStart, payload: [s.rawValue, RealtimeAction.start.rawValue])
    }
    func keepRealtimeAlive(_ s: RealtimeSubtype) {
        send(.realtimeStart, payload: [s.rawValue, RealtimeAction.keepGoing.rawValue])
    }
    func stopRealtime(_ s: RealtimeSubtype) {
        send(.realtimeStop, payload: [s.rawValue, 0, 0])
    }

    func requestBigData(_ type: UInt8, payload: [UInt8] = []) {
        guard let p = peripheral, let ch = bigDataWrite else { return }
        framer.reset()
        bigDataTypesReceived.removeAll()
        let frame = payload.isEmpty ? BigData.read(type) : BigData.request(type, payload: payload)
        note("BD \(hex(frame))", outgoing: true)
        p.writeValue(frame, for: ch, type: .withoutResponse)
    }

    func requestBigData(_ type: BigDataType, payload: [UInt8] = []) {
        requestBigData(type.rawValue, payload: payload)
    }

    func clearLog() { log.removeAll() }

    // MARK: Internals

    private func attach(_ p: CBPeripheral) {
        scanTimeout?.cancel()
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    fileprivate func note(_ text: String, outgoing: Bool = false) {
        log.append(LogLine(time: Date(), text: text, isOutgoing: outgoing))
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
}

// MARK: - CBCentralManagerDelegate

extension RingConnection: CBCentralManagerDelegate {

    /// iOS relaunched the app for the ring and hands back the peripheral.
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
        Task { @MainActor in
            guard let p = restored else { return }
            self.note("restored by iOS")
            self.peripheral = p
            p.delegate = self
            self.state = .connecting
            if p.state == .connected {
                p.discoverServices([CBUUID(string: RingUUID.uartService),
                                    CBUUID(string: RingUUID.bigDataService)])
            } else {
                central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.note("bluetooth ready")
                self.connect()
            case .poweredOff:
                self.state = .poweredOff
            default:
                self.state = .idle
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        // Cheap synchronous filter — the scan is unfiltered, so most of what
        // arrives here is someone else's earbuds.
        guard let name = peripheral.name?.uppercased(),
              name.contains("R02") || name.contains("COLMI") else { return }

        Task { @MainActor in
            central.stopScan()
            self.scanTimeout?.cancel()
            self.note("discovered \(peripheral.name ?? "ring")")
            self.knownID = peripheral.identifier
            self.attach(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.note("connected, discovering services")
            peripheral.discoverServices([CBUUID(string: RingUUID.uartService),
                                         CBUUID(string: RingUUID.bigDataService)])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        // Don't stop at a failure — queue the connection again. A pending
        // connect costs nothing until the ring answers.
        Task { @MainActor in
            self.note("connect failed (\(error?.localizedDescription ?? "unknown")) — retrying")
            self.state = .connecting
            try? await Task.sleep(for: .seconds(3))
            guard central.state == .poweredOn, peripheral.state != .connected else { return }
            central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.note("disconnected — queued for reconnect")
            self.uartWrite = nil
            self.bigDataWrite = nil
            // iOS holds this pending indefinitely and fires the moment the ring
            // advertises again.
            central.connect(peripheral, options: nil)
            self.state = .connecting
        }
    }
}

// MARK: - CBPeripheralDelegate

extension RingConnection: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        for ch in service.characteristics ?? [] {
            switch ch.uuid.uuidString.uppercased() {
            case RingUUID.uartNotify, RingUUID.bigDataNotify:
                peripheral.setNotifyValue(true, for: ch)
            case RingUUID.uartWrite:
                Task { @MainActor in self.uartWrite = ch }
            case RingUUID.bigDataWrite:
                Task { @MainActor in self.bigDataWrite = ch }
            default: break
            }
        }
        Task { @MainActor in
            guard self.uartWrite != nil, self.state != .connected else { return }
            self.state = .connected
            self.note("ready")
            self.syncTime()
            self.requestBattery()
            self.readAllMonitoring()
            self.onReady?()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        let isBigData = characteristic.uuid.uuidString.uppercased() == RingUUID.bigDataNotify

        Task { @MainActor in
            self.note((isBigData ? "BD " : "") + self.hex(data))

            defer { self.onActivity?() }

            if isBigData {
                self.lastBigDataActivity = Date()
                // One reply can carry several messages; type 0x25 sends one per day.
                for message in self.framer.feed(data) {
                    self.bigDataTypesReceived.insert(message.type)
                    self.onBigDataMessage?(message.type, message.payload)
                }
                return
            }

            if let series = self.history.feed(data) {
                self.onHistory?(series)
                return
            }
            if data.first == UARTCommand.heartRateLog.rawValue {
                if let reply = self.heartRateLog.feed(data) { self.onHeartRateLog?(reply) }
                return
            }
            if data.first == UARTCommand.steps.rawValue {
                if let reply = self.steps.feed(data) { self.onSteps?(reply) }
                return
            }
            if let setting = MonitoringSetting(packet: data) {
                self.monitoring[setting.kind.label] = setting
                return
            }
            if let battery = BatteryState(packet: data) {
                self.battery = battery
                return
            }
            if let sample = RealtimeSample(packet: data), sample.isUsable {
                self.onRealtimeSample?(sample)
            }
        }
    }
}

// MARK: - Capture

/// Live streaming, now optional: HRV and stress come from the ring's own logs.
/// It backs the on-demand features — Live heart rate, unguided sessions and
/// workout heart rate — plus RR intervals, which the ring never stores.
@MainActor
final class RingCapture: ObservableObject {

    /// What is streaming right now, if anything.
    @Published private(set) var activeKind: CaptureSession.Kind?
    @Published private(set) var isOvernight = false
    @Published private(set) var liveHeartRate: Int?
    @Published private(set) var liveRR: [Int] = []
    @Published private(set) var liveHeartRates: [Int] = []
    /// The latest SpO₂ or stress value while one of those is being measured.
    @Published private(set) var liveValue: Int?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var status = "Idle"

    var isCapturing: Bool { activeKind != nil }

    var windowSeconds: TimeInterval = 180
    var gapSeconds: TimeInterval = 720

    /// Live heart rate holds for ten seconds, as Oura's does, and gives up
    /// after thirty if the ring never locks on.
    static let spotCheckSeconds: TimeInterval = 10
    static let spotCheckTimeout: TimeInterval = 30

    private let ring: RingConnection
    private let store: RingStore
    private let health: HealthService?
    private var task: Task<Void, Never>?
    private var collectedRR: [Int] = []
    private var collectedHR: [Int] = []
    private var collectedValues: [Int] = []
    private var activeSubtype: RealtimeSubtype = .healthCheck
    private var droppedFirst = false
    private var finishRequested = false

    init(ring: RingConnection, store: RingStore, health: HealthService? = nil) {
        self.ring = ring
        self.store = store
        self.health = health
        ring.onRealtimeSample = { [weak self] sample in self?.ingest(sample) }
    }

    private func ingest(_ sample: RealtimeSample) {
        // The first value after starting a SpO2 stream is a stale heart-rate
        // packet bleeding through the queue.
        if activeSubtype == .spo2 && !droppedFirst {
            droppedFirst = true
            return
        }
        guard sample.subtype == activeSubtype.rawValue else { return }

        // SpO₂ and stress: one value per packet, nothing else to collect.
        if activeSubtype == .spo2 || activeSubtype == .stressHRV {
            if let value = sample.reading {
                collectedValues.append(value)
                liveValue = value
            }
            return
        }

        if let rr = sample.rrMs {
            collectedRR.append(rr)
            liveRR = Array(collectedRR.suffix(60))
        }
        // Heart rate from the packet when it carries one; otherwise from the
        // beats themselves. The health-check stream only sends beats, which is
        // why Live heart rate used to finish with beats and RMSSD but no bpm.
        var bpm: Int?
        if activeSubtype == .heartRate, let value = sample.reading, value > 30, value < 220 {
            bpm = value
        } else if sample.rrMs != nil {
            let recent = HRV.clean(Array(collectedRR.suffix(8))).map(Double.init)
            if recent.count >= 3 {
                let derived = Int((60_000 / HRV.median(recent)).rounded())
                if derived > 30 && derived < 220 { bpm = derived }
            }
        }
        if let bpm {
            collectedHR.append(bpm)
            liveHeartRates = collectedHR
            liveHeartRate = bpm
        }
    }

    /// Streams until `duration` passes or `finish()` is called, then saves
    /// what was recorded. Returns nil if the ring gave nothing usable.
    @discardableResult
    func record(_ kind: CaptureSession.Kind,
                duration: TimeInterval? = nil,
                activity: String? = nil,
                subtype: RealtimeSubtype = .healthCheck) async -> CaptureSession? {
        guard ring.isConnected, activeKind == nil else { return nil }
        activeKind = kind
        activeSubtype = subtype
        droppedFirst = false
        finishRequested = false
        collectedRR.removeAll()
        collectedHR.removeAll()
        liveRR = []
        liveHeartRates = []
        liveHeartRate = nil
        elapsed = 0
        status = kind == .spotCheck ? "Measuring heart rate, hold still" : "Recording…"

        let started = Date()
        var lastKeepAlive = started
        ring.startRealtime(subtype)

        while !finishRequested && !Task.isCancelled && ring.isConnected {
            if let duration, elapsed >= duration { break }
            if kind == .spotCheck {
                if elapsed >= Self.spotCheckSeconds && collectedHR.count >= 3 { break }
                if elapsed >= Self.spotCheckTimeout { break }
            }
            try? await Task.sleep(for: .milliseconds(250))
            elapsed = Date().timeIntervalSince(started)
            // The stream stops after ~30 s without a continue packet.
            if Date().timeIntervalSince(lastKeepAlive) >= 20 {
                ring.keepRealtimeAlive(subtype)
                lastKeepAlive = Date()
            }
        }

        ring.stopRealtime(subtype)
        activeKind = nil

        var session = CaptureSession(started: started, ended: Date(), subtype: subtype.rawValue,
                                     rrIntervals: collectedRR, heartRates: collectedHR)
        session.kind = kind
        session.activity = activity

        guard !collectedRR.isEmpty || !collectedHR.isEmpty else {
            status = ring.isConnected ? "No reading — check the fit and hold still"
                                      : "Ring disconnected"
            return nil
        }
        store.add(session: session)
        if let health { Task { await health.save(session: session) } }
        let rmssd = session.rmssd.map { String(format: "%.0f ms", $0) } ?? "—"
        status = "\(collectedRR.count) beats · RMSSD \(rmssd)"
        return session
    }

    /// Ends the current recording early, keeping what was captured.
    func finish() { finishRequested = true }

    /// Ten-second Live heart rate reading; the settled value, or nil. Uses
    /// the heart-rate stream, which reports bpm directly.
    func measureHeartRate() async -> Int? {
        await record(.spotCheck, subtype: .heartRate)?.settledHR
    }

    /// A single-value reading — SpO₂ or stress — streamed for up to `seconds`
    /// and settled as the median once enough values arrive. Nothing is saved
    /// here; the caller stores it where it belongs.
    func measure(_ subtype: RealtimeSubtype, seconds: TimeInterval = 45) async -> Int? {
        guard ring.isConnected, activeKind == nil else { return nil }
        activeKind = .capture
        activeSubtype = subtype
        droppedFirst = false
        finishRequested = false
        collectedValues.removeAll()
        liveValue = nil
        elapsed = 0
        status = "Measuring \(subtype.label)…"

        let started = Date()
        var lastKeepAlive = started
        ring.startRealtime(subtype)
        while !finishRequested && !Task.isCancelled && ring.isConnected && elapsed < seconds {
            // Settle once there are a few readings past the first ones.
            if elapsed >= 15 && collectedValues.count >= 6 { break }
            try? await Task.sleep(for: .milliseconds(250))
            elapsed = Date().timeIntervalSince(started)
            if Date().timeIntervalSince(lastKeepAlive) >= 20 {
                ring.keepRealtimeAlive(subtype)
                lastKeepAlive = Date()
            }
        }
        ring.stopRealtime(subtype)
        activeKind = nil

        let settled = collectedValues.dropFirst(min(2, max(0, collectedValues.count - 3)))
        guard !settled.isEmpty else {
            status = "No \(subtype.label) reading"
            return nil
        }
        let value = Int(HRV.median(settled.map(Double.init)).rounded())
        status = "\(subtype.label) \(value)"
        return value
    }

    /// Adds feedback to a session already saved.
    func update(_ session: CaptureSession) { store.add(session: session) }

    func captureOnce(_ subtype: RealtimeSubtype = .healthCheck,
                     seconds: TimeInterval = 90) {
        guard ring.isConnected, !isCapturing else { return }
        task = Task { await record(.capture, duration: seconds, subtype: subtype) }
    }

    func startOvernight(_ subtype: RealtimeSubtype = .healthCheck) {
        guard ring.isConnected, !isOvernight, !isCapturing else { return }
        isOvernight = true
        task = Task {
            while !Task.isCancelled && isOvernight {
                if ring.isConnected { await record(.capture, duration: windowSeconds, subtype: subtype) }
                guard isOvernight else { break }
                status = "Waiting for next window"
                try? await Task.sleep(nanoseconds: UInt64(gapSeconds * 1_000_000_000))
            }
        }
    }

    func stop() {
        isOvernight = false
        finish()
        task?.cancel()
        task = nil
        status = "Idle"
    }
}
