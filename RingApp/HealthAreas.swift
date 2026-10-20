import Foundation

// MARK: - Health areas
//
// Oura's My Health tab rates each health area on a four-step scale and keeps
// 90 days of those ratings. What each rating rests on follows Oura's help
// pages; where Oura doesn't publish a cut-off, the mapping here is ours and
// says so.

enum HealthRating: Int, CaseIterable, Comparable {
    case needsCare, worthWatching, lookingGood, thriving

    var label: String {
        switch self {
        case .thriving:      return "Thriving"
        case .lookingGood:   return "Looking Good"
        case .worthWatching: return "Worth Watching"
        case .needsCare:     return "Needs Care"
        }
    }

    /// Oura's one-line meaning for each step.
    var meaning: String {
        switch self {
        case .thriving:      return "This area looks fantastic."
        case .lookingGood:   return "A very nice place to be."
        case .worthWatching: return "Worth keeping an eye on."
        case .needsCare:     return "This area could use some extra care."
        }
    }

    static func < (a: HealthRating, b: HealthRating) -> Bool { a.rawValue < b.rawValue }
}

/// Weekly metrics refresh on Mondays, as Oura's do once a week.
enum HealthWeek {
    private static var calendar: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = .current
        return c
    }

    /// The Monday on or before a day.
    static func updateDay(for dayKey: String) -> String {
        guard let date = DayKey.date(dayKey),
              let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { return dayKey }
        return DayKey.of(start)
    }

    /// Update days for the last `weeks` weeks, oldest first, ending at the
    /// week containing `dayKey`.
    static func updateDays(through dayKey: String, weeks: Int) -> [String] {
        guard let latest = DayKey.date(updateDay(for: dayKey)) else { return [] }
        return (0..<weeks).reversed().compactMap {
            calendar.date(byAdding: .day, value: -7 * $0, to: latest).map(DayKey.of)
        }
    }
}

/// Day keys from `days − 1` days before a day through the day itself.
func dayKeys(endingOn dayKey: String, count: Int) -> [String] {
    guard let end = DayKey.date(dayKey) else { return [] }
    return (0..<count).reversed().compactMap {
        Calendar.current.date(byAdding: .day, value: -$0, to: end).map(DayKey.of)
    }
}

// MARK: - Sleep Health

/// Oura: rated on your median Sleep Score from the past 14 days, so one
/// unusually good or rough night won't swing it. Needs 7 scores.
enum SleepHealth {
    static let windowDays = 14
    static let minimumScores = 7

    static func typicalScore(_ scores: [String: Int], through dayKey: String) -> Int? {
        let values = dayKeys(endingOn: dayKey, count: windowDays).compactMap { scores[$0] }
        guard values.count >= minimumScores else { return nil }
        return Int(HRV.median(values.map(Double.init)).rounded())
    }

    /// Oura doesn't publish the cut-offs; these follow its Sleep Score bands.
    static func rating(_ typical: Int) -> HealthRating {
        switch typical {
        case 85...:   return .thriving
        case 70..<85: return .lookingGood
        case 60..<70: return .worthWatching
        default:      return .needsCare
        }
    }
}

/// Oura's chronotype: when you're naturally inclined to sleep, from 90 days
/// with at least 30 main sleeps. Oura's six types; the mapping from sleep
/// midpoint to type is ours (population mid-sleep averages about 3:30–4 AM).
struct Chronotype {
    enum Kind: CaseIterable {
        case earlyMorning, morning, lateMorning, earlyEvening, evening, lateEvening

        var label: String {
            switch self {
            case .earlyMorning: return "Early morning type"
            case .morning:      return "Morning type"
            case .lateMorning:  return "Late morning type"
            case .earlyEvening: return "Early evening type"
            case .evening:      return "Evening type"
            case .lateEvening:  return "Late evening type"
            }
        }

        var detail: String {
            switch self {
            case .earlyMorning, .morning:
                return "You're naturally inclined to sleep and wake early, and tend to be sharpest in the morning."
            case .lateMorning, .earlyEvening:
                return "You sit near the middle: mornings and evenings both work, with a slight lean one way."
            case .evening, .lateEvening:
                return "You're naturally inclined to sleep and wake later, and tend to come alive later in the day."
            }
        }
    }

    static let windowDays = 90
    static let minimumNights = 30

    let kind: Kind
    let midpointHour: Double
    let nights: Int

    static func compute(_ history: [DailyMetrics], through dayKey: String) -> Chronotype? {
        let keys = Set(dayKeys(endingOn: dayKey, count: windowDays))
        let midpoints = history
            .filter { keys.contains($0.dayKey) && ($0.asleepMinutes ?? 0) >= 180 }
            .compactMap { $0.sleepMidpoint.map(Circadian.hour) }
        guard midpoints.count >= minimumNights else { return nil }
        let mid = HRV.mean(midpoints)
        let kind: Kind
        switch mid {
        case ..<2.0:  kind = .earlyMorning
        case ..<3.0:  kind = .morning
        case ..<3.75: kind = .lateMorning
        case ..<4.5:  kind = .earlyEvening
        case ..<5.5:  kind = .evening
        default:      kind = .lateEvening
        }
        return Chronotype(kind: kind, midpointHour: mid, nights: midpoints.count)
    }
}

