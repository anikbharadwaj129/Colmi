import SwiftUI
import Combine
import UserNotifications

// MARK: - Notifications
//
// Oura's five notifications, sent by the phone itself — no server. Some can be
// scheduled ahead and land on time whether or not the app is running (bedtime,
// the activity reminder, the weekly summary); others depend on fresh ring data
// and go out when the app has a chance to look (battery on any battery
// report, inactivity on each check while the app is awake).

@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    enum Kind: String, CaseIterable, Identifiable {
        case battery, inactivity, progress, bedtime, insights

        var id: String { rawValue }

        var title: String {
            switch self {
            case .battery:    return "Battery level"
            case .inactivity: return "Inactivity alerts"
            case .progress:   return "Activity progress"
            case .bedtime:    return "Bedtime"
            case .insights:   return "Insights"
            }
        }

        var detail: String {
            switch self {
            case .battery:    return "2–3 hours before bed if the ring is under 30%"
            case .inactivity: return "After 50 minutes without moving"
            case .progress:   return "An evening nudge toward your step goal, and when you reach it"
            case .bedtime:    return "An hour before your suggested bedtime"
            case .insights:   return "Monday's weekly summary, and Symptom Radar signs"
            }
        }

        /// Oura's defaults: battery and inactivity on, the rest off.
        var defaultOn: Bool { self == .battery || self == .inactivity }
    }

    @Published private(set) var authorized = false
    @Published var enabled: [Kind: Bool] = [:] {
        didSet {
            guard loaded else { return }
            for (kind, on) in enabled { UserDefaults.standard.set(on, forKey: "notify.\(kind.rawValue)") }
            if enabled.values.contains(true) { Task { await requestPermission() } }
            refresh()
        }
    }
    private var loaded = false

    private let ring: RingConnection
    private let store: RingStore
    private let center = UNUserNotificationCenter.current()
    private var batteryWatch: AnyCancellable?

    /// When the last step pull happened, so inactivity is judged on fresh data.
    var lastStepFetch: Date?

    init(ring: RingConnection, store: RingStore) {
        self.ring = ring
        self.store = store
        super.init()
        for kind in Kind.allCases {
            enabled[kind] = UserDefaults.standard.object(forKey: "notify.\(kind.rawValue)") as? Bool ?? kind.defaultOn
        }
        center.delegate = self
        // Battery reports arrive on connect, on each sync, and when the ring
        // pushes one — check each.
        batteryWatch = ring.$battery.compactMap { $0 }.removeDuplicates()
            .sink { [weak self] battery in self?.checkBattery(battery) }
        loaded = true
        Task { await refreshAuthorization() }
    }

    func isOn(_ kind: Kind) -> Bool { enabled[kind] ?? false }

    // MARK: Permission

    func requestPermission() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
    }

    private func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Show banners even while the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // MARK: Bedtime guidance

    var bedtimeGuidance: BedtimeGuidance? {
        let today = DayKey.of(Date())
        return BedtimeGuidance.compute(history: store.daily,
                                       sleepScores: store.sleepScores(through: today, days: 30),
                                       sleepNeedMinutes: store.sleepNeed(asOf: today).minutes,
                                       through: today)
    }

    /// Tonight's bedtime: the start of the suggested window, or your usual
    /// bedtime until there's enough data for guidance, or 11 PM.
    private func tonightsBedtime(now: Date = Date()) -> Date {
        let hour: Double
        if let guidance = bedtimeGuidance {
            hour = guidance.windowStart
        } else {
            let usual = store.daily.prefix(14).compactMap { $0.bedtime.map(Circadian.hour) }
            hour = usual.count >= 3 ? HRV.median(usual) : -1
        }
        return Self.date(atCircadianHour: hour, onEveningOf: now)
    }

    /// A circadian hour (evening negative) as a clock time on tonight's evening.
    static func date(atCircadianHour hour: Double, onEveningOf now: Date) -> Date {
        let clock = (hour + 24).truncatingRemainder(dividingBy: 24)
        let midnight = Calendar.current.startOfDay(for: now)
        var date = midnight.addingTimeInterval(clock * 3600)
        // Times after midnight belong to tonight, so to tomorrow's date.
        if hour >= 0 { date = date.addingTimeInterval(86400) }
        return date
    }

    // MARK: Refresh

    /// Re-evaluates everything. Called after syncs, on each scheduler check,
    /// and when settings change.
    func refresh(now: Date = Date()) {
        scheduleBedtime()
        if let battery = ring.battery { checkBattery(battery) }
        checkInactivity(now: now)
        checkProgress(now: now)
        scheduleWeeklyInsight(now: now)
        checkSymptomRadar(now: now)
    }

    // Battery

    private func checkBattery(_ battery: BatteryState) {
        guard isOn(.battery),
              let fire = NotificationRules.batteryAlert(level: battery.level, isCharging: battery.isCharging,
                                                       bedtime: tonightsBedtime(), now: Date()) else {
            center.removePendingNotificationRequests(withIdentifiers: ["battery"])
            return
        }
        guard !sentToday("battery") else { return }
        schedule("battery", at: fire,
                 title: "Charge your ring before bed",
                 body: "It's at \(battery.level)%. Oura needs at least 30% to track a full night's sleep.")
        markSent("battery")
    }

    // Inactivity

    private func checkInactivity(now: Date) {
        guard isOn(.inactivity), !store.isRestMode(on: DayKey.of(now)) else { return }
        let today = DayKey.of(now)
        let wake = store.night(on: today)?.end
            ?? Calendar.current.startOfDay(for: now).addingTimeInterval(8 * 3600)
        let awakeSince = max(wake, Calendar.current.startOfDay(for: now).addingTimeInterval(7 * 3600))
        // Quiet from 30 minutes before tonight's bedtime, and never past 9:30 PM.
        let quiet = min(tonightsBedtime(now: now).addingTimeInterval(-1800),
                        Calendar.current.startOfDay(for: now).addingTimeInterval(21.5 * 3600))
        let lastAlert = UserDefaults.standard.double(forKey: "notified.inactivity.at")
        guard NotificationRules.shouldAlertInactivity(
            buckets: store.stepBuckets(on: store.activityDayKey(showing: today)),
            now: now, awakeSince: awakeSince, quietFrom: quiet,
            lastAlert: lastAlert > 0 ? Date(timeIntervalSince1970: lastAlert) : nil,
            lastStepFetch: lastStepFetch) else { return }
        schedule("inactivity", at: now.addingTimeInterval(1),
                 title: "Time to move",
                 body: "You've been still for about 50 minutes. A short walk or stretch in the next 10 minutes resets it.")
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "notified.inactivity.at")
    }

    /// Whether the scheduler should pull today's steps before checking.
    var wantsFreshSteps: Bool {
        isOn(.inactivity) && (lastStepFetch.map { Date().timeIntervalSince($0) > 10 * 60 } ?? true)
    }

    // Activity progress

    private func checkProgress(now: Date) {
        let reminderID = "progress"
        guard isOn(.progress), !store.isRestMode(on: DayKey.of(now)) else {
            center.removePendingNotificationRequests(withIdentifiers: [reminderID])
            return
        }
        let goal = ActivityScore.stepGoal
        let steps = store.activity(on: store.activityDayKey(showing: DayKey.of(now)))?.steps ?? 0
        // The activity day runs to 4 AM, but nobody wants a step nudge at 1 AM.
        let hour = Calendar.current.component(.hour, from: now)
        let daytime = (7..<22).contains(hour)
        if steps >= goal {
            guard daytime else { return }
            center.removePendingNotificationRequests(withIdentifiers: [reminderID])
            if !sentToday("progress.goal") {
                schedule("progress.goal", at: now.addingTimeInterval(1),
                         title: "Daily goal reached",
                         body: "\(Int(steps).formatted()) steps today. Nice work.")
                markSent("progress.goal")
            }
            return
        }
        // An evening reminder at 6 PM, its numbers refreshed on every check
        // until it goes out.
        let sixPM = Calendar.current.startOfDay(for: now).addingTimeInterval(18 * 3600)
        if now < sixPM {
            schedule(reminderID, at: sixPM, title: "Activity progress",
                     body: NotificationRules.progressMessage(steps: steps, goal: goal))
        } else if now < sixPM.addingTimeInterval(3 * 3600), !sentToday(reminderID),
                  let fetched = lastStepFetch, now.timeIntervalSince(fetched) < 30 * 60 {
            schedule(reminderID, at: now.addingTimeInterval(1), title: "Activity progress",
                     body: NotificationRules.progressMessage(steps: steps, goal: goal))
            markSent(reminderID)
        }
    }

    // Bedtime

    private func scheduleBedtime() {
        let id = "bedtime"
        guard isOn(.bedtime), let guidance = bedtimeGuidance else {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return
        }
        // Daily, an hour before the window opens — iOS delivers these on time
        // whether or not the app is running.
        let clock = (guidance.windowStart - 1 + 24).truncatingRemainder(dividingBy: 24)
        var time = DateComponents()
        time.hour = Int(clock)
        time.minute = Int((clock - Double(Int(clock))) * 60)
        let window = "\(Circadian.label(guidance.windowStart))–\(Circadian.label(guidance.windowEnd))"
        let content = UNMutableNotificationContent()
        content.title = "Bedtime in an hour"
        content.body = "Your ideal bedtime tonight is \(window). Time to start winding down."
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: time, repeats: true)))
    }

    // Insights

    private func scheduleWeeklyInsight(now: Date) {
        let id = "insight.weekly"
        guard isOn(.insights) else {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return
        }
        // Next Monday 9 AM, summarising the week that ends the night before.
        guard let thisMonday = DayKey.date(HealthWeek.updateDay(for: DayKey.of(now))) else { return }
        let nineAM = thisMonday.addingTimeInterval(9 * 3600)
        let fire = now < nineAM ? nineAM : Calendar.current.date(byAdding: .day, value: 7, to: nineAM)!
        let weekStart = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: fire))!
        let week = dayKeys(endingOn: DayKey.of(weekStart.addingTimeInterval(6 * 86400)), count: 7)
        let before = dayKeys(endingOn: DayKey.of(weekStart.addingTimeInterval(-86400)), count: 7)
        guard let body = NotificationRules.weeklySummary(
            readiness: week.compactMap { store.readiness(on: $0)?.value },
            previousReadiness: before.compactMap { store.readiness(on: $0)?.value },
            sleep: week.compactMap { store.sleepScore(on: $0)?.value },
            steps: week.compactMap { store.activity(on: $0)?.steps }) else { return }
        schedule(id, at: fire, title: "Your week in review", body: body)
    }

    private func checkSymptomRadar(now: Date) {
        let today = DayKey.of(now)
        guard isOn(.insights), let radar = store.symptomRadar(on: today), radar.level != .none,
              !sentToday("insight.radar") else { return }
        schedule("insight.radar", at: now.addingTimeInterval(1),
                 title: "Symptom Radar: \(radar.level.rawValue.lowercased())",
                 body: "\(radar.level.summary) \(radar.detail).")
        markSent("insight.radar")
    }

    // MARK: Helpers

    private func schedule(_ id: String, at date: Date, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let seconds = max(1, date.timeIntervalSinceNow)
        center.add(UNNotificationRequest(identifier: id, content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)))
    }

    private func sentToday(_ id: String) -> Bool {
        UserDefaults.standard.string(forKey: "notified.\(id)") == DayKey.of(Date())
    }

    private func markSent(_ id: String) {
        UserDefaults.standard.set(DayKey.of(Date()), forKey: "notified.\(id)")
    }
}

// MARK: - Settings

struct NotificationsSection: View {
    @ObservedObject var notifier: Notifier

    var body: some View {
        Section {
            ForEach(Notifier.Kind.allCases) { kind in
                Toggle(isOn: Binding(get: { notifier.isOn(kind) },
                                     set: { notifier.enabled[kind] = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title)
                        Text(subtitle(kind)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !notifier.authorized && notifier.enabled.values.contains(true) {
                Button("Allow notifications") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.footnote)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Bedtime, the evening activity reminder and the weekly summary are scheduled ahead and arrive on time. Battery, inactivity and Symptom Radar need fresh data from the ring, so they go out when the app next checks in — right away while it's open, and on its background wake-ups otherwise.")
        }
    }

    private func subtitle(_ kind: Notifier.Kind) -> String {
        guard kind == .bedtime else { return kind.detail }
        if let guidance = notifier.bedtimeGuidance {
            return "Ideal bedtime \(Circadian.label(guidance.windowStart))–\(Circadian.label(guidance.windowEnd)); reminder an hour before"
        }
        return "Needs two weeks of nights to suggest a bedtime"
    }
}
