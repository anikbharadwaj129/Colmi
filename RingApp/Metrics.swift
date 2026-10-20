import Foundation

// MARK: - HRV

enum HRV {

    /// Drops implausible intervals and ectopic beats: anything more than
    /// `tolerance` from the running median.
    static func clean(_ rr: [Int], tolerance: Double = 0.2) -> [Int] {
        let plausible = rr.filter { $0 > 300 && $0 < 2000 }
        guard plausible.count > 4 else { return plausible }
        let m = median(plausible.map(Double.init))
        return plausible.filter { abs(Double($0) - m) / m <= tolerance }
    }

    static func rmssd(_ rr: [Int]) -> Double? {
        let c = clean(rr)
        guard c.count >= 10 else { return nil }
        let diffs = zip(c.dropFirst(), c).map { Double($0 - $1) }
        return (diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count)).squareRoot()
    }

    /// Apple Health's HRV field means SDNN, so that's what gets written there.
    static func sdnn(_ rr: [Int]) -> Double? {
        let c = clean(rr)
        guard c.count >= 10 else { return nil }
        return standardDeviation(c.map(Double.init))
    }

    static func meanHeartRate(_ rr: [Int]) -> Double? {
        let c = clean(rr)
        guard !c.isEmpty else { return nil }
        return 60_000 / (Double(c.reduce(0, +)) / Double(c.count))
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted(), mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    static func mean(_ v: [Double]) -> Double {
        v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }

    static func standardDeviation(_ v: [Double]) -> Double {
        guard v.count > 1 else { return 0 }
        let m = mean(v)
        return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count - 1)).squareRoot()
    }
}

// MARK: - Capture

struct CaptureSession: Codable, Identifiable {
    /// What the stream was for. Sessions saved before kinds existed decode as
    /// nil and are treated as plain captures.
    enum Kind: String, Codable {
        case capture        // overnight window or debug stream
        case spotCheck      // Live heart rate, ~10 s
        case session        // unguided session — still, resting
        case workout        // recorded workout heart rate
    }

    enum Feeling: String, Codable, CaseIterable {
        case worse, same, better

        var label: String {
            switch self {
            case .worse:  return "Worse"
            case .same:   return "About the same"
            case .better: return "Better"
            }
        }
    }

    var id: String { DayKey.iso(started) }
    let started: Date
    let ended: Date
    let subtype: UInt8
    let rrIntervals: [Int]
    let heartRates: [Int]
    var kind: Kind? = nil
    var activity: String? = nil     // workouts only
    var feeling: Feeling? = nil     // unguided sessions only

    var resolvedKind: Kind { kind ?? .capture }
    var dayKey: String { DayKey.of(started) }
    var duration: TimeInterval { ended.timeIntervalSince(started) }
    var rmssd: Double? { HRV.rmssd(rrIntervals) }
    var sdnn: Double? { HRV.sdnn(rrIntervals) }
    var meanHR: Double? {
        let valid = validHeartRates
        guard !valid.isEmpty else { return HRV.meanHeartRate(rrIntervals) }
        return Double(valid.reduce(0, +)) / Double(valid.count)
    }

    /// Still captures feed resting heart rate; spot checks and workouts don't.
    var isResting: Bool { resolvedKind == .capture || resolvedKind == .session }

    var validHeartRates: [Int] { heartRates.filter { $0 > 30 && $0 < 220 } }

    var maxHR: Int? { validHeartRates.max() }

    /// Where the reading settled: the median of the last few values, since
    /// the first ones are the ring locking on.
    var settledHR: Int? {
        let tail = validHeartRates.suffix(5).map(Double.init)
        if !tail.isEmpty { return Int(HRV.median(tail).rounded()) }
        // No heart rate field, but beats: the rate is 60,000 / interval.
        let beats = HRV.clean(rrIntervals).suffix(10).map(Double.init)
        guard beats.count >= 3 else { return nil }
        return Int((60_000 / HRV.median(Array(beats))).rounded())
    }

    /// The lowest stretch rather than the lowest beat, so one long RR interval
    /// can't pass for a resting heart rate.
    var lowestHR: Double? {
        let fromRR = HRV.clean(rrIntervals).map { 60_000 / Double($0) }
        let series = fromRR.count >= 20 ? fromRR : validHeartRates.map(Double.init)
        let window = series.count >= 20 ? 15 : 3
        guard series.count >= window else { return series.min() }
        return (0...(series.count - window))
            .map { HRV.mean(Array(series[$0..<($0 + window)])) }
            .min()
    }

    /// Readings carry no timestamps of their own, so they're spread evenly
    /// across the session.
    var heartRateTrack: [(Date, Double)] {
        let values = validHeartRates
        guard !values.isEmpty else { return [] }
        let step = duration / Double(max(values.count - 1, 1))
        return values.enumerated().map {
            (started.addingTimeInterval(Double($0.offset) * step), Double($0.element))
        }
    }

    /// RMSSD over successive 60-beat windows, timed by the beats themselves.
    var hrvTrack: [(Date, Double)] {
        let rr = HRV.clean(rrIntervals)
        guard rr.count >= 60 else { return [] }
        var out: [(Date, Double)] = []
        for start in stride(from: 0, to: rr.count - 59, by: 30) {
            let window = Array(rr[start..<(start + 60)])
            let elapsed = Double(rr[..<(start + 60)].reduce(0, +)) / 1000
            if let value = HRV.rmssd(window) {
                out.append((started.addingTimeInterval(elapsed), value))
            }
        }
        return out
    }
}

// MARK: - Heart rate zones

/// Five zones as fractions of an age-predicted maximum (208 − 0.7 × age, the
/// same estimate the VO₂max figure uses).
struct HeartZones {
    let maxHR: Double

    init?(age: Int?) {
        guard let age else { return nil }
        maxHR = 208 - 0.7 * Double(age)
    }

    static let names = ["Very light", "Light", "Moderate", "Hard", "Maximum"]

    /// 1–5, or 0 below zone 1.
    func zone(_ bpm: Double) -> Int {
        let fraction = bpm / maxHR
        switch fraction {
        case ..<0.5: return 0
        case ..<0.6: return 1
        case ..<0.7: return 2
        case ..<0.8: return 3
        case ..<0.9: return 4
        default:     return 5
        }
    }

    func range(_ zone: Int) -> ClosedRange<Int> {
        let low = 0.4 + Double(zone) * 0.1
        return Int(maxHR * low)...Int(maxHR * (low + 0.1))
    }

    /// Seconds in each of zones 1–5, index 0 being zone 1.
    func timeInZones(_ session: CaptureSession) -> [TimeInterval] {
        let values = session.validHeartRates
        guard !values.isEmpty else { return Array(repeating: 0, count: 5) }
        let each = session.duration / Double(values.count)
        var out = Array(repeating: 0.0, count: 5)
        for bpm in values {
            let z = zone(Double(bpm))
            if z > 0 { out[z - 1] += each }
        }
        return out
    }
}

// MARK: - Daily roll-up

struct DailyMetrics: Codable, Identifiable {
    let dayKey: String
    var id: String { dayKey }

    var restingHR: Double?
    var rmssd: Double?
    var nightTemperature: Double?
    var spo2Average: Double?
    var spo2Low: Double?
    var asleepMinutes: Int?
    var sleepEfficiency: Double?
    var deepMinutes: Int?
    var remMinutes: Int?
    var awakenings: Int?
    var sleepMidpoint: Date?
    var bedtime: Date?
    var wakeTime: Date?
    var stressAverage: Double?
    var stressPeak: Double?
    var respiratoryRate: Double?    // breaths/min, from beat-to-beat captures
    var lowestHRTime: Date?         // middle of the night's lowest 15 minutes
    var inactiveMinutes: Double?    // awake, ring on, under 25 steps per 15 min

