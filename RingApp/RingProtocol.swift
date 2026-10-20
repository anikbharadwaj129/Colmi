import Foundation

// MARK: - UUIDs

enum RingUUID {
    static let uartService    = "6E40FFF0-B5A3-F393-E0A9-E50E24DCCA9E"
    static let uartWrite      = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    static let uartNotify     = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    static let bigDataService = "DE5BF728-D711-4E47-AF26-65E3012A5DC7"
    static let bigDataWrite   = "DE5BF72A-D711-4E47-AF26-65E3012A5DC7"
    static let bigDataNotify  = "DE5BF729-D711-4E47-AF26-65E3012A5DC7"
}

// MARK: - UART

enum UARTCommand: UInt8 {
    case setTime          = 0x01
    case battery          = 0x03
    case heartRateLog     = 0x15
    case hrLogSettings    = 0x16   // read/write: full-day HR logging
    case spo2Pref         = 0x2C   // read/write: full-day SpO2        (inferred)
    case stressPref       = 0x36   // read/write: full-day stress      (inferred)
    case hrvPref          = 0x38   // read/write: scheduled HRV        (inferred)
    case stressHistory    = 0x37
    case hrvHistory       = 0x39
    case steps            = 0x43
    case realtimeStart    = 0x69
    case realtimeStop     = 0x6A
    case statusPush       = 0x73
}

/// The toggles QRing exposes under Health Monitoring. These settings live on
/// the ring, so they govern what gets logged whether or not any app is
/// connected — which is what makes history sync work at all.
///
/// Framing (confirmed for 0x16, the same shape assumed for the rest):
///   read   → [cmd, 0x01]
///   write  → [cmd, 0x02, enabled, interval]
///   reply  → [cmd, 0x01, enabled, interval]
enum MonitoringKind: CaseIterable, Identifiable {
    case heartRate, spo2, stress, hrv

    var id: String { label }

    var command: UARTCommand {
        switch self {
        case .heartRate: return .hrLogSettings
        case .spo2:      return .spo2Pref
        case .stress:    return .stressPref
        case .hrv:       return .hrvPref
        }
    }

    var label: String {
        switch self {
        case .heartRate: return "Full-day heart rate"
        case .spo2:      return "Full-day blood oxygen"
        case .stress:    return "Full-day stress"
        case .hrv:       return "Scheduled HRV"
        }
    }

    /// Intervals QRing offers, in minutes.
    var intervals: [Int] {
        switch self {
        case .heartRate: return [1, 5, 10, 15, 30, 45, 60]
        case .spo2, .hrv: return [60]
        case .stress: return [30]
        }
    }

    var isVerified: Bool { self == .heartRate }
}

struct MonitoringSetting {
    let kind: MonitoringKind
    let isEnabled: Bool
    let intervalMinutes: Int

    init?(packet: Data) {
        guard packet.count >= 16,
              let kind = MonitoringKind.allCases.first(where: {
                  $0.command.rawValue == packet[0]
              }),
              packet[1] == 0x01 else { return nil }
        self.kind = kind
        isEnabled = packet[2] != 0
        intervalMinutes = max(1, Int(packet[3]))
    }
}

enum RealtimeSubtype: UInt8, CaseIterable, Identifiable {
    case heartRate   = 0x01
    case spo2        = 0x03
    case healthCheck = 0x05
    case stressHRV   = 0x08

    var id: UInt8 { rawValue }
    var label: String {
        switch self {
        case .heartRate:   return "Heart rate"
        case .spo2:        return "SpO₂"
        case .healthCheck: return "Health check"
        case .stressHRV:   return "Stress"
        }
    }
    var yieldsRR: Bool { self != .spo2 }
}

enum RealtimeAction: UInt8 {
    case start     = 0x01
    case pause     = 0x02
    case keepGoing = 0x03
}

enum UARTPacket {
    /// 16 bytes: [command][payload padded to 14][checksum = sum(0..<15) & 0xFF]
    static func make(_ command: UInt8, payload: [UInt8] = []) -> Data {
        precondition(payload.count <= 14)
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = command
        for (i, b) in payload.enumerated() { bytes[1 + i] = b }
        bytes[15] = UInt8(bytes[0..<15].reduce(0) { $0 + Int($1) } & 0xFF)
        return Data(bytes)
    }

