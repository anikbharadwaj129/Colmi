import SwiftUI
import BackgroundTasks
import Combine

// MARK: - App services
//
// One shared set of objects, created at launch rather than when the first
// view appears. When iOS relaunches the app in the background for the ring
// (state restoration) or for a background refresh, there may be no window at
// all — the connection, sync and scheduler still have to exist.

@MainActor
final class AppServices {
    static let shared = AppServices()

    let ring = RingConnection()
    let store = RingStore()
    let health = HealthService()
    let sync: RingSync
    let capture: RingCapture
    let notifier: Notifier
    let monitor: RingMonitor

    private init() {
        // The App struct can create these before the delegate's
        // didFinishLaunching runs, and submitting a refresh for a task that
        // isn't registered yet is fatal — so register here first.
        RingMonitor.registerBackgroundRefresh()
        sync = RingSync(ring: ring, store: store, health: health)
        capture = RingCapture(ring: ring, store: store, health: health)
        notifier = Notifier(ring: ring, store: store)
        monitor = RingMonitor(ring: ring, store: store, sync: sync, capture: capture, notifier: notifier)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Both must happen before launch finishes: the central manager so iOS
        // can hand back a restored connection, the task so refreshes can run.
        RingMonitor.registerBackgroundRefresh()
        _ = AppServices.shared
        return true
    }
}

// MARK: - Monitor
//
// The ring keeps its own schedule for what it logs (temperature every 30 min,
// SpO₂ and HRV hourly, stress every 30 min, heart rate at the interval set in
// Settings), and the app pulls those logs whenever it syncs. On top of that,
// this runs extra live measurements at intervals you choose.
//
// iOS doesn't let an app run a timer in the background, so measurements run
// whenever the app gets a chance: when the ring connects or reconnects, when
// you open the app, on a scheduled background refresh, and on any packet the
// ring sends while the app is in the background. The cost to the phone is
// small — a pending reconnect is held by the Bluetooth chip, refreshes are
// budgeted by iOS — and the measurement itself runs on the ring.

@MainActor
final class RingMonitor: ObservableObject {

    enum Measurement: String, CaseIterable, Identifiable {
        case heart, spo2, stress

        var id: String { rawValue }

        var title: String {
            switch self {
            case .heart:  return "Heart rate & HRV"
            case .spo2:   return "Blood oxygen"
            case .stress: return "Stress"
            }
        }

        var detail: String {
            switch self {
            case .heart:  return "90-second beat-to-beat capture"
            case .spo2:   return "Live SpO₂ reading (69 03)"
            case .stress: return "Live stress reading (69 08)"
            }
        }

        var defaultMinutes: Int { 60 }
    }

    static let refreshID = "com.aniketh.RingApp.refresh"
    static let choices = [0, 15, 30, 60, 120, 240]          // 0 = off
    static let syncMaxAge: TimeInterval = 30 * 60

    @Published private(set) var status = "Waiting"
    @Published private(set) var lastRun: [Measurement: Date] = [:]
    @Published var intervals: [Measurement: Int] = [:] {
        didSet {
            guard loaded else { return }
            for (m, minutes) in intervals { UserDefaults.standard.set(minutes, forKey: "monitor.\(m.rawValue)") }
            scheduleRefresh()
        }
    }
    private var loaded = false

    private let ring: RingConnection
    private let store: RingStore
    private let sync: RingSync
    private let capture: RingCapture
    private let notifier: Notifier
    private var running = false
    private var lastCheck = Date.distantPast
    private var foregroundLoop: Task<Void, Never>?

    init(ring: RingConnection, store: RingStore, sync: RingSync, capture: RingCapture, notifier: Notifier) {
        self.ring = ring
        self.store = store
        self.sync = sync
        self.notifier = notifier
        self.capture = capture

        let defaults = UserDefaults.standard
        for m in Measurement.allCases {
            let stored = defaults.object(forKey: "monitor.\(m.rawValue)") as? Int
            intervals[m] = stored ?? m.defaultMinutes
            let t = defaults.double(forKey: "monitor.\(m.rawValue).last")
            if t > 0 { lastRun[m] = Date(timeIntervalSince1970: t) }
        }

        ring.onReady = { [weak self] in
            Task { await self?.tick() }
        }
        ring.onActivity = { [weak self] in self?.ringActivity() }
        loaded = true
    }

    // MARK: Schedule

    func nextDue(_ m: Measurement) -> Date? {
        guard let minutes = intervals[m], minutes > 0 else { return nil }
        return (lastRun[m] ?? .distantPast).addingTimeInterval(TimeInterval(minutes * 60))
    }

    private var dueNow: [Measurement] {
        Measurement.allCases.filter { nextDue($0).map { $0 <= Date() } ?? false }
    }

    /// The next moment there's something to do: a measurement or a stale sync.
    private var nextWake: Date? {
        let syncDue = sync.lastSync.map { $0.addingTimeInterval(Self.syncMaxAge) } ?? Date()
        return (Measurement.allCases.compactMap(nextDue) + [syncDue]).min()
    }