    init(dayKey: String) { self.dayKey = dayKey }
}

// MARK: - Baseline

struct Baseline {
    let mean: Double
    let sd: Double
    let count: Int

    var isReliable: Bool { count >= 14 }

    init?(_ values: [Double]) {
        let valid = values.filter(\.isFinite)
        guard valid.count >= 3 else { return nil }
        mean = HRV.mean(valid)
        sd = HRV.standardDeviation(valid)
        count = valid.count
    }

    func z(_ value: Double) -> Double { sd > 0.001 ? (value - mean) / sd : 0 }

    /// Your long-term normal is the two months before a day, not counting the
    /// day itself — Oura's long-term window. All of history would let an old
    /// illness or fitness change keep skewing today's verdict.
    static let windowDays = 60

    static func window(_ history: [DailyMetrics], before dayKey: String,
                       days: Int = windowDays) -> [DailyMetrics] {
        guard let date = DayKey.date(dayKey),
              let start = Calendar.current.date(byAdding: .day, value: -days, to: date)
        else { return history.filter { $0.dayKey < dayKey } }
        let from = DayKey.of(start)
        return history.filter { $0.dayKey >= from && $0.dayKey < dayKey }
    }
}

/// Oura's "balance" contributors: the last 14 days, with recent days counting
/// a little more — each day back weighs 5% less.
enum Balance {
    static let days = 14

    static func weightedAverage(_ history: [DailyMetrics], through dayKey: String,
                                _ value: (DailyMetrics) -> Double?) -> (average: Double, count: Int)? {
        weightedAverage(history.compactMap { m in value(m).map { (m.dayKey, $0) } }, through: dayKey)
    }

    static func weightedAverage(_ series: [(dayKey: String, value: Double)],
                                through dayKey: String) -> (average: Double, count: Int)? {
        guard let end = DayKey.date(dayKey),
              let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: end)
        else { return nil }
        let from = DayKey.of(start)
        var sum = 0.0, weights = 0.0, count = 0
        for (key, v) in series where key >= from && key <= dayKey {
            guard let date = DayKey.date(key),
                  let age = Calendar.current.dateComponents([.day], from: date, to: end).day,
                  (0..<days).contains(age) else { continue }
            let w = pow(0.95, Double(age))
            sum += v * w
            weights += w
            count += 1
        }
        return count > 0 ? (sum / weights, count) : nil
    }
}

// MARK: - Score model

enum ScoreBand: String {
    case optimal      = "Optimal"
    case good         = "Good"
    case fair         = "Fair"
    case payAttention = "Pay attention"

    init(_ score: Int) {
        switch score {
        case 85...:   self = .optimal
        case 70..<85: self = .good
        case 60..<70: self = .fair
        default:      self = .payAttention
        }
    }
}

struct Contributor: Identifiable {
    let name: String
    let score: Int
    let detail: String
    var id: String { name }
    var band: ScoreBand { ScoreBand(score) }
}

struct Score {
    let value: Int
    let contributors: [Contributor]      // weakest first
    let inOrder: [Contributor]           // as listed, for display
    let isProvisional: Bool

    var band: ScoreBand { ScoreBand(value) }

    init?(weights: [(Contributor, Double)], isProvisional: Bool) {
        guard !weights.isEmpty else { return nil }
        let total = weights.reduce(0) { $0 + $1.1 }
        value = Int((weights.reduce(0.0) { $0 + Double($1.0.score) * $1.1 } / total).rounded())
        inOrder = weights.map(\.0)
        contributors = inOrder.sorted { $0.score < $1.score }
        self.isProvisional = isProvisional
    }
}

func ramp(_ value: Double, floor: Double, target: Double) -> Int {
    guard target != floor else { return 100 }
    return Int((max(0, min(1, (value - floor) / (target - floor))) * 100).rounded())
}

/// Piecewise-linear score through (input, score) points, flat past either end.
func curve(_ x: Double, _ points: [(Double, Double)]) -> Int {
    guard let first = points.first, let last = points.last else { return 0 }
    if x <= first.0 { return Int(first.1.rounded()) }
    if x >= last.0 { return Int(last.1.rounded()) }
    for (a, b) in zip(points, points.dropFirst()) where x <= b.0 {
        return Int((a.1 + (b.1 - a.1) * (x - a.0) / (b.0 - a.0)).rounded())
    }
    return Int(last.1.rounded())
}

func closeness(_ value: Double, ideal: Double, tolerance: Double) -> Int {
    Int((max(0, 1 - abs(value - ideal) / tolerance / 3) * 100).rounded())
}

// MARK: - Sleep score

enum SleepScore {

    static func compute(night: SleepNight, history: [DailyMetrics]) -> Score? {
        var parts: [(Contributor, Double)] = []

        let asleep = Double(night.asleepMinutes)
        parts.append((Contributor(name: "Total sleep",
                                  score: ramp(asleep, floor: 240, target: 480),
                                  detail: Format.duration(night.asleepMinutes)), 0.25))

        let efficiency = night.efficiency * 100
        parts.append((Contributor(name: "Efficiency",
                                  score: ramp(efficiency, floor: 70, target: 95),
                                  detail: "\(Int(efficiency))%"), 0.20))

        let awakeMinutes = night.minutes(in: .awake)
        let awakenings = night.segments.filter { $0.stage == .awake }.count
        parts.append((Contributor(name: "Restfulness",
                                  score: min(100, max(0, 100 - awakenings * 8 - awakeMinutes)),
                                  detail: "\(awakenings) wake-ups"), 0.15))

        let rem = Double(night.minutes(in: .rem))
        parts.append((Contributor(name: "REM sleep",
                                  score: ramp(rem, floor: 0, target: 90),
                                  detail: Format.duration(Int(rem))), 0.15))

        let deep = Double(night.minutes(in: .deep))
        parts.append((Contributor(name: "Deep sleep",
                                  score: ramp(deep, floor: 0, target: 75),
                                  detail: Format.duration(Int(deep))), 0.15))

        let midpoint = night.midpoint
        let usual = Circadian.usualMidpoints(history, before: night.dayKey)
        let ideal = usual.count >= 5 ? HRV.mean(usual) : 3.0
        parts.append((Contributor(name: "Timing",
                                  score: closeness(Circadian.hour(midpoint), ideal: ideal, tolerance: 1.0),
                                  detail: "Midpoint " + Format.time(midpoint)), 0.10))

        return Score(weights: parts, isProvisional: usual.count < 5)
    }
}

// MARK: - Readiness

enum ReadinessScore {

    // Oura's nine contributors and how its Readiness article and support
    // pages describe each. Oura publishes neither weights nor curves, so those
    // are ours, shaped around the points it does publish. Weights lean on the
    // body-stress signals and the trend ("balance") contributors, which Oura
    // says the score emphasises; a contributor without data drops out and the
    // rest rescale. Curves put a normal night in the high 80s to mid 90s —
    // Oura: "100s are designed to be rare" — and only better than usual earns
    // 100. A weak contributor counts up to double, so one bad signal isn't
    // averaged away by six fine ones.
    static let weights: [String: Double] = [
        "Resting heart rate": 0.16, "HRV balance": 0.18, "Body temperature": 0.14,
        "Recovery index": 0.10, "Sleep": 0.11, "Sleep balance": 0.10,
        "Sleep regularity": 0.05, "Previous day activity": 0.07, "Activity balance": 0.09,
    ]

    /// The AASM's 7–9 hours for adults, which Oura's Sleep balance also checks.
    static let recommendedSleep = 420.0...540.0

