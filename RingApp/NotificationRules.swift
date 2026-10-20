import Foundation

// MARK: - Notification rules
//
// When each of Oura's notifications should go out, kept apart from the
// scheduling code so the decisions can be tested on their own. Timings follow
// Oura's support pages ("Managing Your Notifications", "Bedtime Guidance").

/// Oura's Bedtime Guidance: a bedtime window drawn from the nights that went
/// best — highest Sleep Scores, lowest resting heart rate — checked against
/// when you usually wake and how much sleep you need. Needs two weeks.
struct BedtimeGuidance: Equatable {
    static let minimumNights = 14
    static let windowHalfWidth = 0.375           // a 45-minute window

    /// Circadian hours: evening negative, so 22:30 is −1.5.
    let windowStart: Double
    let windowEnd: Double
    let fromBestNights: Bool

    var center: Double { (windowStart + windowEnd) / 2 }

    static func compute(history: [DailyMetrics], sleepScores: [String: Int],
                        sleepNeedMinutes: Double, through dayKey: String) -> BedtimeGuidance? {
        let keys = Set(dayKeys(endingOn: dayKey, count: 30))
        let nights = history.filter { keys.contains($0.dayKey) && $0.bedtime != nil && $0.wakeTime != nil }
        guard nights.count >= minimumNights else { return nil }

        let typicalWake = HRV.median(nights.compactMap { $0.wakeTime.map(Circadian.hour) })
        // The latest bedtime that still fits your sleep need before you usually
        // wake, with 15 minutes to fall asleep.
        let latestFitting = typicalWake - sleepNeedMinutes / 60 - 0.25

        // Best nights: top third of sleep scores, and resting heart rate no
        // higher than usual.
        let scored = nights.compactMap { m in sleepScores[m.dayKey].map { (m, $0) } }
        let cutoff = scored.map(\.1).sorted().dropFirst(scored.count * 2 / 3).first ?? Int.max
        let typicalRHR = HRV.median(nights.compactMap(\.restingHR))
        let best = scored.filter { m, score in
            score >= cutoff && (m.restingHR.map { $0 <= typicalRHR } ?? true)
        }.compactMap { $0.0.bedtime.map(Circadian.hour) }

        let center: Double
        if best.count >= 5 {
            // Your best nights' bedtime, unless it can't fit your sleep need.
            center = min(HRV.median(best), latestFitting)
        } else {
            center = latestFitting
        }
        return BedtimeGuidance(windowStart: center - windowHalfWidth, windowEnd: center + windowHalfWidth,
                               fromBestNights: best.count >= 5)
    }
}

enum NotificationRules {

    /// Oura needs at least 30% to record a full night.
    static let lowBattery = 30

    /// Battery: 2–3 hours before bedtime when the ring is too low to last the
    /// night. Returns when to send, or nil if no alert is needed. If that
    /// moment has passed but bedtime hasn't, send now.
    static func batteryAlert(level: Int, isCharging: Bool, bedtime: Date, now: Date) -> Date? {
        guard level < lowBattery, !isCharging, now < bedtime else { return nil }
        let planned = bedtime.addingTimeInterval(-2.5 * 3600)
        return max(planned, now.addingTimeInterval(5))
    }

    /// Inactivity: after 50 minutes still, as Oura does. Only judged on fresh
    /// step data, while you're up for the day, and with signs the ring is
    /// being worn — a ring on the nightstand isn't "inactive".
    static func shouldAlertInactivity(buckets: [StepBucket], now: Date, awakeSince: Date,
                                      quietFrom: Date, lastAlert: Date?, lastStepFetch: Date?) -> Bool {
        let fiftyMinutes: TimeInterval = 50 * 60
        guard now >= awakeSince.addingTimeInterval(fiftyMinutes), now < quietFrom,
              let fetched = lastStepFetch, now.timeIntervalSince(fetched) < 20 * 60 else { return false }
        if let lastAlert, now.timeIntervalSince(lastAlert) < fiftyMinutes { return false }
        // The ring's 15-minute slots that overlap the last 50 minutes.
        let recent = buckets.filter { $0.time > now.addingTimeInterval(-fiftyMinutes - 15 * 60) && $0.time <= now }
        let recentSteps = recent.reduce(0) { $0 + $1.steps }
        // Worn recently: some movement within the last three hours.
        let worn = buckets.contains { $0.time > now.addingTimeInterval(-3 * 3600) && $0.steps > 0 }
        return worn && recentSteps < 80
    }

    /// Activity progress: where you are against today's goal, and what it
    /// would take to close the gap (about 100 steps a minute walking).
    static func progressMessage(steps: Double, goal: Double) -> String {
        let remaining = max(0, goal - steps)
        let minutes = Int((remaining / 100 / 5).rounded(.up)) * 5
        return "You're at \(Int(steps).formatted()) of \(Int(goal).formatted()) steps. A \(minutes)-minute walk would get you there."
    }

    /// Insights: a weekly summary of the week that just ended, against the
    /// week before.
    static func weeklySummary(readiness: [Int], previousReadiness: [Int], sleep: [Int],
                              steps: [Double]) -> String? {
        guard readiness.count >= 3 || sleep.count >= 3 else { return nil }
        var parts: [String] = []
        if readiness.count >= 3 {
            let avg = Int(HRV.mean(readiness.map(Double.init)).rounded())
            var text = "Readiness averaged \(avg)"
            if previousReadiness.count >= 3 {
                let change = avg - Int(HRV.mean(previousReadiness.map(Double.init)).rounded())
                if change != 0 { text += " (\(change > 0 ? "up" : "down") \(abs(change)))" }
            }
            parts.append(text)
        }
        if sleep.count >= 3 {
            parts.append("sleep score \(Int(HRV.mean(sleep.map(Double.init)).rounded()))")
        }
        if steps.count >= 3 {
            parts.append("\(Int(HRV.mean(steps)).formatted()) steps a day")
        }
        return "Last week: " + parts.joined(separator: ", ") + "."
    }
}