    static func make(_ command: UARTCommand, payload: [UInt8] = []) -> Data {
        make(command.rawValue, payload: payload)
    }

    static func checksumValid(_ data: Data) -> Bool {
        guard data.count == 16 else { return false }
        return data[15] == UInt8(data[0..<15].reduce(0) { Int($0) + Int($1) } & 0xFF)
    }

    /// BCD yy mm dd hh mm ss.
    ///
    /// The ring has no timezone field — it stores whatever wall-clock digits it
    /// is handed, and sleep is a circadian measure, so local time is correct.
    /// (Converting to UTC here would silently shift every stored timestamp.)
    static func setTimePayload(_ date: Date = Date()) -> [UInt8] {
        let c = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        func bcd(_ v: Int) -> UInt8 { UInt8(((v / 10) << 4) | (v % 10)) }
        return [bcd((c.year ?? 2000) % 100), bcd(c.month ?? 1), bcd(c.day ?? 1),
                bcd(c.hour ?? 0), bcd(c.minute ?? 0), bcd(c.second ?? 0)]
    }
}

struct BatteryState: Equatable {
    let level: Int
    let isCharging: Bool

    init?(packet: Data) {
        guard packet.count >= 16 else { return nil }
        switch packet[0] {
        case UARTCommand.battery.rawValue:
            level = Int(packet[1]); isCharging = packet[2] == 1
        case UARTCommand.statusPush.rawValue where packet[1] == 0x0C:
            level = Int(packet[2]); isCharging = packet[3] == 1
        default: return nil
        }
    }
}

/// One packet from a real-time stream.
///   [3]    bpm (0x01, 0x05) · SpO₂ % (0x03) · stress (0x08)
///   [4..5] blood pressure pair on 0x05
///   [6..7] RR interval, uint16 LE, ms
struct RealtimeSample {
    let subtype: UInt8
    let timestamp: Date
    let errorCode: UInt8
    let primary: Int
    let systolic: Int?
    let diastolic: Int?
    let rrMs: Int?

    /// For the single-value streams — heart rate (1), SpO₂ (3), stress (8) —
    /// byte 3 is the reading and byte 2 an error code, per colmi_r02_client.
    /// The health-check stream (5) carries beat intervals and puts something
    /// other than heart rate in byte 3.
    var reading: Int? {
        guard [RealtimeSubtype.heartRate, .spo2, .stressHRV].map(\.rawValue).contains(subtype),
              errorCode == 0, primary > 0 else { return nil }
        return primary
    }

    init?(packet: Data, at date: Date = Date()) {
        guard packet.count >= 16,
              packet[0] == UARTCommand.realtimeStart.rawValue else { return nil }
        subtype = packet[1]
        timestamp = date
        errorCode = packet[2]
        primary = Int(packet[3])
        let d = Int(packet[4]), s = Int(packet[5])
        diastolic = d > 0 ? d : nil
        systolic  = s > 0 ? s : nil
        let rr = Int(packet[6]) | (Int(packet[7]) << 8)
        rrMs = (rr > 200 && rr < 2500) ? rr : nil
    }

    var isUsable: Bool { primary > 0 || rrMs != nil }
}

// MARK: - UART history (0x37 stress, 0x39 HRV)
//
// The ring logs HRV and stress on its own all day, so these series need no live
// capture — this is how the app gets HRV without holding a BLE stream overnight.
//
// Wire format:
//   packet [0] = command, [1] = packet index (0 = header)
//   header:  [2] packet count, [3] interval minutes
//   data:    bytes 2..14 of packets 1..n, concatenated into one stream
//   stream[0] = the requested day offset, echoed back (not a sample)
//   samples start at stream[1] — HRV uint16 LE (ms), stress uint8 (0-100)
// Zero means "no measurement", not a real zero.

struct HistorySeries {
    let command: UInt8
    let dayOffset: Int
    let intervalMinutes: Int
    let values: [Int]          // index-aligned, 0 = no measurement