    static func compute(today: DailyMetrics,
                        sleepNeed: SleepNeed,
                        history: [DailyMetrics],
                        activity: [ActivityDay],
                        restMode: Bool) -> Score? {
        let twoMonths = Baseline.window(history, before: today.dayKey)
        let threeMonths = Baseline.window(history, before: today.dayKey, days: 90)
        var parts: [(Contributor, Double)] = []
        var provisional = !sleepNeed.isLearned
        func add(_ name: String, _ score: Int, _ detail: String) {
            let score = max(0, min(100, score))
            let emphasis = 1 + Double(100 - score) / 100
            parts.append((Contributor(name: name, score: score, detail: detail),
                          (weights[name] ?? 0.1) * emphasis))
        }
        let target = min(max(sleepNeed.minutes, recommendedSleep.lowerBound), recommendedSleep.upperBound)

        // Resting heart rate: last night's lowest against your two-month
        // average. Oura: it costs you when 3–5 bpm higher or 10–15 bpm lower
        // than usual. A little below usual is the best place to be.
        if let rhr = today.restingHR, let baseline = Baseline(twoMonths.compactMap(\.restingHR)) {
            if !baseline.isReliable { provisional = true }
            let delta = rhr - baseline.mean
            add("Resting heart rate",
                curve(delta, [(-15, 40), (-10, 80), (-5, 100), (0, 88), (3, 70), (5, 55), (8, 35),
                              (10, 25), (15, 10)]),
                String(format: "%.0f bpm · %+d vs usual", rhr, Int(delta.rounded())))
        }

        // HRV balance: 14-day weighted average against your three-month average.
        if let baseline = Baseline(threeMonths.compactMap(\.rmssd)), baseline.mean > 0,
           let recent = Balance.weightedAverage(history, through: today.dayKey, { $0.rmssd }) {
            if !baseline.isReliable { provisional = true }
            let change = (recent.average - baseline.mean) / baseline.mean * 100
            add("HRV balance",
                curve(change, [(-40, 10), (-25, 35), (-15, 55), (-10, 68), (-5, 80), (0, 90), (5, 97), (10, 100)]),
                String(format: "%.0f ms vs %.0f usual", recent.average, baseline.mean))
        }

        // Body temperature: last night against your long-term night average.
        // Higher counts against you sooner than lower, as Oura frames it.
        if let temp = today.nightTemperature,
           let baseline = Baseline(twoMonths.compactMap(\.nightTemperature)) {
            if !baseline.isReliable { provisional = true }
            let delta = temp - baseline.mean
            add("Body temperature",
                curve(delta, [(-1.5, 30), (-1.0, 55), (-0.6, 78), (-0.3, 92), (0, 95), (0.1, 95),
                              (0.3, 80), (0.5, 60), (0.8, 35), (1.0, 20), (1.5, 5)]),
                Format.temperatureDelta(delta))
        }

        // Recovery index: sleep after your heart rate bottomed out. Oura:
        // optimal is at least six hours.
        if let low = today.lowestHRTime, let wake = today.wakeTime, wake > low {
            let hours = wake.timeIntervalSince(low) / 3600
            add("Recovery index",
                curve(hours, [(0, 10), (2, 40), (4, 70), (5, 85), (6, 95), (7, 100)]),
                "\(Format.duration(Int(hours * 60))) after your low")
        }

        // Sleep: last night's total against what you need.
        if let asleep = today.asleepMinutes {
            add("Sleep",
                curve(Double(asleep) - target, [(-240, 10), (-180, 30), (-120, 55), (-60, 78), (-30, 88),
                                                (0, 93), (30, 100)]),
                "\(Format.duration(asleep)) of \(Format.duration(Int(target)))")
        }

        // Sleep balance: two weeks, recent nights weighted more, against your
        // need held inside the 7–9 hour recommendation.
        if let recent = Balance.weightedAverage(history, through: today.dayKey, {
            $0.asleepMinutes.map(Double.init)
        }), recent.count >= 3 {
            if recent.count < 7 { provisional = true }
            add("Sleep balance",
                curve(recent.average - target, [(-240, 10), (-150, 30), (-90, 55), (-60, 70), (-30, 84),
                                                (0, 93), (30, 100)]),
                "\(Format.duration(Int(recent.average))) avg · need \(Format.duration(Int(target)))")
        }

        // Sleep regularity: how much bedtime and wake time moved over two weeks.
        if let regularity = sleepRegularity(history, through: today.dayKey) {
            add("Sleep regularity",
                curve(regularity, [(15, 100), (30, 92), (45, 82), (60, 70), (90, 48), (120, 30), (180, 10)]),
                "Varies ±\(Int(regularity.rounded())) min")
        }

        // Activity contributors pause in Rest Mode, as Oura's do.
        if !restMode {
            if let previous = previousDayActivity(today: today, history: history, activity: activity) {
                add("Previous day activity", previous.score, previous.detail)
            }
            if let balance = activityBalance(through: today.dayKey, activity: activity) {
                add("Activity balance", balance.score, balance.detail)
            }
        }

        return Score(weights: parts, isProvisional: provisional)
    }

    /// Average spread (SD, minutes) of bedtime and wake time over the last 14
    /// nights (or `days`). Needs five.
    static func sleepRegularity(_ history: [DailyMetrics], through dayKey: String,
                                days: Int = 14) -> Double? {
        guard let end = DayKey.date(dayKey),
              let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: end) else { return nil }
        let from = DayKey.of(start)
        let nights = history.filter { $0.dayKey >= from && $0.dayKey <= dayKey }
        let beds = nights.compactMap { $0.bedtime.map(Circadian.hour) }
        let wakes = nights.compactMap { $0.wakeTime.map(Circadian.hour) }
        guard beds.count >= 5, wakes.count >= 5 else { return nil }
        return (HRV.standardDeviation(beds) + HRV.standardDeviation(wakes)) / 2 * 60
    }

    /// Yesterday's movement and sitting against your usual. Oura: optimal is
    /// five to eight hours or less of inactivity, and both an idle day and an
    /// unusually heavy one cost you.
    static func previousDayActivity(today: DailyMetrics, history: [DailyMetrics],
                                    activity: [ActivityDay]) -> (score: Int, detail: String)? {
        guard let yesterdayKey = DayKey.date(today.dayKey)
                .flatMap({ Calendar.current.date(byAdding: .day, value: -1, to: $0) })
                .map(DayKey.of) else { return nil }
        var scores: [Int] = []
        var details: [String] = []

        if let inactive = history.first(where: { $0.dayKey == yesterdayKey })?.inactiveMinutes {
            scores.append(curve(inactive / 60, [(5, 100), (8, 92), (9, 80), (10, 66), (11, 52), (12, 40), (14, 20)]))
            details.append("\(Format.duration(Int(inactive))) inactive")
        }
        if let yesterday = activity.first(where: { $0.dayKey == yesterdayKey }) {
            let usual = Baseline.windowedActivity(activity, before: yesterdayKey).map(\.steps)
            if usual.count >= 7, HRV.mean(usual) > 0 {
                let ratio = yesterday.steps / HRV.mean(usual)
                scores.append(curve(ratio, [(0.3, 40), (0.5, 62), (0.75, 85), (1.0, 95), (1.6, 95),
                                            (2.0, 82), (2.5, 68), (3.0, 52)]))
            }
            details.append("\(Int(yesterday.steps).formatted()) steps")
        }
        guard !scores.isEmpty else { return nil }
        return (Int(HRV.mean(scores.map(Double.init)).rounded()), details.joined(separator: " · "))
    }

    /// Your last 14 days of activity (recent days weighted more) against your
    /// two-month average. Too far below is under-load, too far above is
    /// over-load — the ratio sports scientists track as acute:chronic
    /// workload, whose comfortable band is about 0.8–1.3.
    static func activityBalance(through dayKey: String, activity: [ActivityDay]) -> (score: Int, detail: String)? {
        // Through yesterday: today's steps are still coming in.
        guard let yesterdayKey = DayKey.date(dayKey)
                .flatMap({ Calendar.current.date(byAdding: .day, value: -1, to: $0) })
                .map(DayKey.of) else { return nil }
        let longTerm = Baseline.windowedActivity(activity, before: dayKey)
        guard longTerm.count >= 21,
              let recent = Balance.weightedAverage(activity.map { ($0.dayKey, $0.steps) }, through: yesterdayKey),
              recent.count >= 5 else { return nil }
        let usual = HRV.mean(longTerm.map(\.steps))
        guard usual > 0 else { return nil }
        let ratio = recent.average / usual
        return (curve(ratio, [(0.4, 40), (0.6, 68), (0.8, 92), (1.0, 95), (1.3, 92), (1.5, 78), (2.0, 45), (2.5, 25)]),
                "\(Int(recent.average).formatted()) steps/day vs \(Int(usual).formatted()) usual")
    }
}