    /// Sync if the last one is old, then run whatever's due — one at a time,
    /// since the ring streams one thing at once.
    func tick(budget: TimeInterval? = nil) async {
        guard !running, ring.isConnected, !capture.isCapturing else { return }
        running = true
        lastCheck = Date()
        defer {
            running = false
            scheduleRefresh()
        }
        let deadline = budget.map { Date().addingTimeInterval($0) }

        if sync.isStale(maxAge: Self.syncMaxAge) {
            status = "Syncing"
            // A background refresh gets about 30 seconds, so it pulls today only.
            await sync.syncAll(backfillDays: budget == nil ? 7 : 1)
            notifier.lastStepFetch = Date()
        } else if notifier.wantsFreshSteps {
            // Inactivity alerts need steps from the last few minutes.
            await sync.syncTodaySteps()
            notifier.lastStepFetch = Date()
        }
        notifier.refresh()
        for m in dueNow {
            if let deadline, deadline.timeIntervalSinceNow < 60 { break }
            guard ring.isConnected, !capture.isCapturing, !Task.isCancelled else { break }
            await run(m)
        }
        notifier.refresh()
        status = "Up to date · \(Format.time(Date()))"
    }

    private func run(_ m: Measurement) async {
        status = "Measuring \(m.title.lowercased())"
        switch m {
        case .heart:
            _ = await capture.record(.capture, duration: 90, subtype: .healthCheck)
        case .spo2:
            if let value = await capture.measure(.spo2) {
                store.merge(spo2: [SpO2Reading(time: Date(), low: value, high: value)])
            }
        case .stress:
            if let value = await capture.measure(.stressHRV) {
                store.merge(samples: [SeriesSample(kind: "stress", time: Date(), value: Double(value))])
            }
        }
        // Counted as run even without a reading, so a ring off the finger
        // isn't asked again every minute.
        lastRun[m] = Date()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "monitor.\(m.rawValue).last")
    }

    /// Any packet from the ring is a brief chance to run in the background.
    /// Checked at most once a minute, and only acts when something is due.
    private func ringActivity() {
        guard !running, Date().timeIntervalSince(lastCheck) > 60 else { return }
        lastCheck = Date()
        guard !dueNow.isEmpty || sync.isStale(maxAge: Self.syncMaxAge) else { return }
        Task { await tick() }
    }

    // MARK: App lifecycle

    func appBecameActive() {
        ring.connectIfNeeded()
        notifier.refresh()
        foregroundLoop?.cancel()
        foregroundLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func appEnteredBackground() {
        foregroundLoop?.cancel()
        foregroundLoop = nil
        scheduleRefresh()
    }

    // MARK: Background refresh

    private static var registered = false

    /// Safe to call more than once; only the first registers.
    static func registerBackgroundRefresh() {
        guard !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: .main) { task in
            MainActor.assumeIsolated {
                guard let refresh = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                AppServices.shared.monitor.handle(refresh)
            }
        }
    }

    /// Ask iOS for a refresh around the next due time. iOS decides when it
    /// actually runs — typically when the phone is awake and on a schedule it
    /// learns from how you use the app — so this is a request, not an alarm.
    func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        let soonest = Date().addingTimeInterval(15 * 60)
        request.earliestBeginDate = max(soonest, nextWake ?? Date().addingTimeInterval(3600))
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshID)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handle(_ task: BGAppRefreshTask) {
        let work = Task { [weak self] in
            guard let self else { return }
            self.ring.connectIfNeeded()
            // Give a pending connection a few seconds to come up.
            for _ in 0..<10 where !self.ring.isConnected {
                try? await Task.sleep(for: .milliseconds(500))
            }
            await self.tick(budget: 25)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { @Sendable in work.cancel() }
    }
}

// MARK: - Settings

struct BackgroundMonitoringSection: View {
    @EnvironmentObject private var ring: RingConnection
    @ObservedObject var monitor: RingMonitor

    var body: some View {
        Section {
            ForEach(RingMonitor.Measurement.allCases) { m in
                Picker(selection: Binding(
                    get: { monitor.intervals[m] ?? 0 },
                    set: { monitor.intervals[m] = $0 })) {
                    ForEach(RingMonitor.choices, id: \.self) { minutes in
                        Text(label(minutes)).tag(minutes)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.title)
                        Text(monitor.lastRun[m].map { "Last \(Format.time($0)) · \(m.detail)" } ?? m.detail)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Status", value: monitor.status)
                .font(.footnote)
        } header: {
            Text("App measurements")
        } footer: {
            Text("Extra live readings on top of what the ring logs by itself, which syncs whenever the app wakes. iOS doesn't let apps run timers in the background, so these run when the app gets a chance — when the ring connects, when you open the app, on background refreshes iOS schedules, and when the ring sends data — and may land later than the interval in the background. Each reading turns the ring's sensor on for up to a minute, which costs ring battery.")
        }
    }

    private func label(_ minutes: Int) -> String {
        switch minutes {
        case 0:  return "Off"
        case ..<60: return "Every \(minutes) min"
        case 60: return "Hourly"
        default: return "Every \(minutes / 60) h"
        }
    }
}