// MARK: - Heart Health

/// Oura's weekly Cardiovascular Age: built from the past 30 nights, needing
/// 14, classed against your actual age. Oura derives it from pulse wave
/// velocity; here it averages the daily cardiovascular index, which comes
/// from resting heart rate, HRV and blood oxygen instead.
struct CardiovascularAgeReading {
    enum Range: String {
        case below = "Below", aligned = "Aligned", above = "Above"

        var detail: String {
            switch self {
            case .below:   return "6 or more years below your actual age"
            case .aligned: return "Within 5 years of your actual age"
            case .above:   return "6 or more years above your actual age"
            }
        }
    }

    static let windowDays = 30
    static let minimumNights = 14

    let asOf: String
    let age: Double
    let chronologicalAge: Int
    let nights: Int

    var delta: Double { age - Double(chronologicalAge) }

    var range: Range {
        if delta <= -6 { return .below }
        if delta >= 6 { return .above }
        return .aligned
    }

    /// Heart Health's rating. Oura's scale is Needs Care to Thriving; the
    /// step past "Above" is ours.
    var rating: HealthRating {
        switch range {
        case .below:   return .thriving
        case .aligned: return .lookingGood
        case .above:   return delta >= 10 ? .needsCare : .worthWatching
        }
    }

    static func weekly(daily: [String: Double], chronologicalAge: Int, asOf: String) -> CardiovascularAgeReading? {
        let ages = dayKeys(endingOn: asOf, count: windowDays).compactMap { daily[$0] }
        guard ages.count >= minimumNights else { return nil }
        return CardiovascularAgeReading(asOf: asOf, age: HRV.mean(ages),
                                        chronologicalAge: chronologicalAge, nights: ages.count)
    }
}

// MARK: - Cumulative stress
//
// Oura: strain built up over the past 31 days, updated weekly, needing 21
// days of data, rated low / moderate / high from five contributors. Four are
// approximated from what this ring logs; sleep micromotions needs raw
// accelerometer data the ring doesn't expose, so it's left out.

struct CumulativeStress {
    enum Level: String {
        case low = "Low", moderate = "Moderate", high = "High"
    }

    static let windowDays = 31
    static let minimumDays = 21

    let asOf: String
    let score: Int                      // 0–100, higher = less strain
    let contributors: [Contributor]
    let days: Int

    var level: Level {
        switch score {
        case 75...:   return .low
        case 55..<75: return .moderate
        default:      return .high
        }
    }

    /// Stress Management's rating, from the latest Cumulative Stress.
    var rating: HealthRating {
        switch level {
        case .low:      return score >= 85 ? .thriving : .lookingGood
        case .moderate: return .worthWatching
        case .high:     return .needsCare
        }
    }