extension Baseline {
    /// Activity days in the two months before a day.
    static func windowedActivity(_ activity: [ActivityDay], before dayKey: String,
                                 days: Int = windowDays) -> [ActivityDay] {
        guard let date = DayKey.date(dayKey),
              let start = Calendar.current.date(byAdding: .day, value: -days, to: date) else { return [] }
        let from = DayKey.of(start)
        return activity.filter { $0.dayKey >= from && $0.dayKey < dayKey }
    }
}

// MARK: - Activity
//
// Steps and distance come from the ring's 15-minute buckets (0x43).

struct ActivityDay {
    let dayKey: String
    var steps: Double = 0
    var metres: Double = 0
    var activeCalories: Double = 0      // 0 until a weight is set

    init(dayKey: String, buckets: [StepBucket], weightKg: Double?) {
        self.dayKey = dayKey
        steps = Double(buckets.reduce(0) { $0 + $1.steps })
        metres = Double(buckets.reduce(0) { $0 + $1.metres })
        if let weightKg {
            activeCalories = buckets.reduce(0) { $0 + ActiveEnergy.kcal($1, weightKg: weightKg) }
        }
    }
}

/// Active calories — on top of resting burn — from steps and distance.
///
/// MET route: kcal/min = MET × 3.5 × kg / 200, where MET × 3.5 is oxygen use
/// (mL/kg/min). ACSM's walking equation puts that at 3.5 + 0.1 × speed
/// (m/min); the 3.5 is rest, so the active part is 0.1 × speed. Over a stretch
/// of walking, speed × minutes is just distance, so
///     active kcal = 0.1 × metres × kg / 200 = 0.0005 × metres × kg.
/// Duration drops out — which is what makes this workable, since a bucket
/// says how far you went in 15 minutes but not for how long you moved.
/// The rough steps × kg × 0.0005 is the same sum assuming a metre per step;
/// with the ring's measured ~0.75 m stride it overstates by about a third.
/// Running costs about twice the oxygen per metre (0.2 × speed).
enum ActiveEnergy {
    /// Used when a bucket has steps but no distance.
    static let fallbackStride = 0.75

    static func kcal(_ bucket: StepBucket, weightKg: Double) -> Double {
        guard bucket.steps > 0 else { return 0 }
        let metres = bucket.metres > 0 ? Double(bucket.metres)
                                       : Double(bucket.steps) * fallbackStride
        let stride = metres / Double(bucket.steps)
        // A whole slot averaging 130+ steps a minute, or strides over a metre,
        // is running. Shorter runs get diluted into a walking slot and are
        // undercounted — the bucket can't say more.
        let running = Double(bucket.steps) / 15 >= 130 || stride >= 1.0
        let oxygenPerMetre = running ? 0.2 : 0.1
        return oxygenPerMetre * metres * weightKg / 200
    }
}

enum ActivityScore {
    static let stepGoal = 8_000.0
    static let calorieGoal = 400.0

    static func compute(today: ActivityDay, history: [ActivityDay]) -> Score? {
        guard today.steps > 0 || today.activeCalories > 0 else { return nil }
        var parts: [(Contributor, Double)] = []

        parts.append((Contributor(name: "Daily steps",
                                  score: ramp(today.steps, floor: 1_000, target: stepGoal),
                                  detail: today.steps.formatted(.number.precision(.fractionLength(0)))),
                      0.40))

        if today.activeCalories > 0 {
            parts.append((Contributor(name: "Active calories",
                                      score: ramp(today.activeCalories, floor: 50, target: calorieGoal),
                                      detail: String(format: "%.0f kcal", today.activeCalories)), 0.30))
        }

        // A week of moving most days matters more than one big day.
        let week = history.filter { $0.dayKey < today.dayKey }.prefix(7)
        if week.count >= 3 {
            let activeDays = week.filter { $0.steps >= stepGoal * 0.75 }.count
            parts.append((Contributor(name: "Training frequency",
                                      score: ramp(Double(activeDays), floor: 0, target: 5),
                                      detail: "\(activeDays) of \(week.count) days"), 0.30))
        }

        return Score(weights: parts, isProvisional: week.count < 7)
    }
}

// MARK: - Cardiovascular index
//
// Oura derives cardiovascular age from arterial pulse wave velocity, which
// needs the raw PPG waveform — the R02 only exposes computed values, never the
// waveform. So this index is built from three markers the ring does provide,
// each with established links to cardiovascular fitness and mortality:
// resting heart rate, HRV, and overnight blood oxygen. It answers a similar
// question by a different route, and it is not a PWV measurement.

struct CardiovascularIndex {
    let score: Int                  // 0-100, higher is better
    let vo2max: Double?             // mL/kg/min, Uth estimate
    let ageDelta: Double?           // years younger (negative) or older (positive)
    let chronologicalAge: Int?
    let contributors: [Contributor]
    let isProvisional: Bool

    var cardiovascularAge: Double? {
        guard let chronologicalAge, let ageDelta else { return nil }
        return Double(chronologicalAge) + ageDelta
    }

    var band: ScoreBand { ScoreBand(score) }

    var headline: String {
        guard let delta = ageDelta else { return "Building estimate" }
        let years = abs(delta).rounded()
        if years < 1 { return "In line with your age" }
        return delta < 0 ? "\(Int(years)) years younger" : "\(Int(years)) years older"
    }

    /// Uth et al. (2004): VO2max ≈ 15.3 × (HRmax / HRrest).
    /// HRmax from Tanaka: 208 − 0.7 × age.
    static func vo2max(restingHR: Double, age: Int) -> Double {
        let hrMax = 208 - 0.7 * Double(age)
        return 15.3 * (hrMax / restingHR)
    }

    /// Rough population expectation for VO2max by age. Used only to turn a
    /// VO2max estimate into a "years younger/older" figure.
    static func expectedVO2max(age: Int) -> Double {
        max(20, 58 - 0.42 * Double(age))
    }

    /// Oura's Cardio Capacity levels, relative to your age group.
    enum CapacityLevel: String {
        case low  = "Low"
        case fair = "Fair"
        case high = "High"
        case peak = "Peak"
    }

    var capacityLevel: CapacityLevel? {
        guard let vo2max, let age = chronologicalAge else { return nil }
        switch vo2max / Self.expectedVO2max(age: age) {
        case 1.15...:   return .peak
        case 1.0..<1.15: return .high
        case 0.85..<1.0: return .fair
        default:         return .low
        }
    }