    var isEmpty: Bool { values.allSatisfy { $0 == 0 } }

    /// These series carry no absolute clock, so timestamps are inferred from
    /// the interval and the echoed day offset.
    func timestamps(now: Date = Date()) -> [(Date, Int)] {
        guard let midnight = DayKey.midnight(daysAgo: dayOffset, from: now) else { return [] }
        return values.enumerated().compactMap { index, value in
            guard value > 0 else { return nil }
            return (midnight.addingTimeInterval(TimeInterval(index * intervalMinutes * 60)), value)
        }
    }
}

/// Reassembles the indexed multi-packet history replies.
final class HistoryAssembler {
    private var command: UInt8?
    private var expectedPackets = 0
    private var interval = 5
    private var stream: [UInt8] = []

    func reset() { command = nil; expectedPackets = 0; stream.removeAll() }

    func feed(_ packet: Data) -> HistorySeries? {
        let bytes = [UInt8](packet)
        guard bytes.count >= 16 else { return nil }
        let cmd = bytes[0]
        guard cmd == UARTCommand.hrvHistory.rawValue
                || cmd == UARTCommand.stressHistory.rawValue else { return nil }

        if bytes[1] == 0 {                      // header
            command = cmd
            expectedPackets = Int(bytes[2])
            interval = max(1, Int(bytes[3]))
            stream.removeAll()
            if expectedPackets <= 1 { defer { reset() }; return finish(cmd) }
            return nil
        }

        guard command == cmd else { return nil }
        stream.append(contentsOf: bytes[2...14])

        // The count includes the header, so data packets run 1…count−1.
        // Waiting for index == count never finished, and every stress and
        // HRV history reply was silently dropped.
        if Int(bytes[1]) >= expectedPackets - 1 {
            defer { reset() }
            return finish(cmd)
        }
        return nil
    }

    private func finish(_ cmd: UInt8) -> HistorySeries {
        let dayOffset = Int(stream.first ?? 0)
        let samples = Array(stream.dropFirst())

        let values: [Int]
        if cmd == UARTCommand.hrvHistory.rawValue {
            // uint16 little-endian. Reading this big-endian produces identical
            // numbers while values stay under 256, then breaks the first time
            // HRV exceeds 255 ms or a non-zero day offset is requested.
            values = stride(from: 0, to: samples.count - 1, by: 2).map {
                Int(samples[$0]) | (Int(samples[$0 + 1]) << 8)
            }
        } else {
            values = samples.map(Int.init)
        }

        return HistorySeries(command: cmd, dayOffset: dayOffset,
                             intervalMinutes: interval, values: values)
    }
}

// MARK: - Heart rate log (0x15)
//
// The ring's own all-day log: one reading per 5-minute slot from midnight,
// 288 a day. Request: [0x15, that day's local midnight as a little-endian
// Unix timestamp]. Reply, 16-byte packets:
//   [1] = 0xFF        no data for that day
//   [1] = 0           header: [2] packet count, [3] logging interval
//   [1] = 1           [2..5] timestamp LE, [6..14] the first 9 readings
//   [1] = 2…count−1   13 readings each in [2..14]; the last index ends it
// Zero is "no reading", not 0 bpm. Ported from colmi_r02_client.hr and
// ngeorge15/smart-ring, which notes a short wait silently truncates the day.

struct HeartRateReading: Codable, Identifiable {
    var id: String { DayKey.iso(time) }
    let time: Date
    let bpm: Int

    var dayKey: String { DayKey.of(time) }
}

enum HeartRateLogReply {
    case noData
    case readings([HeartRateReading])
}

final class HeartRateLogAssembler {
    static let slotsPerDay = 288
    static let slotSeconds: TimeInterval = 300

    private var midnight: Date?
    private var packetCount = 0
    private var raw: [UInt8] = []
    private var sawFirst = false

    /// Readings are dated by the day asked for, so a ring clock that drifted
    /// across a timezone can't move them onto another day.
    func begin(day midnight: Date) {
        self.midnight = midnight
        packetCount = 0
        raw.removeAll()
        sawFirst = false
    }