    static func compute(history: [DailyMetrics], activity: [ActivityDay],
                        asOf dayKey: String) -> CumulativeStress? {
        let keys = Set(dayKeys(endingOn: dayKey, count: windowDays))
        let window = history.filter { keys.contains($0.dayKey) }.sorted { $0.dayKey < $1.dayKey }
        let nights = window.filter { $0.asleepMinutes != nil }
        guard nights.count >= minimumDays else { return nil }
        var parts: [(Contributor, Double)] = []

        // Sleep continuity: how often sleep was broken, and how much of the
        // night was spent awake.
        let wakeUps = nights.compactMap(\.awakenings).map(Double.init)
        let efficiency = nights.compactMap(\.sleepEfficiency)
        if !wakeUps.isEmpty, !efficiency.isEmpty {
            let w = HRV.mean(wakeUps), e = HRV.mean(efficiency)
            let score = (curve(w, [(1, 100), (2, 90), (3, 78), (5, 55), (8, 25)])
                         + curve(e, [(0.70, 25), (0.80, 55), (0.85, 72), (0.90, 88), (0.95, 100)])) / 2
            parts.append((Contributor(name: "Sleep continuity", score: score,
                                      detail: String(format: "%.1f wake-ups · %.0f%% efficient", w, e * 100)), 0.25))
        }

        // Heart stress-response: the month's resting heart rate and HRV
        // against the two months before it.
        if let first = window.first?.dayKey {
            let prior = Baseline.window(history, before: first)
            let rhrPrior = Baseline(prior.compactMap(\.restingHR))
            let hrvPrior = Baseline(prior.compactMap(\.rmssd))
            var shifts: [Double] = []
            if let b = rhrPrior, b.count >= 14, case let v = window.compactMap(\.restingHR), v.count >= 7 {
                shifts.append((HRV.mean(v) - b.mean) / max(b.sd, 1.5))
            }
            if let b = hrvPrior, b.count >= 14, case let v = window.compactMap(\.rmssd), v.count >= 7 {
                shifts.append((b.mean - HRV.mean(v)) / max(b.sd, b.mean * 0.1))
            }
            if !shifts.isEmpty {
                let shift = HRV.mean(shifts)
                parts.append((Contributor(name: "Heart stress-response",
                                          score: curve(shift, [(-0.5, 100), (0, 90), (0.5, 72), (1.0, 55), (1.5, 40), (2.5, 15)]),
                                          detail: shift > 0.25 ? "Strained vs before" : "Steady vs before"), 0.35))
            }
        }

        // Temperature regulation: how much night temperature swung.
        let temps = window.compactMap(\.nightTemperature)
        if temps.count >= 7 {
            let sd = HRV.standardDeviation(temps)
            parts.append((Contributor(name: "Temperature regulation",
                                      score: curve(sd, [(0.12, 100), (0.2, 85), (0.3, 65), (0.4, 45), (0.6, 20)]),
                                      detail: "Varies " + Format.temperatureSpread(sd)), 0.20))
        }

        // Activity impact: HRV the night after your bigger days. A body
        // that's carrying stress recovers less well from exertion.
        let steps = Dictionary(uniqueKeysWithValues: activity.filter { keys.contains($0.dayKey) }
            .map { ($0.dayKey, $0.steps) })
        let hrv = window.compactMap(\.rmssd)
        if steps.count >= 14, hrv.count >= 14 {
            let typical = HRV.median(Array(steps.values))
            let hrvMean = HRV.mean(hrv), hrvSD = max(HRV.standardDeviation(hrv), hrvMean * 0.1)
            let byDay = Dictionary(uniqueKeysWithValues: window.compactMap { m in m.rmssd.map { (m.dayKey, $0) } })
            let after = steps.filter { $0.value >= max(typical * 1.4, 8_000) }.compactMap { key, _ -> Double? in
                guard let next = DayKey.date(key)
                        .flatMap({ Calendar.current.date(byAdding: .day, value: 1, to: $0) })
                        .map(DayKey.of),
                      let value = byDay[next] else { return nil }
                return (value - hrvMean) / hrvSD
            }
            if after.count >= 3 {
                let z = HRV.mean(after)
                parts.append((Contributor(name: "Activity impact",
                                          score: curve(z, [(-1.2, 30), (-0.8, 50), (-0.4, 75), (0, 95), (0.2, 100)]),
                                          detail: "\(after.count) bigger days"), 0.20))
            }
        }

        guard parts.count >= 2,
              let combined = Score(weights: parts, isProvisional: false) else { return nil }
        return CumulativeStress(asOf: dayKey, score: combined.value,
                                contributors: combined.inOrder, days: nights.count)
    }
}

// MARK: - Trends

/// Oura's Trends: a metric by day, week, month or year. The big number is the
/// latest period; the small one the average — 90 days in Day view, all of
/// your data otherwise.
enum TrendSpan: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month", year = "Year"
    var id: String { rawValue }
}

struct TrendPoint: Identifiable {
    let start: Date
    let value: Double
    var id: Date { start }
}

enum Trends {
    static func aggregate(_ daily: [String: Double], span: TrendSpan,
                          through end: Date = Date()) -> [TrendPoint] {
        let cal = Calendar.current
        let dated = daily.compactMap { key, value in DayKey.date(key).map { ($0, value) } }
            .filter { $0.0 <= end }
        func group(_ component: Calendar.Component, last count: Int?) -> [TrendPoint] {
            var buckets: [Date: [Double]] = [:]
            for (date, value) in dated {
                guard let start = cal.dateInterval(of: component, for: date)?.start else { continue }
                buckets[start, default: []].append(value)
            }
            let points = buckets.map { TrendPoint(start: $0.key, value: HRV.mean($0.value)) }
                .sorted { $0.start < $1.start }
            return count.map { Array(points.suffix($0)) } ?? points
        }
        switch span {
        case .day:
            guard let from = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: end)) else { return [] }
            return dated.filter { $0.0 >= from }.map { TrendPoint(start: $0.0, value: $0.1) }
                .sorted { $0.start < $1.start }
        case .week:  return group(.weekOfYear, last: 26)
        case .month: return group(.month, last: 12)
        case .year:  return group(.year, last: nil)
        }
    }

    static func average(_ daily: [String: Double], span: TrendSpan, through end: Date = Date()) -> Double? {
        let values: [Double]
        if span == .day, let from = Calendar.current.date(byAdding: .day, value: -89, to: end) {
            values = daily.compactMap { key, value in
                DayKey.date(key).flatMap { $0 >= from && $0 <= end ? value : nil }
            }
        } else {
            values = Array(daily.values)
        }
        return values.isEmpty ? nil : HRV.mean(values)
    }
}