    static func compute(today: DailyMetrics,
                        history: [DailyMetrics],
                        age: Int?) -> CardiovascularIndex? {
        let past = Baseline.window(history, before: today.dayKey)
        var parts: [(Contributor, Double)] = []
        var provisional = false

        // Resting heart rate — the single strongest of the three.
        if let rhr = today.restingHR {
            let score: Int
            let detail = String(format: "%.0f bpm", rhr)
            if let baseline = Baseline(past.compactMap(\.restingHR)), baseline.isReliable {
                score = Int(max(0, min(100, 75 - baseline.z(rhr) * 15)).rounded())
            } else {
                provisional = true
                // Absolute scale until there's a personal baseline:
                // ~50 bpm excellent, ~75 bpm poor.
                score = ramp(rhr, floor: 80, target: 48)
            }
            parts.append((Contributor(name: "Resting heart rate", score: score, detail: detail), 0.40))
        }

        // HRV — autonomic balance.
        if let rmssd = today.rmssd {
            let score: Int
            if let baseline = Baseline(past.compactMap(\.rmssd)), baseline.isReliable {
                score = Int(max(0, min(100, 75 + baseline.z(rmssd) * 15)).rounded())
            } else {
                provisional = true
                score = ramp(rmssd, floor: 15, target: 70)
            }
            parts.append((Contributor(name: "HRV", score: score,
                                      detail: String(format: "%.0f ms", rmssd)), 0.35))
        }

        // Overnight oxygen saturation — low values suggest disordered breathing.
        if let spo2 = today.spo2Average {
            parts.append((Contributor(name: "Blood oxygen",
                                      score: ramp(spo2, floor: 92, target: 97),
                                      detail: String(format: "%.0f%%", spo2)), 0.25))
        }

        guard !parts.isEmpty else { return nil }

        let totalWeight = parts.reduce(0) { $0 + $1.1 }
        let score = Int((parts.reduce(0.0) { $0 + Double($1.0.score) * $1.1 } / totalWeight).rounded())

        var vo2: Double?
        var delta: Double?
        // Fitness doesn't change overnight, so VO₂max uses the median resting
        // heart rate of the last two weeks rather than last night alone — one
        // night's swing (or a stray daytime reading) moved it by 18 mL/kg/min.
        let recentRHR = dayKeys(endingOn: today.dayKey, count: 14).compactMap { key in
            history.first { $0.dayKey == key }?.restingHR
        }
        let fitnessRHR = recentRHR.count >= 3 ? HRV.median(recentRHR) : today.restingHR
        if let age, let rhr = fitnessRHR {
            let estimate = vo2max(restingHR: rhr, age: age)
            vo2 = estimate
            // Each 0.42 mL/kg/min of VO2max is worth roughly a year on the
            // population curve, so convert the gap into years and blend in the
            // index itself so HRV and SpO2 move the number too.
            let fitnessYears = (expectedVO2max(age: age) - estimate) / 0.42
            let indexYears = Double(75 - score) / 5.0
            delta = max(-15, min(15, fitnessYears * 0.7 + indexYears * 0.3))
        }

        return CardiovascularIndex(
            score: score, vo2max: vo2, ageDelta: delta, chronologicalAge: age,
            contributors: parts.map(\.0).sorted { $0.score < $1.score },
            isProvisional: provisional)
    }
}

// MARK: - Respiratory rate
//
// Breathing modulates heart rate (respiratory sinus arrhythmia): RR intervals
// shorten on the inhale and lengthen on the exhale, so the RR series
// oscillates at the breathing frequency. Resample the beats onto an even
// 4 Hz grid, estimate the spectrum with Welch's method, and take the peak in
// the high-frequency band, 0.15–0.4 Hz (9–24 breaths a minute). This is the
// same route Oura and Whoop take — nobody measures airflow.

enum RespiratoryRate {
    static let sampleRate = 4.0
    static let band = 0.15...0.40
    static let minimumSeconds = 60.0
    private static let segmentLength = 256          // 64 s at 4 Hz
    private static let frequencyStep = 0.005        // evaluated between bins
    /// Tuned on synthetic RR: ~0.3% false peaks on pure noise, and reliable
    /// at a ±20 ms breathing swing, the low end of resting RSA.
    private static let minimumConcentration = 0.45

    /// Breaths per minute from one capture, or nil without a clear peak.
    static func estimate(rr: [Int]) -> Double? {
        guard let run = longestRun(rr) else { return nil }
        let signal = resample(run)
        guard signal.count >= Int(minimumSeconds * sampleRate) else { return nil }
        return welchPeak(signal).map { $0 * 60 }
    }

    /// Beats as (time of beat, interval) for the longest stretch without an
    /// artifact. A missed or extra beat breaks the stretch rather than being
    /// interpolated over, since a bad interval would swamp the breathing signal.
    private static func longestRun(_ rr: [Int]) -> [(Double, Double)]? {
        let plausible = rr.filter { $0 > 300 && $0 < 2000 }
        guard plausible.count >= 30 else { return nil }
        let median = HRV.median(plausible.map(Double.init))

        var best: [(Double, Double)] = []
        var current: [(Double, Double)] = []
        var time = 0.0
        for interval in rr {
            time += Double(interval) / 1000
            let value = Double(interval)
            if value > 300, value < 2000, abs(value - median) / median <= 0.3 {
                current.append((time, value))
            } else {
                if current.count > best.count { best = current }
                current = []
            }
        }
        if current.count > best.count { best = current }
        guard let first = best.first, let last = best.last,
              last.0 - first.0 >= minimumSeconds else { return nil }
        return best
    }

    /// Linear interpolation onto an even grid.
    private static func resample(_ beats: [(Double, Double)]) -> [Double] {
        guard let start = beats.first?.0, let end = beats.last?.0 else { return [] }
        var out: [Double] = []
        var j = 0
        var t = start
        while t <= end {
            while j < beats.count - 2 && beats[j + 1].0 < t { j += 1 }
            let (t0, v0) = beats[j], (t1, v1) = beats[j + 1]
            let f = t1 > t0 ? (t - t0) / (t1 - t0) : 0
            out.append(v0 + (v1 - v0) * max(0, min(1, f)))
            t += 1 / sampleRate
        }
        return out
    }

    /// Averaged Hann-windowed periodograms over 50%-overlapping segments,
    /// evaluated only across the band. Returns the peak frequency in Hz.
    private static func welchPeak(_ signal: [Double]) -> Double? {
        let length = min(segmentLength, signal.count)
        let hop = length / 2
        let window = (0..<length).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(length - 1)) }
        let frequencies = Array(stride(from: band.lowerBound, through: band.upperBound, by: frequencyStep))
        let coefficients = frequencies.map { 2 * cos(2 * .pi * $0 / sampleRate) }
        var power = Array(repeating: 0.0, count: frequencies.count)
        var segments = 0

        var start = 0
        while start + length <= signal.count {
            let segment = detrend(Array(signal[start..<(start + length)]))
            let windowed = zip(segment, window).map { $0 * $1 }
            for (k, coefficient) in coefficients.enumerated() {
                power[k] += goertzel(windowed, coefficient: coefficient)
            }
            segments += 1
            start += hop
        }
        guard segments > 0, let peak = power.indices.max(by: { power[$0] < power[$1] }) else { return nil }

        // A peak on the band edge is usually low-frequency leakage. And unless
        // most of the band's power sits right around the peak, breathing isn't
        // what's showing in the heart rhythm — noise has peaks too.
        guard peak > 0, peak < power.count - 1 else { return nil }
        let total = power.reduce(0, +)
        let near = power.indices
            .filter { abs(frequencies[$0] - frequencies[peak]) <= 0.02 }
            .reduce(0.0) { $0 + power[$1] }
        guard total > 0, near / total >= minimumConcentration else { return nil }

        // Parabolic interpolation around the peak.
        let (a, b, c) = (power[peak - 1], power[peak], power[peak + 1])
        let denominator = a - 2 * b + c
        let shift = denominator != 0 ? 0.5 * (a - c) / denominator : 0
        return frequencies[peak] + max(-0.5, min(0.5, shift)) * frequencyStep
    }

    /// Power at one frequency without a full transform: a two-term
    /// recurrence per sample instead of a sine and cosine.
    private static func goertzel(_ x: [Double], coefficient: Double) -> Double {
        var s1 = 0.0, s2 = 0.0
        for value in x {
            let s0 = value + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        return s1 * s1 + s2 * s2 - coefficient * s1 * s2
    }

    /// Removes the mean and linear trend, so slow drift doesn't leak in.
    private static func detrend(_ x: [Double]) -> [Double] {
        let n = Double(x.count)
        let meanT = (n - 1) / 2
        let meanX = x.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (i, v) in x.enumerated() {
            num += (Double(i) - meanT) * (v - meanX)
            den += (Double(i) - meanT) * (Double(i) - meanT)
        }
        let slope = den > 0 ? num / den : 0
        return x.enumerated().map { $0.element - meanX - slope * (Double($0.offset) - meanT) }
    }
}