    func feed(_ packet: Data) -> HeartRateLogReply? {
        let p = [UInt8](packet)
        guard p.count == 16, p[0] == UARTCommand.heartRateLog.rawValue else { return nil }
        switch p[1] {
        case 0xFF:
            return .noData
        case 0:
            packetCount = Int(p[2])
            raw.removeAll()
            sawFirst = false
            return packetCount <= 1 ? .noData : nil
        case 1:
            raw = Array(p[6...14])
            sawFirst = true
            return packetCount == 2 ? finish() : nil
        default:
            guard sawFirst else { return nil }
            raw += p[2...14]
            return Int(p[1]) >= packetCount - 1 ? finish() : nil
        }
    }

    private func finish() -> HeartRateLogReply {
        guard let midnight else { return .noData }
        let now = Date()
        let readings = raw.prefix(Self.slotsPerDay).enumerated().compactMap { slot, bpm -> HeartRateReading? in
            let time = midnight.addingTimeInterval(Double(slot) * Self.slotSeconds)
            // Slots still in the future hold leftovers, not readings.
            guard bpm >= 30, bpm <= 220, time <= now else { return nil }
            return HeartRateReading(time: time, bpm: Int(bpm))
        }
        raw.removeAll()
        sawFirst = false
        return .readings(readings)
    }
}

// MARK: - Steps (0x43)
//
// Request: [0x43, day_offset, 0x0F, 0x00, 0x5F, 0x01] — the trailing bytes are
// constants the ring ignores but expects. The reply is a run of 16-byte packets:
//   no data:  [1] = 0xFF
//   header:   [1] = 0xF0, [3] = 1 means the newer calorie scale (×10)
//   rows:     [1..3] BCD year-2000 / month / day, [4] 15-minute slot (0–95),
//             [5] row index, [6] row count, [7..8] calories LE,
//             [9..10] steps LE, [11..12] distance LE in metres
//   last row: [5] == [6] − 1
// Ported from colmi_r02_client.steps and ngeorge15/smart-ring's engine. The
// distance unit was pinned there: distance/steps holds at 0.68–0.82 across
// every busy hour, a normal walking stride.

struct StepBucket: Codable, Identifiable {
    var id: String { DayKey.iso(time) }
    let time: Date          // start of the 15-minute slot
    let steps: Int
    let metres: Int

    var dayKey: String { DayKey.of(time) }
    /// 4 AM to 4 AM, as Oura counts activity.
    var activityDayKey: String { DayKey.activityDay(of: time) }
}

enum StepsReply {
    case noData
    case rows([StepBucket])
}

/// Reassembles one day's step rows. The firmware's own calorie field is
/// parsed past but not kept: it comes from step count alone, and the app
/// works calories out from distance and your weight instead.
final class StepsAssembler {
    private var rows: [StepBucket] = []
    private var started = false

    func reset() { rows.removeAll(); started = false }

    func feed(_ packet: Data) -> StepsReply? {
        let p = [UInt8](packet)
        guard p.count == 16, p[0] == UARTCommand.steps.rawValue else { return nil }
        if !started && p[1] == 0xFF { reset(); return .noData }
        if p[1] == 0xF0 { rows.removeAll(); started = true; return nil }

        started = true
        let bcd: (UInt8) -> Int = { Int($0 >> 4) * 10 + Int($0 & 0x0F) }
        var parts = DateComponents()
        parts.year = 2000 + bcd(p[1])
        parts.month = bcd(p[2])
        parts.day = bcd(p[3])
        if let midnight = Calendar.current.date(from: parts), p[4] < 96 {
            rows.append(StepBucket(
                time: midnight.addingTimeInterval(TimeInterval(Int(p[4]) * 15 * 60)),
                steps: Int(p[9]) | Int(p[10]) << 8,
                metres: Int(p[11]) | Int(p[12]) << 8))
        }
        if Int(p[5]) == Int(p[6]) - 1 { return drain() }
        return nil
    }

    /// Whatever arrived, for when the last row never does: a dropped BLE
    /// packet should cost one slot, not the whole day.
    func drain() -> StepsReply? {
        defer { reset() }
        return rows.isEmpty ? nil : .rows(rows)
    }
}