// MARK: - Sleep need and debt

struct SleepNeed {
    static let fallbackMinutes = 480.0

    let minutes: Double
    let isLearned: Bool

    /// Typical sleep on recent nights after which your body read as
    /// recovered — resting heart rate at or below your normal, HRV at or
    /// above it. Judged on physiology rather than readiness, because readiness
    /// now scores sleep against this need. Until there are five such nights
    /// in the last 30, 8 hours.
    static func estimate(history: [DailyMetrics], asOf dayKey: String) -> SleepNeed {
        let normal = Baseline.window(history, before: dayKey)
        let rhr = Baseline(normal.compactMap(\.restingHR))
        let hrv = Baseline(normal.compactMap(\.rmssd))
        let cutoff = DayKey.date(dayKey)
            .flatMap { Calendar.current.date(byAdding: .day, value: -30, to: $0) }
            .map(DayKey.of) ?? ""

        let recovered = history
            .filter { $0.dayKey <= dayKey && $0.dayKey > cutoff }
            .compactMap { m -> Int? in
                guard let asleep = m.asleepMinutes else { return nil }
                let checks = [m.restingHR.flatMap { v in rhr.map { v <= $0.mean } },
                              m.rmssd.flatMap { v in hrv.map { v >= $0.mean } }].compactMap { $0 }
                return !checks.isEmpty && checks.allSatisfy { $0 } ? asleep : nil
            }

        guard recovered.count >= 5 else {
            return SleepNeed(minutes: fallbackMinutes, isLearned: false)
        }
        let typical = HRV.median(recovered.map(Double.init))
        return SleepNeed(minutes: max(390, min(570, typical)), isLearned: true)
    }
}

struct SleepDebt {
    enum Level: String {
        case none     = "None"
        case low      = "Low"
        case moderate = "Moderate"
        case high     = "High"
    }

    let minutes: Double
    let need: SleepNeed
    let nights: Int

    var level: Level {
        switch minutes {
        case ..<15:  return .none
        case ..<120: return .low
        case ...300: return .moderate
        default:     return .high
        }
    }

    /// The last 14 days, oldest first. Each night adds its shortfall or pays
    /// back its surplus, and older debt fades so recent nights count most.
    /// Needs five nights in the window, like Oura's.
    static func compute(asleepByDay: [(String, Int?)], need: SleepNeed) -> SleepDebt? {
        let nights = asleepByDay.compactMap(\.1).count
        guard nights >= 5 else { return nil }
        var debt = 0.0
        for (_, asleep) in asleepByDay {
            debt *= 0.9
            if let asleep { debt = max(0, debt + need.minutes - Double(asleep)) }
        }
        return SleepDebt(minutes: debt, need: need, nights: nights)
    }
}

// MARK: - Daytime stress
//
// The ring logs stress on a 1–100 scale. Its bands map onto Oura's four
// zones: 1–29 restored, 30–59 relaxed, 60–79 engaged, 80+ stressed.

struct DaytimeStress {
    enum Zone: Int, CaseIterable {
        case restored, relaxed, engaged, stressed

        init(_ value: Double) {
            switch value {
            case ..<30: self = .restored
            case ..<60: self = .relaxed
            case ..<80: self = .engaged
            default:    self = .stressed
            }
        }

        var label: String {
            switch self {
            case .restored: return "Restored"
            case .relaxed:  return "Relaxed"
            case .engaged:  return "Engaged"
            case .stressed: return "Stressed"
            }
        }
    }

    enum Summary: String {
        case restored  = "Restored"
        case normal    = "Normal"
        case stressful = "Stressful"
    }

    let samples: [SeriesSample]
    let stressedMinutes: Double
    let restoredMinutes: Double

    var summary: Summary {
        if stressedMinutes >= 60 && stressedMinutes >= 2 * restoredMinutes { return .stressful }
        if restoredMinutes > stressedMinutes { return .restored }
        return .normal
    }

    /// Each sample stands for one logging interval, read from the gaps.
    static func compute(samples: [SeriesSample]) -> DaytimeStress? {
        guard !samples.isEmpty else { return nil }
        let gaps = zip(samples, samples.dropFirst()).map { $1.time.timeIntervalSince($0.time) / 60 }
        let interval = gaps.isEmpty ? 30 : max(5, min(60, HRV.median(gaps)))
        let zones = samples.map { Zone($0.value) }
        return DaytimeStress(
            samples: samples,
            stressedMinutes: Double(zones.filter { $0 == .stressed }.count) * interval,
            restoredMinutes: Double(zones.filter { $0 == .restored }.count) * interval)
    }
}

// MARK: - Resilience
//
// Oura balances daytime stress against daytime and nighttime recovery over
// 14 days. Same three contributors here, from what this ring logs.

struct Resilience {
    enum Level: String, CaseIterable {
        case limited     = "Limited"
        case adequate    = "Adequate"
        case solid       = "Solid"
        case strong      = "Strong"
        case exceptional = "Exceptional"

        init(_ score: Int) {
            switch score {
            case 85...:   self = .exceptional
            case 70..<85: self = .strong
            case 55..<70: self = .solid
            case 40..<55: self = .adequate
            default:      self = .limited
            }
        }
    }

    struct Day {
        let dayKey: String
        let stress: DaytimeStress
        let sessionMinutes: Double
        let nightRecovery: Int        // readiness, else sleep score
    }

    let score: Int
    let contributors: [Contributor]
    let days: [Day]

    var level: Level { Level(score) }

    /// Needs five complete days — daytime stress then a scored night.
    static func compute(days: [Day]) -> Resilience? {
        guard days.count >= 5 else { return nil }
        let stressed = HRV.mean(days.map(\.stress.stressedMinutes))
        let recovered = HRV.mean(days.map { $0.stress.restoredMinutes + $0.sessionMinutes })
        let night = HRV.mean(days.map { Double($0.nightRecovery) })

        let parts: [(Contributor, Double)] = [
            (Contributor(name: "Daytime stress load", score: ramp(stressed, floor: 240, target: 30),
                         detail: Format.duration(Int(stressed)) + " stressed / day"), 0.35),
            (Contributor(name: "Daytime recovery", score: ramp(recovered, floor: 0, target: 120),
                         detail: Format.duration(Int(recovered)) + " restored / day"), 0.25),
            (Contributor(name: "Nighttime recovery", score: Int(night.rounded()),
                         detail: String(format: "%.0f avg", night)), 0.40),
        ]
        let total = parts.reduce(0) { $0 + $1.1 }
        let score = Int((parts.reduce(0.0) { $0 + Double($1.0.score) * $1.1 } / total).rounded())
        return Resilience(score: score, contributors: parts.map(\.0), days: days)
    }
}

// MARK: - Body clock

enum Circadian {
    /// Hours past midnight, with evening times negative so a 23:30 bedtime and
    /// a 00:30 bedtime stay adjacent on the scale rather than 24 hours apart.
    static func hour(_ date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        var h = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
        if h > 12 { h -= 24 }
        return h
    }

    /// Midpoints of the 14 nights before a day, newest first. Shared by the
    /// sleep score's Timing and Body Clock so they never disagree.
    static func usualMidpoints(_ history: [DailyMetrics], before dayKey: String) -> [Double] {
        Array(history.filter { $0.dayKey < dayKey }
            .sorted { $0.dayKey > $1.dayKey }
            .compactMap { $0.sleepMidpoint.map(hour) }
            .prefix(14))
    }

    static func label(_ hour: Double) -> String {
        var h = hour
        if h < 0 { h += 24 }
        let hours = Int(h), minutes = Int((h - Double(hours)) * 60)
        let date = Calendar.current.date(bySettingHour: hours % 24, minute: minutes,
                                         second: 0, of: Date()) ?? Date()
        return Format.time(date)
    }
}

/// Where your sleep actually sits relative to your own established pattern.
/// Oura calls the equivalent Body Clock; the input here is the sleep midpoint,
/// which is the standard chronotype marker.
struct BodyClock {
    enum Alignment: String {
        case aligned      = "Aligned"
        case shiftedLate  = "Shifted later"
        case shiftedEarly = "Shifted earlier"
        case irregular    = "Irregular"
    }

    let alignment: Alignment
    let chronotypeHour: Double       // your usual midpoint
    let lastNightHour: Double        // last night's midpoint
    let shiftMinutes: Double         // signed, positive = later than usual
    let regularityMinutes: Double    // SD of midpoints — lower is steadier
    let sampleCount: Int

    var isProvisional: Bool { sampleCount < 7 }

    var detail: String {
        let minutes = Int(abs(shiftMinutes).rounded())
        switch alignment {
        case .aligned:
            return "Within \(minutes) min of your usual rhythm"
        case .shiftedLate:
            return "\(minutes) min later than usual"
        case .shiftedEarly:
            return "\(minutes) min earlier than usual"
        case .irregular:
            return "Bedtimes vary by about \(Int(regularityMinutes.rounded())) min"
        }
    }

    static func compute(history: [DailyMetrics]) -> BodyClock? {
        guard let lastNight = history.sorted(by: { $0.dayKey > $1.dayKey })
                .first(where: { $0.sleepMidpoint != nil }),
              let latest = lastNight.sleepMidpoint.map(Circadian.hour) else { return nil }

        let past = Circadian.usualMidpoints(history, before: lastNight.dayKey)
        guard !past.isEmpty else { return nil }

        let chronotype = HRV.mean(past)
        let regularity = HRV.standardDeviation(past) * 60
        let shift = (latest - chronotype) * 60

        let alignment: Alignment
        if regularity > 90 {
            alignment = .irregular
        } else if abs(shift) <= 30 {
            alignment = .aligned
        } else {
            alignment = shift > 0 ? .shiftedLate : .shiftedEarly
        }

        return BodyClock(alignment: alignment,
                         chronotypeHour: chronotype,
                         lastNightHour: latest,
                         shiftMinutes: shift,
                         regularityMinutes: regularity,
                         sampleCount: past.count)
    }
}

// MARK: - Symptom radar
//
// Built after Oura's Symptom Radar and the UCSF TemPredict work behind it.
// TemPredict scored each person against their own baseline (z-scores) and
// found the combination mattered: temperature added the most accuracy, HRV
// carried the most weight, and the model flagged COVID-19 an average of 2.75
// days before people sought testing. Oura watches skin temperature and its
// trend, respiratory rate, resting heart rate, HRV and inactive time, and looks
// for several shifting together — so it can flag strain while each number
// still sits inside its usual range. It needs seven nights in the past 14.
//
// Here: each signal becomes a z-score against your 28-day normal (the window
// Stanford's real-time CuSum used; TemPredict used 21), oriented so positive
// means strain. The strain score is their weighted average of the positive
// part; a level needs several signals moving at once, or one very large move.
// Two rules come from Stanford's NightSignal: resting heart rate 3 bpm over
// your median always counts, 4 bpm counts strongly; and the strongest level
// waits for a second night. Heads-up about your own trend — not a diagnosis.

struct SymptomRadar {
    enum Level: String, CaseIterable {
        case none  = "No signs"
        case minor = "Minor signs"
        case major = "Major signs"

        /// Oura's wording.
        var summary: String {
            switch self {
            case .none:  return "There are no obvious signs in your biometrics of something straining your body."
            case .minor: return "There are small signs in your biometrics of something straining your body."
            case .major: return "There are stronger signs in your biometrics of something straining your body."
            }
        }
    }

    struct Signal: Identifiable {
        enum Metric: String, CaseIterable {
            case temperature, temperatureTrend, restingHR, hrv, respiratoryRate, inactiveTime

            var name: String {
                switch self {
                case .temperature:      return "Body temperature"
                case .temperatureTrend: return "Temperature trend"
                case .restingHR:        return "Resting heart rate"
                case .hrv:              return "Heart rate variability"
                case .respiratoryRate:  return "Respiratory rate"
                case .inactiveTime:     return "Inactive time"
                }
            }

            /// Temperature and HRV carried the most weight in TemPredict.
            var weight: Double {
                switch self {
                case .temperature, .temperatureTrend, .hrv: return 1.0
                case .restingHR, .respiratoryRate:          return 0.8
                case .inactiveTime:                         return 0.5
                }
            }

            /// Which way is strain: up for most, down for HRV.
            var strainSign: Double { self == .hrv ? -1 : 1 }

            /// The smallest spread a baseline is allowed, so a young or very
            /// steady baseline can't turn a normal wobble into an alarm.
            func minimumSD(mean: Double) -> Double {
                switch self {
                case .temperature, .temperatureTrend: return 0.15
                case .restingHR:                      return 1.5
                case .hrv:                            return max(3, mean * 0.1)
                case .respiratoryRate:                return 0.5
                case .inactiveTime:                   return 30
                }
            }

            func format(_ value: Double) -> String {
                switch self {
                case .temperature, .temperatureTrend: return Format.temperature(value)
                case .restingHR:                      return String(format: "%.0f bpm", value)
                case .hrv:                            return String(format: "%.0f ms", value)
                case .respiratoryRate:                return String(format: "%.1f br/min", value)
                case .inactiveTime:                   return Format.duration(Int(value))
                }
            }
        }

        let metric: Metric
        let value: Double
        let normal: Double
        let z: Double                  // positive = toward strain

        var id: String { metric.rawValue }
        var isFlagged: Bool { z >= SymptomRadar.flagZ }
    }

    static let flagZ = 1.0
    static let requiredNights = 7
    static let baselineDays = 28

    var level: Level
    let strain: Double                 // weighted mean of positive z-scores
    let signals: [Signal]              // most strained first
    let nightsInWindow: Int
    /// Flagged signals, with temperature and its trend counted as one.
    let flaggedSystems: Set<String>
    /// Last night alone read major; it becomes major if the next night agrees.
    var awaitingConfirmation = false

    var flagged: [Signal] { signals.filter(\.isFlagged) }

    var detail: String {
        flagged.isEmpty ? "Your numbers look typical for you."
                        : flagged.map(\.metric.name).joined(separator: " · ")
    }

    var temperatureDelta: Double? {
        signals.first { $0.metric == .temperature }.map { $0.value - $0.normal }
    }