// MARK: - Big data

enum BigDataType: UInt8, CaseIterable, Identifiable {
    case temperature = 0x25
    case sleep       = 0x27
    case spo2        = 0x2A

    var id: UInt8 { rawValue }
    var label: String {
        switch self {
        case .temperature: return "Temperature"
        case .sleep:       return "Sleep"
        case .spo2:        return "SpO₂ history"
        }
    }
}

enum BigDataStatus: UInt8 {
    case ok          = 0x00
    case unsupported = 0x02
    case needsParams = 0x03
}

enum BigData {
    static let magic: UInt8 = 0xBC

    /// CRC-16/CCITT-FALSE. The ring validates this; CRC-16/ARC is rejected
    /// with status 0x02, which reads deceptively like "unsupported type".
    static func crc16CCITT(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    static func request(_ type: UInt8, payload: [UInt8] = []) -> Data {
        let len = UInt16(payload.count), crc = crc16CCITT(payload)
        return Data([magic, type,
                     UInt8(len & 0xFF), UInt8(len >> 8),
                     UInt8(crc & 0xFF), UInt8(crc >> 8)] + payload)
    }

    static func request(_ type: BigDataType, payload: [UInt8] = []) -> Data {
        request(type.rawValue, payload: payload)
    }

    /// The read request QRing sends, byte for byte: bc <type> 01 00 ff 00 ff.
    /// ngeorge15/smart-ring validated sleep, SpO₂ and temperature with it.
    static func read(_ type: UInt8) -> Data {
        Data([magic, type, 0x01, 0x00, 0xFF, 0x00, 0xFF])
    }
}

/// Buffers notifications and walks the framing.
///
/// A single reply can contain SEVERAL messages, each with its own 6-byte
/// header — type 0x25 sends one message per day. Reading the first declared
/// length and stopping returns only the first record and parses the following
/// headers as if they were data.
final class BigDataFramer {
    private var buffer: [UInt8] = []

    func reset() { buffer.removeAll() }

    func feed(_ chunk: Data) -> [(type: UInt8, payload: [UInt8])] {
        buffer.append(contentsOf: chunk)
        var messages: [(UInt8, [UInt8])] = []

        while buffer.count >= 6 {
            guard buffer[0] == BigData.magic else {
                buffer.removeFirst()        // resync on the next magic byte
                continue
            }
            let type = buffer[1]
            let length = Int(buffer[2]) | (Int(buffer[3]) << 8)
            guard buffer.count >= 6 + length else { break }   // wait for the rest
            messages.append((type, Array(buffer[6..<(6 + length)])))
            buffer.removeFirst(6 + length)
        }
        return messages
    }
}

// MARK: - Parsed payloads

enum SleepStage: UInt8, Codable, CaseIterable {
    case light = 0x02
    case deep  = 0x03
    case rem   = 0x04
    case awake = 0x05

    var label: String {
        switch self {
        case .light: return "Light"
        case .deep:  return "Deep"
        case .rem:   return "REM"
        case .awake: return "Awake"
        }
    }
}

struct SleepSegment: Codable, Identifiable {
    var id: String { "\(start.timeIntervalSince1970)-\(stage.rawValue)" }
    let stage: SleepStage
    let start: Date
    let minutes: Int
    var end: Date { start.addingTimeInterval(TimeInterval(minutes * 60)) }
}

struct SleepNight: Codable, Identifiable {
    let dayKey: String
    let start: Date
    let end: Date
    let segments: [SleepSegment]

    var id: String { dayKey }
    var totalMinutes: Int { segments.reduce(0) { $0 + $1.minutes } }
    func minutes(in stage: SleepStage) -> Int {
        segments.filter { $0.stage == stage }.reduce(0) { $0 + $1.minutes }
    }
    var asleepMinutes: Int { totalMinutes - minutes(in: .awake) }
    var efficiency: Double {
        totalMinutes > 0 ? Double(asleepMinutes) / Double(totalMinutes) : 0
    }
    /// Standard chronotype marker: the clock time halfway through the night.
    var midpoint: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }

    /// Oura's sleep day: a sleep belongs to the 6 PM–6 PM window its middle
    /// falls in, and the longest sleep in a window is that day's night.
    /// The ring's own day offset is usually the same, but an evening sleep
    /// (say 7–11 PM) belongs to the next day, and a 4 AM–10 AM one to today.
    static func bySleepDay(_ nights: [SleepNight]) -> [SleepNight] {
        let keyed = nights.map { night in
            SleepNight(dayKey: DayKey.sleepDay(of: night.midpoint), start: night.start,
                       end: night.end, segments: night.segments)
        }
        return Dictionary(grouping: keyed, by: \.dayKey).values.compactMap { sameDay in
            sameDay.max { $0.asleepMinutes < $1.asleepMinutes }
        }
    }

    /// Nights saved before the midnight fix have their onset a day late.
    var repaired: SleepNight {
        guard start > end,
              let fixedStart = Calendar.current.date(byAdding: .day, value: -1, to: start) else { return self }
        let shift = fixedStart.timeIntervalSince(start)
        return SleepNight(dayKey: dayKey, start: fixedStart, end: end,
                          segments: segments.map {
                              SleepSegment(stage: $0.stage, start: $0.start.addingTimeInterval(shift),
                                           minutes: $0.minutes)
                          })
    }

    /// Payload: [n_days] then per day [days_ago][len][body].
    /// Body: start minutes LE, end minutes LE, then (stage, minutes) pairs.
    static func parse(_ payload: [UInt8], now: Date = Date()) -> [SleepNight] {
        guard payload.count > 7 else { return [] }
        var nights: [SleepNight] = []
        var cursor = 1                      // skip the day count

        while cursor + 2 < payload.count {
            let dayOffset = Int(payload[cursor])
            let length = Int(payload[cursor + 1])
            let bodyStart = cursor + 2
            guard length >= 4, bodyStart + length <= payload.count else { break }
            let body = Array(payload[bodyStart..<(bodyStart + length)])
            cursor = bodyStart + length

            let startMin = Int(body[0]) | (Int(body[1]) << 8)
            let endMin   = Int(body[2]) | (Int(body[3]) << 8)
            guard let midnight = DayKey.midnight(daysAgo: dayOffset, from: now) else { continue }

            // Both times are minutes from midnight and both wrap, and the day
            // offset counts back from the morning you woke. So an end earlier
            // than the start means the night began the evening before — a
            // 23:27 onset belongs to the previous day, not 23:27 after waking.
            // Reading it on the wake day put the start after the end, and
            // every "during the night" window came back empty.
            let wrapped = endMin < startMin
            guard let startDay = wrapped
                    ? Calendar.current.date(byAdding: .day, value: -1, to: midnight) : midnight
            else { continue }
            let start = startDay.addingTimeInterval(TimeInterval(startMin * 60))
            let end   = midnight.addingTimeInterval(TimeInterval(endMin * 60))

            var segments: [SleepSegment] = []
            var at = start
            var i = 4
            while i + 1 < body.count {
                let raw = body[i], minutes = Int(body[i + 1])
                i += 2
                guard minutes > 0, let stage = SleepStage(rawValue: raw) else { continue }
                segments.append(SleepSegment(stage: stage, start: at, minutes: minutes))
                at = at.addingTimeInterval(TimeInterval(minutes * 60))
            }
            guard !segments.isEmpty else { continue }
            nights.append(SleepNight(dayKey: DayKey.of(midnight),
                                     start: start, end: end, segments: segments))
        }
        return nights
    }
}

struct TemperatureReading: Codable, Identifiable {
    var id: String { DayKey.iso(time) }
    let time: Date
    let celsius: Double
}

enum TemperatureParser {
    static let recordLength = 50