    /// Nil until there are seven nights in the past 14, or without last
    /// night's biometrics to judge.
    ///
    /// Major needs signs on two nights in a row. NightSignal alerts on
    /// deviations in successive nights and CuSum waits for 24 hours of
    /// elevation; one night alone stays at minor. As in NightSignal, the night
    /// before doesn't need an alert of its own — it confirms if the same
    /// signals were already off: at least two of tonight's flagged signals.
    static func compute(today: DailyMetrics, history: [DailyMetrics]) -> SymptomRadar? {
        guard var radar = evaluate(today: today, history: history) else { return nil }
        guard radar.level == .major else { return radar }

        let previousKey = DayKey.date(today.dayKey)
            .flatMap { Calendar.current.date(byAdding: .day, value: -1, to: $0) }
            .map(DayKey.of)
        let earlier = history.filter { $0.dayKey < today.dayKey }
        let confirmed = earlier.first { $0.dayKey == previousKey }
            .flatMap { evaluate(today: $0, history: earlier) }
            .map { $0.level != .none || $0.flaggedSystems.intersection(radar.flaggedSystems).count >= 2 }
            ?? false
        if !confirmed {
            radar.level = .minor
            radar.awaitingConfirmation = true
        }
        return radar
    }

    /// One night on its own, before the two-night check.
    private static func evaluate(today: DailyMetrics, history: [DailyMetrics]) -> SymptomRadar? {
        guard let date = DayKey.date(today.dayKey),
              let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -13, to: date) else { return nil }
        let from = DayKey.of(twoWeeksAgo)
        let recent = history.filter { $0.dayKey >= from && $0.dayKey <= today.dayKey }
        let nights = recent.filter { $0.asleepMinutes != nil }.count
        guard nights >= requiredNights,
              today.nightTemperature != nil || today.restingHR != nil || today.rmssd != nil
        else { return nil }

        let past = Baseline.window(history, before: today.dayKey, days: baselineDays)
        var signals: [Signal] = []

        func add(_ metric: Signal.Metric, _ value: Double?, _ keyPath: KeyPath<DailyMetrics, Double?>) {
            guard let value, let baseline = Baseline(past.compactMap { $0[keyPath: keyPath] }) else { return }
            let sd = max(baseline.sd, metric.minimumSD(mean: baseline.mean))
            signals.append(Signal(metric: metric, value: value, normal: baseline.mean,
                                  z: metric.strainSign * (value - baseline.mean) / sd))
        }

        add(.temperature, today.nightTemperature, \.nightTemperature)
        // The three-night average TemPredict used, so a slow rise registers.
        let lastThree = recent.sorted { $0.dayKey > $1.dayKey }.prefix(3).compactMap(\.nightTemperature)
        if lastThree.count >= 2 { add(.temperatureTrend, HRV.mean(lastThree), \.nightTemperature) }
        add(.restingHR, today.restingHR, \.restingHR)
        // NightSignal's fixed rule, measured from your median: +3 bpm is a
        // yellow and always flags, +4 is a red and counts as strongly as a
        // two-SD move — whatever your spread happens to be. Their reasoning:
        // overnight resting heart rate normally wanders about 3 bpm.
        let pastRHR = past.compactMap(\.restingHR)
        if let rhr = today.restingHR, pastRHR.count >= 3,
           let i = signals.firstIndex(where: { $0.metric == .restingHR }) {
            let above = rhr - HRV.median(pastRHR)
            let floor = above >= 4 ? 2.0 : (above >= 3 ? flagZ : -Double.infinity)
            if signals[i].z < floor {
                signals[i] = Signal(metric: .restingHR, value: rhr, normal: signals[i].normal, z: floor)
            }
        }
        add(.hrv, today.rmssd, \.rmssd)
        add(.respiratoryRate, today.respiratoryRate, \.respiratoryRate)
        // Inactivity is the day before: yesterday's sitting, last night's body.
        let yesterday = history.first { $0.dayKey < today.dayKey }
        add(.inactiveTime, yesterday?.inactiveMinutes, \.inactiveMinutes)

        guard !signals.isEmpty else { return nil }
        signals.sort { $0.z > $1.z }

        // Last night's temperature and the three-night trend share last
        // night, so they count once — whichever is further out — rather than
        // letting one warm night look like two signals agreeing.
        var systems: [(name: String, z: Double, weight: Double, infection: Bool)] = []
        let temperature = signals.filter { $0.metric == .temperature || $0.metric == .temperatureTrend }
        if let warmest = temperature.max(by: { $0.z < $1.z }) {
            systems.append(("temperature", warmest.z, 1.2, true))
        }
        for signal in signals where signal.metric != .temperature && signal.metric != .temperatureTrend {
            systems.append((signal.metric.rawValue, signal.z, signal.metric.weight,
                            signal.metric == .respiratoryRate))
        }

        let totalWeight = systems.reduce(0) { $0 + $1.weight }
        let strain = systems.reduce(0) { $0 + $1.weight * max(0, min(3, $1.z)) } / totalWeight
        let flaggedSystems = Set(systems.filter { $0.z >= flagZ }.map(\.name))
        let flags = flaggedSystems.count
        // Temperature and breathing are the infection-type signals. Heart rate,
        // HRV and inactivity also move after a late night, a drink or a hard
        // session, so without one of those clearly up it stays at minor.
        let infection = systems.contains { $0.infection && $0.z >= 1.5 }
        // A fever-sized jump is worth a heads-up on its own.
        let fever = signals.contains { $0.metric == .temperature && $0.z >= 3 }

        // Tuned by simulation against typical night-to-night spread: about 1 in
        // 60 ordinary nights reads minor and 1 in 1,000 major; a clear onset
        // (temperature +0.5 °C, resting HR +5, HRV −12 ms, breathing +1) is
        // flagged 99% of the time, ~90% as major.
        let level: Level
        if strain >= 1.5 && flags >= 3 && infection {
            level = .major
        } else if (strain >= 1.1 && flags >= 2) || fever {
            level = .minor
        } else {
            level = .none
        }
        return SymptomRadar(level: level, strain: strain, signals: signals, nightsInWindow: nights,
                            flaggedSystems: flaggedSystems)
    }
}

// MARK: - Formatting

/// Display unit for temperature. Data stays in °C; only what's shown changes.
enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius, fahrenheit

    var id: String { rawValue }

    /// The saved choice, or the locale's default until one is made.
    static var current: TemperatureUnit {
        if let raw = UserDefaults.standard.string(forKey: "temperatureUnit"),
           let unit = TemperatureUnit(rawValue: raw) { return unit }
        return Locale.current.measurementSystem == .us ? .fahrenheit : .celsius
    }

    var label: String { self == .celsius ? "Celsius (°C)" : "Fahrenheit (°F)" }
    var symbol: String { self == .celsius ? "°C" : "°F" }

    /// A difference of 1 °C is 1.8 °F; no offset.
    var deltaScale: Double { self == .celsius ? 1 : 1.8 }

    func absolute(_ celsius: Double) -> Double { self == .celsius ? celsius : celsius * 1.8 + 32 }
}

enum Format {
    static func temperature(_ celsius: Double) -> String {
        let unit = TemperatureUnit.current
        return String(format: "%.1f %@", unit.absolute(celsius), unit.symbol)
    }

    /// A change from your normal, signed: "+0.3 °C" or "+0.5 °F".
    static func temperatureDelta(_ celsius: Double, decimals: Int = 1, symbol: Bool = true) -> String {
        let unit = TemperatureUnit.current
        var value = celsius * unit.deltaScale
        if abs(value) < 0.5 * pow(10, -Double(decimals)) { value = 0 }
        return String(format: "%+.\(decimals)f", value) + (symbol ? " \(unit.symbol)" : "")
    }

    /// A spread: "±0.20 °C".
    static func temperatureSpread(_ celsius: Double) -> String {
        let unit = TemperatureUnit.current
        return String(format: "±%.2f %@", celsius * unit.deltaScale, unit.symbol)
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