    /// Fixed 50-byte records, one per day: [days_ago][interval][48 slots from
    /// local midnight]. A payload can hold several days back to back, so it's
    /// walked a record at a time — reading the first record's header and
    /// treating everything after as samples smeared later days onto the first.
    /// Scale confirmed against the QRing app: celsius = raw / 10 + 20.
    static func parse(_ payload: [UInt8], now: Date = Date()) -> [TemperatureReading] {
        guard payload.count >= recordLength else { return [] }
        return stride(from: 0, through: payload.count - recordLength, by: recordLength).flatMap { offset in
            let record = Array(payload[offset..<(offset + recordLength)])
            let interval = record[1] == 0 ? 30 : Int(record[1])
            guard let midnight = DayKey.midnight(daysAgo: Int(record[0]), from: now) else {
                return [TemperatureReading]()
            }
            return record.dropFirst(2).enumerated().compactMap { slot, raw in
                guard raw > 0 else { return nil }
                return TemperatureReading(
                    time: midnight.addingTimeInterval(TimeInterval(slot * interval * 60)),
                    celsius: Double(raw) / 10 + 20)
            }
        }
    }
}

struct SpO2Reading: Codable, Identifiable {
    var id: String { DayKey.iso(time) }
    let time: Date
    let low: Int
    let high: Int
    var average: Double { Double(low + high) / 2 }
}

enum SpO2Parser {
    static let recordLength = 49

    /// Fixed 49-byte records, one per day: [days_ago][48 × uint8], one value
    /// per 30-minute slot from local midnight; 0 is "no measurement". A reply
    /// usually carries several days. Hourly logging shows up as each value
    /// repeated across two slots. (ngeorge15/smart-ring pinned this layout
    /// against live readings; the old pairwise read put night readings hours
    /// away from where they belong.)
    static func parse(_ payload: [UInt8], now: Date = Date()) -> [SpO2Reading] {
        guard payload.count >= recordLength else { return [] }
        return stride(from: 0, through: payload.count - recordLength, by: recordLength).flatMap { offset in
            let record = Array(payload[offset..<(offset + recordLength)])
            guard let midnight = DayKey.midnight(daysAgo: Int(record[0]), from: now) else {
                return [SpO2Reading]()
            }
            return record.dropFirst(1).enumerated().compactMap { slot, value in
                guard value >= 70, value <= 100 else { return nil }
                return SpO2Reading(time: midnight.addingTimeInterval(TimeInterval(slot * 30 * 60)),
                                   low: Int(value), high: Int(value))
            }
        }
    }
}

/// A logged HRV or stress sample pulled from the ring's own history.
struct SeriesSample: Codable, Identifiable {
    var id: String { "\(kind)-\(DayKey.iso(time))" }
    let kind: String       // "hrv" | "stress"
    let time: Date
    let value: Double

    var dayKey: String { DayKey.of(time) }
}

// MARK: - Dates

enum DayKey {
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func of(_ date: Date) -> String { day.string(from: date) }

    // Oura keeps three kinds of day (partner docs, "Types of Oura Days"):
    // calendar days run midnight to midnight; activity days 4 AM to 4 AM, so
    // dancing until 3 AM still counts toward the day before; sleep days 6 PM
    // to 6 PM, so the night you go to bed at 11 PM — or at 4 AM — belongs to
    // the day you wake into.

    /// The activity day a moment belongs to: 4 AM to 4 AM, dated by its start.
    static func activityDay(of date: Date) -> String {
        of(Calendar.current.date(byAdding: .hour, value: -4, to: date) ?? date)
    }

    /// The sleep day a moment belongs to: 6 PM to 6 PM, dated by its end.
    static func sleepDay(of date: Date) -> String {
        of(Calendar.current.date(byAdding: .hour, value: 6, to: date) ?? date)
    }
    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func date(_ key: String) -> Date? { day.date(from: key) }
    static func isToday(_ key: String) -> Bool { key == of(Date()) }

    static func friendly(_ key: String) -> String {
        guard let date = date(key) else { return key }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func full(_ key: String) -> String {
        guard let date = date(key) else { return key }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    static func midnight(daysAgo: Int, from now: Date = Date()) -> Date? {
        let cal = Calendar.current
        guard let today = cal.date(from: cal.dateComponents([.year, .month, .day], from: now))
        else { return nil }
        return cal.date(byAdding: .day, value: -daysAgo, to: today)
    }
}
