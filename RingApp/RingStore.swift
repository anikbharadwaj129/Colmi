import Foundation
import HealthKit
import SwiftUI
import Combine
// MARK: - Store

@MainActor
final class RingStore: ObservableObject {

    @Published private(set) var nights: [SleepNight] = []
    @Published private(set) var temperatures: [TemperatureReading] = []
    @Published private(set) var spo2: [SpO2Reading] = []
    @Published private(set) var sessions: [CaptureSession] = []
    @Published private(set) var samples: [SeriesSample] = []     // logged HRV + stress
    @Published private(set) var tags: [DayTag] = []
    @Published private(set) var daily: [DailyMetrics] = []
    @Published private(set) var steps: [StepBucket] = []
    @Published private(set) var heartRates: [HeartRateReading] = []   // the ring's 5-min log

    /// Body weight for calories. 0 = not set.
    @Published var weightKg: Double = UserDefaults.standard.double(forKey: "weightKg") {
        didSet { UserDefaults.standard.set(weightKg, forKey: "weightKg"); invalidateCaches() }
    }
    var weight: Double? { weightKg > 0 ? weightKg : nil }

    /// Display unit for temperature; stored data stays in °C.
    @Published var temperatureUnit: TemperatureUnit = .current {
        didSet {
            UserDefaults.standard.set(temperatureUnit.rawValue, forKey: "temperatureUnit")
            invalidateCaches()          // cached scores carry formatted details
        }
    }

    /// Rest Mode, as Oura offers alongside Symptom Radar: activity goals and
    /// the Activity score pause from the day it's turned on until it's off.
    @Published var restModeSince: Date? = {
        let t = UserDefaults.standard.double(forKey: "restModeSince")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }() {
        didSet {
            UserDefaults.standard.set(restModeSince?.timeIntervalSince1970 ?? 0, forKey: "restModeSince")
            invalidateCaches()
        }
    }

    func isRestMode(on dayKey: String) -> Bool {
        restModeSince.map { dayKey >= DayKey.of($0) } ?? false
    }

    @AppStorage("birthYear") var birthYear: Int = 0 {
        didSet { invalidateCaches() }
    }

    /// Spectral estimates are costly and a capture never changes, so each
    /// one's breathing rate is worked out once.
    private var breathingCache: [String: Double?] = [:]

    var age: Int? {
        guard birthYear > 1900 else { return nil }
        return Calendar.current.component(.year, from: Date()) - birthYear
    }

    private let dir = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() {
        nights       = read("nights") ?? []
        temperatures = read("temperature") ?? []
        spo2         = read("spo2") ?? []
        sessions     = read("sessions") ?? []
        samples      = read("samples") ?? []
        tags         = read("tags") ?? []
        steps        = read("steps") ?? []
        heartRates   = read("heartrate") ?? []
        migrate()
        migrateSleepDays()
        regroupSteps()
        regroupHeartRates()
        recomputeDaily()
    }

    /// One-time repairs for data saved by earlier parsers.
    private func migrate() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: "dataVersion") < 2 else { return }
        // Nights that began before midnight were filed with their onset a day
        // late; SpO₂ and temperature were split wrongly across days. The ring
        // still holds its last few days, so those two re-sync cleanly.
        nights = nights.map(\.repaired)
        spo2 = []
        temperatures = []
        write(nights, "nights"); write(spo2, "spo2"); write(temperatures, "temperature")
        defaults.set(2, forKey: "dataVersion")
    }

    /// Version 3: nights re-dated by Oura's 6 PM–6 PM sleep day.
    private func migrateSleepDays() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: "dataVersion") < 3 else { return }
        nights = SleepNight.bySleepDay(nights).sorted { $0.start > $1.start }
        write(nights, "nights")
        defaults.set(3, forKey: "dataVersion")
    }

    // MARK: File IO

    private func url(_ name: String) -> URL { dir.appendingPathComponent("\(name).json") }

    private func read<T: Decodable>(_ name: String) -> [T]? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([T].self, from: data)
    }

    private func write<T: Encodable>(_ values: [T], _ name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(values) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    private func upsert<T: Identifiable>(_ existing: [T], _ new: [T]) -> [T] where T.ID: Hashable {
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for item in new { byID[item.id] = item }
        return Array(byID.values)
    }

    // MARK: Merging

    func merge(nights new: [SleepNight]) {
        nights = SleepNight.bySleepDay(nights + new).sorted { $0.start > $1.start }
        write(nights, "nights"); recomputeDaily()
    }

    func merge(temperatures new: [TemperatureReading]) {
        temperatures = upsert(temperatures, new).sorted { $0.time > $1.time }
        write(temperatures, "temperature"); recomputeDaily()
    }

    func merge(spo2 new: [SpO2Reading]) {
        spo2 = upsert(spo2, new).sorted { $0.time > $1.time }
        write(spo2, "spo2"); recomputeDaily()
    }

    /// Timestamps on these are inferred from the series interval, not absolute,
    /// so re-syncing the same day overwrites rather than duplicates.
    func merge(samples new: [SeriesSample]) {
        samples = upsert(samples, new).sorted { $0.time > $1.time }
        write(samples, "samples"); recomputeDaily()
    }

    func merge(heartRates new: [HeartRateReading]) {
        heartRates = upsert(heartRates, new).sorted { $0.time < $1.time }
        write(heartRates, "heartrate"); regroupHeartRates(); recomputeDaily()
    }

    func merge(steps new: [StepBucket]) {
        steps = upsert(steps, new).sorted { $0.time < $1.time }
        write(steps, "steps"); regroupSteps(); recomputeDaily()
    }

    func add(session: CaptureSession) {
        sessions = upsert(sessions, [session]).sorted { $0.started > $1.started }
        write(sessions, "sessions"); recomputeDaily()
    }

    func remove(session: CaptureSession) {
        sessions.removeAll { $0.id == session.id }
        write(sessions, "sessions"); recomputeDaily()
    }

    func sessions(on dayKey: String, _ kinds: Set<CaptureSession.Kind>? = nil) -> [CaptureSession] {
        sessions.filter { $0.dayKey == dayKey && (kinds?.contains($0.resolvedKind) ?? true) }
    }

    func add(tag: DayTag) {
        tags = upsert(tags, [tag]).sorted { $0.time > $1.time }
        write(tags, "tags")
    }

    func remove(tag: DayTag) {
        tags.removeAll { $0.id == tag.id }
        write(tags, "tags")
    }

    func tags(on dayKey: String) -> [DayTag] {
        tags.filter { DayKey.of($0.time) == dayKey }
    }

    // MARK: Day access

    var availableDays: [String] {
        Set(daily.map(\.dayKey)).union(stepsByDay.keys).union(heartRatesByDay.keys)
            .union([DayKey.of(Date())]).sorted()
    }

    // MARK: Heart rate log

    private var heartRatesByDay: [String: [HeartRateReading]] = [:]

    private func regroupHeartRates() {
        heartRatesByDay = Dictionary(grouping: heartRates, by: \.dayKey)
    }

    /// The day's logged readings, oldest first.
    func heartRates(on dayKey: String) -> [HeartRateReading] { heartRatesByDay[dayKey] ?? [] }

    /// Readings between bedtime and waking, across midnight.
    func heartRates(during night: SleepNight) -> [HeartRateReading] {
        Set([DayKey.of(night.start), DayKey.of(night.end)]).sorted()
            .flatMap { heartRates(on: $0) }
            .filter { $0.time >= night.start && $0.time <= night.end }
    }

    /// The newest reading of the day, whether logged or measured on demand.
    func latestHeartRate(on dayKey: String) -> (time: Date, bpm: Int)? {
        let logged = heartRates(on: dayKey).last.map { (time: $0.time, bpm: $0.bpm) }
        let measured = sessions(on: dayKey).compactMap { s in s.settledHR.map { (time: s.ended, bpm: $0) } }
        return ([logged].compactMap { $0 } + measured).max { $0.time < $1.time }
    }

    func isAsleep(at time: Date) -> Bool {
        nights.contains { time >= $0.start && time <= $0.end }
    }

    // MARK: Activity

    private var stepsByDay: [String: [StepBucket]] = [:]

    /// Grouped by activity day, 4 AM to 4 AM.
    private func regroupSteps() {
        stepsByDay = Dictionary(grouping: steps, by: \.activityDayKey)
        invalidateCaches()
    }

    /// The activity day to show for a calendar day. Before 4 AM, today's
    /// activity day hasn't started — the one still running is yesterday's, as
    /// in Oura, where the small hours count toward the day before.
    func activityDayKey(showing dayKey: String) -> String {
        guard DayKey.isToday(dayKey), Calendar.current.component(.hour, from: Date()) < 4 else { return dayKey }
        return DayKey.activityDay(of: Date())
    }

    func stepBuckets(on dayKey: String) -> [StepBucket] { stepsByDay[dayKey] ?? [] }

    func activity(on dayKey: String) -> ActivityDay? {
        stepsByDay[dayKey].map { ActivityDay(dayKey: dayKey, buckets: $0, weightKg: weight) }
    }

    /// Days with steps, newest first.
    var activityDays: [ActivityDay] {
        if let cached = cache.activityDays { return cached }
        let days = stepsByDay.keys.sorted(by: >).compactMap(activity(on:))
        cache.activityDays = days
        return days
    }

    // MARK: Caches
    //
    // A day's scores don't change until the data behind them does, and My
    // Health's 90-day charts ask for hundreds of them at once. Any change to
    // the underlying data clears the lot.

    private struct ScoreCache {
        var readiness: [String: Score?] = [:]
        var sleep: [String: Score?] = [:]
        var cardiovascular: [String: CardiovascularIndex?] = [:]
        var activityDays: [ActivityDay]?
    }

    private var cache = ScoreCache()

    private func invalidateCaches() { cache = ScoreCache() }

    func activityScore(on dayKey: String) -> Score? {
        guard !isRestMode(on: dayKey), let today = activity(on: dayKey) else { return nil }
        return ActivityScore.compute(today: today,
                                     history: activityDays.filter { $0.dayKey <= dayKey })
    }

    func metrics(on dayKey: String) -> DailyMetrics? { daily.first { $0.dayKey == dayKey } }
    func night(on dayKey: String) -> SleepNight? { nights.first { $0.dayKey == dayKey } }

    /// History as of a day, so scrolling back shows what you'd have seen then.
    private func history(upTo dayKey: String) -> [DailyMetrics] {
        daily.filter { $0.dayKey <= dayKey }
    }

    func sleepScore(on dayKey: String) -> Score? {
        if let cached = cache.sleep[dayKey] { return cached }
        let score = night(on: dayKey).flatMap {
            SleepScore.compute(night: $0, history: history(upTo: dayKey))
        }
        cache.sleep[dayKey] = score
        return score
    }

    /// Readiness is built from the night, so a day has none until its sleep
    /// has synced. Without this, stress and HRV logged after midnight made a
    /// row for the new day and a score appeared from history alone.
    func readiness(on dayKey: String) -> Score? {
        if let cached = cache.readiness[dayKey] { return cached }
        let score = night(on: dayKey) == nil ? nil : metrics(on: dayKey).flatMap { today in
            ReadinessScore.compute(today: today,
                                   sleepNeed: sleepNeed(asOf: dayKey),
                                   history: history(upTo: dayKey),
                                   activity: activityDays.filter { $0.dayKey <= dayKey },
                                   restMode: isRestMode(on: dayKey))
        }
        cache.readiness[dayKey] = score
        return score
    }

    func cardiovascular(on dayKey: String) -> CardiovascularIndex? {
        let key = "\(dayKey)-\(age ?? 0)"
        if let cached = cache.cardiovascular[key] { return cached }
        let index = metrics(on: dayKey).flatMap {
            CardiovascularIndex.compute(today: $0, history: history(upTo: dayKey), age: age)
        }
        cache.cardiovascular[key] = index
        return index
    }

    // MARK: My Health

    func sleepScores(through dayKey: String, days: Int) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: dayKeys(endingOn: dayKey, count: days).compactMap { key in
            sleepScore(on: key).map { (key, $0.value) }
        })
    }

    /// Sleep Health: the median sleep score of the last 14 days.
    func sleepHealth(on dayKey: String) -> (typical: Int, rating: HealthRating)? {
        SleepHealth.typicalScore(sleepScores(through: dayKey, days: SleepHealth.windowDays), through: dayKey)
            .map { ($0, SleepHealth.rating($0)) }
    }

    /// The typical (14-day median) sleep score on each of the last `days` days.
    func typicalSleepScores(through dayKey: String, days: Int) -> [String: Int] {
        let scores = sleepScores(through: dayKey, days: days + SleepHealth.windowDays)
        return Dictionary(uniqueKeysWithValues: dayKeys(endingOn: dayKey, count: days).compactMap { key in
            SleepHealth.typicalScore(scores, through: key).map { (key, $0) }
        })
    }

    /// Updated weekly, as of the Monday on or before the day.
    func cumulativeStress(on dayKey: String) -> CumulativeStress? {
        CumulativeStress.compute(history: daily, activity: activityDays,
                                 asOf: HealthWeek.updateDay(for: dayKey))
    }

    /// Weekly, from the 30 nights before the Monday on or before the day.
    func cardiovascularAge(on dayKey: String) -> CardiovascularAgeReading? {
        guard let age else { return nil }
        let asOf = HealthWeek.updateDay(for: dayKey)
        let ages = Dictionary(uniqueKeysWithValues:
            dayKeys(endingOn: asOf, count: CardiovascularAgeReading.windowDays).compactMap { key in
                cardiovascular(on: key)?.cardiovascularAge.map { (key, $0) }
            })
        return CardiovascularAgeReading.weekly(daily: ages, chronologicalAge: age, asOf: asOf)
    }

    func chronotype(on dayKey: String) -> Chronotype? {
        Chronotype.compute(daily, through: dayKey)
    }

    func bodyClock(on dayKey: String) -> BodyClock? {
        BodyClock.compute(history: history(upTo: dayKey).sorted { $0.dayKey > $1.dayKey })
    }

    func symptomRadar(on dayKey: String) -> SymptomRadar? {
        guard let today = metrics(on: dayKey) else { return nil }
        return SymptomRadar.compute(today: today, history: history(upTo: dayKey))
    }

    func temperatures(on dayKey: String) -> [TemperatureReading] {
        temperatures.filter { DayKey.of($0.time) == dayKey }.sorted { $0.time < $1.time }
    }

    func spo2(on dayKey: String) -> [SpO2Reading] {
        spo2.filter { DayKey.of($0.time) == dayKey }.sorted { $0.time < $1.time }
    }

    func samples(kind: String, on dayKey: String) -> [SeriesSample] {
        samples.filter { $0.kind == kind && $0.dayKey == dayKey }.sorted { $0.time < $1.time }
    }

    func series(_ keyPath: KeyPath<DailyMetrics, Double?>, days: Int = 30) -> [(String, Double)] {
        daily.prefix(days).reversed().compactMap { m in
            m[keyPath: keyPath].map { (m.dayKey, $0) }
        }
    }

    /// Your normal for a metric: the 60 days before a day (today by default).
    func baseline(_ keyPath: KeyPath<DailyMetrics, Double?>,
                  before dayKey: String = DayKey.of(Date())) -> Baseline? {
        Baseline(Baseline.window(daily, before: dayKey).compactMap { $0[keyPath: keyPath] })
    }

    // MARK: Sleep need and debt

    func sleepNeed(asOf dayKey: String) -> SleepNeed {
        SleepNeed.estimate(history: history(upTo: dayKey), asOf: dayKey)
    }

    func sleepDebt(on dayKey: String) -> SleepDebt? {
        let window = days(endingOn: dayKey, count: 14).reversed().map {
            ($0, metrics(on: $0)?.asleepMinutes)
        }
        return SleepDebt.compute(asleepByDay: window, need: sleepNeed(asOf: dayKey))
    }

    // MARK: Stress

    /// Stress logged while awake.
    func daytimeStress(on dayKey: String) -> DaytimeStress? {
        DaytimeStress.compute(samples: samples(kind: "stress", on: dayKey).filter { sample in
            !nights.contains { sample.time >= $0.start && sample.time <= $0.end }
        })
    }

    /// Fourteen days of daytime stress, each followed by a scored night.
    func resilience(on dayKey: String) -> Resilience? {
        let days: [Resilience.Day] = days(endingOn: dayKey, count: 14).compactMap { key in
            guard let stress = daytimeStress(on: key),
                  let next = DayKey.date(key).flatMap({ Calendar.current.date(byAdding: .day, value: 1, to: $0) }),
                  let night = readiness(on: DayKey.of(next))?.value ?? sleepScore(on: DayKey.of(next))?.value
            else { return nil }
            let restorative = sessions(on: key, [.session]).reduce(0) { $0 + $1.duration } / 60
            return Resilience.Day(dayKey: key, stress: stress, sessionMinutes: restorative,
                                  nightRecovery: night)
        }
        return Resilience.compute(days: days)
    }

    /// Day keys counting back from a day, newest first.
    private func days(endingOn dayKey: String, count: Int) -> [String] {
        guard let date = DayKey.date(dayKey) else { return [] }
        return (0..<count).compactMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: date).map(DayKey.of)
        }
    }

    private func respiratoryRate(of session: CaptureSession) -> Double? {
        if let cached = breathingCache[session.id] { return cached }
        let value = RespiratoryRate.estimate(rr: session.rrIntervals)
        breathingCache[session.id] = value
        return value
    }

    // MARK: Derived

    private func recomputeDaily() {
        var byDay: [String: DailyMetrics] = [:]

        func metrics(for key: String) -> DailyMetrics {
            byDay[key] ?? DailyMetrics(dayKey: key)
        }

        // Logged HRV and stress first — these exist without any live capture.
        // Grouped once: filtering per sample made this quadratic in history.
        for (dayKey, group) in Dictionary(grouping: samples, by: \.dayKey) {
            var m = metrics(for: dayKey)
            let stress = group.filter { $0.kind == "stress" }.map(\.value)
            if !stress.isEmpty {
                m.stressAverage = HRV.mean(stress)
                m.stressPeak = stress.max()
            }
            byDay[dayKey] = m
        }

        for night in nights {
            var m = metrics(for: night.dayKey)
            m.asleepMinutes = night.asleepMinutes
            m.sleepEfficiency = night.efficiency
            m.deepMinutes = night.minutes(in: .deep)
            m.remMinutes = night.minutes(in: .rem)
            m.awakenings = night.segments.filter { $0.stage == .awake }.count
            m.sleepMidpoint = night.midpoint
            m.bedtime = night.start
            m.wakeTime = night.end

            let temps = temperatures
                .filter { $0.time >= night.start && $0.time <= night.end }.map(\.celsius)
            if !temps.isEmpty { m.nightTemperature = HRV.mean(temps) }

            let oxygen = spo2.filter { $0.time >= night.start && $0.time <= night.end }
            if !oxygen.isEmpty {
                m.spo2Average = HRV.mean(oxygen.map(\.average))
                m.spo2Low = Double(oxygen.map(\.low).min() ?? 0)
            }

            // Overnight HRV from the ring's own log, which needs no capture.
            let loggedHRV = samples.filter {
                $0.kind == "hrv" && $0.time >= night.start && $0.time <= night.end
            }.map(\.value)
            if !loggedHRV.isEmpty { m.rmssd = HRV.mean(loggedHRV) }

            // A capture session that covers the night is beat-to-beat data, so
            // it takes precedence over the ring's own averaged figure.
            let overnight = sessions.filter {
                $0.isResting && $0.started >= night.start && $0.ended <= night.end
            }
            if let measured = HRV.rmssd(overnight.flatMap(\.rrIntervals)) { m.rmssd = measured }
            if let lowest = overnight.compactMap(\.meanHR).min() { m.restingHR = lowest }

            // The ring's own log covers the whole night, so it wins over
            // captures for resting heart rate: the lowest 15-minute stretch,
            // so one low reading can't pass for the night.
            let sleeping = heartRates(during: night)
            if sleeping.count >= 3 {
                let stretches = (0...(sleeping.count - 3)).map { start in
                    (bpm: HRV.mean(sleeping[start..<(start + 3)].map { Double($0.bpm) }),
                     time: sleeping[start + 1].time)
                }
                if let lowest = stretches.min(by: { $0.bpm < $1.bpm }) {
                    m.restingHR = lowest.bpm
                    m.lowestHRTime = lowest.time
                }
            }

            // Nightly breathing rate, the median across the night's captures.
            let breathing = overnight.compactMap(respiratoryRate(of:))
            if !breathing.isEmpty { m.respiratoryRate = HRV.median(breathing) }

            byDay[night.dayKey] = m
        }

        // Resting heart rate and HRV come from the night only, as Oura's do.
        // A daytime capture used to stand in on days without a synced night,
        // which let a Debug-tab stream at 78 bpm become "resting" heart rate.

        // Inactive time while awake: 15-minute slots with the ring on (a heart
        // rate reading in the slot) and under 25 steps. Wear comes from the
        // heart rate log because a slot with no steps can't otherwise be told
        // apart from the ring sitting on a nightstand.
        for (dayKey, readings) in heartRatesByDay {
            guard let midnight = DayKey.date(dayKey) else { continue }
            let next = Calendar.current.date(byAdding: .day, value: 1, to: midnight).map(DayKey.of) ?? ""
            let wake = nights.first { $0.dayKey == dayKey }?.end ?? midnight.addingTimeInterval(7 * 3600)
            let sleep = nights.first { $0.dayKey == next }?.start ?? midnight.addingTimeInterval(22 * 3600)
            let slot = { (t: Date) in Int(t.timeIntervalSince(midnight) / 900) }
            let worn = Set(readings.filter { $0.time >= wake && $0.time < sleep }.map { slot($0.time) })
            guard worn.count >= 8 else { continue }
            var stepsBySlot: [Int: Int] = [:]
            for bucket in stepBuckets(on: dayKey) { stepsBySlot[slot(bucket.time), default: 0] += bucket.steps }
            var m = metrics(for: dayKey)
            m.inactiveMinutes = Double(worn.filter { (stepsBySlot[$0] ?? 0) < 25 }.count * 15)
            byDay[dayKey] = m
        }

        // Without overnight captures, an unguided session still gives a
        // resting breathing rate for its day.
        let still = Dictionary(grouping: sessions.filter { $0.resolvedKind == .session }, by: \.dayKey)
        for (dayKey, group) in still where byDay[dayKey]?.respiratoryRate == nil {
            let rates = group.compactMap(respiratoryRate(of:))
            guard !rates.isEmpty else { continue }
            var m = metrics(for: dayKey)
            m.respiratoryRate = HRV.median(rates)
            byDay[dayKey] = m
        }

        daily = byDay.values.sorted { $0.dayKey > $1.dayKey }
        invalidateCaches()
    }
}

// MARK: - Tags

struct DayTag: Codable, Identifiable, Hashable {
    let id: String
    let time: Date
    let label: String
    let symbol: String

    init(label: String, symbol: String, time: Date = Date()) {
        self.id = UUID().uuidString
        self.time = time
        self.label = label
        self.symbol = symbol
    }

    static let presets: [(String, String)] = [
        ("Caffeine", "cup.and.saucer.fill"),
        ("Alcohol", "wineglass.fill"),
        ("Late meal", "fork.knife"),
        ("Workout", "figure.run"),
        ("Stressful day", "bolt.heart.fill"),
        ("Travel", "airplane"),
        ("Feeling unwell", "thermometer.medium"),
        ("Nap", "powersleep"),
    ]
}

// MARK: - HealthKit

@MainActor
final class HealthService: ObservableObject {

    @Published private(set) var isAuthorized = false
    @Published private(set) var lastError: String?
    private let store = HKHealthStore()

    private var readTypes: Set<HKObjectType> {
        Set([HKObjectType.quantityType(forIdentifier: .bodyMass)].compactMap { $0 })
    }

    private var shareTypes: Set<HKSampleType> {
        var types = Set<HKSampleType>()
        for id: HKCategoryTypeIdentifier in [.sleepAnalysis, .mindfulSession] {
            if let t = HKObjectType.categoryType(forIdentifier: id) { types.insert(t) }
        }
        for id: HKQuantityTypeIdentifier in [.bodyTemperature, .oxygenSaturation, .heartRate,
                                             .heartRateVariabilitySDNN, .restingHeartRate] {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        return types
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            lastError = "HealthKit not available"; return
        }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            isAuthorized = true; lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Body mass

    /// Most recent weight in Health, in kg — used once to prefill Settings.
    func latestBodyMass() async -> Double? {
        guard isAuthorized, let type = HKObjectType.quantityType(forIdentifier: .bodyMass) else { return nil }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1)
        let latest = try? await descriptor.result(for: store).first
        return latest?.quantity.doubleValue(for: .gramUnit(with: .kilo))
    }

    func save(night: SleepNight) async {
        guard isAuthorized,
              let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        await save(night.segments.map { segment in
            let value: HKCategoryValueSleepAnalysis = {
                switch segment.stage {
                case .light: return .asleepCore
                case .deep:  return .asleepDeep
                case .rem:   return .asleepREM
                case .awake: return .awake
                }
            }()
            return HKCategorySample(type: type, value: value.rawValue,
                                    start: segment.start, end: segment.end)
        })
    }

    func save(temperatures: [TemperatureReading]) async {
        guard isAuthorized,
              let type = HKObjectType.quantityType(forIdentifier: .bodyTemperature) else { return }
        await save(temperatures.map {
            HKQuantitySample(type: type,
                             quantity: HKQuantity(unit: .degreeCelsius(), doubleValue: $0.celsius),
                             start: $0.time, end: $0.time)
        })
    }

    func save(spo2: [SpO2Reading]) async {
        guard isAuthorized,
              let type = HKObjectType.quantityType(forIdentifier: .oxygenSaturation) else { return }
        await save(spo2.map {
            HKQuantitySample(type: type,
                             quantity: HKQuantity(unit: .percent(), doubleValue: $0.average / 100),
                             start: $0.time, end: $0.time)
        })
    }

    func save(session: CaptureSession) async {
        guard isAuthorized else { return }
        var out: [HKSample] = []
        if session.resolvedKind == .session,
           let type = HKObjectType.categoryType(forIdentifier: .mindfulSession) {
            out.append(HKCategorySample(type: type, value: HKCategoryValue.notApplicable.rawValue,
                                        start: session.started, end: session.ended))
        }
        if session.isResting, let sdnn = session.sdnn,
           let type = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
            out.append(HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: sdnn),
                start: session.started, end: session.ended))
        }
        if let hr = session.meanHR,
           let type = HKObjectType.quantityType(forIdentifier: .heartRate) {
            out.append(HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: hr),
                start: session.started, end: session.ended))
        }
        await save(out)
    }

    private func save(_ samples: [HKSample]) async {
        guard !samples.isEmpty else { return }
        do { try await store.save(samples) }
        catch { lastError = error.localizedDescription }
    }
}

// MARK: - Sync

@MainActor
final class RingSync: ObservableObject {

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date? = {
        let t = UserDefaults.standard.double(forKey: "lastSync")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }() {
        didSet { UserDefaults.standard.set(lastSync?.timeIntervalSince1970 ?? 0, forKey: "lastSync") }
    }

    func isStale(maxAge: TimeInterval) -> Bool {
        guard let lastSync else { return true }
        return Date().timeIntervalSince(lastSync) > maxAge
    }

    private var historyArrived = false
    @Published private(set) var status = "Not synced yet"

    private let ring: RingConnection
    private let store: RingStore
    private let health: HealthService
    private var emptyDays = Set<Int>()
    private var noStepsDay = false
    private var heartRateDay: Bool?            // true = got a day, false = none

    init(ring: RingConnection, store: RingStore, health: HealthService) {
        self.ring = ring; self.store = store; self.health = health
        ring.onBigDataMessage = { [weak self] type, payload in
            self?.handle(type: type, payload: payload)
        }
        ring.onHistory = { [weak self] series in
            self?.handle(series: series)
        }
        ring.onSteps = { [weak self] reply in
            self?.handle(steps: reply)
        }
        ring.onHeartRateLog = { [weak self] reply in
            self?.handle(heartRateLog: reply)
        }
    }

    /// Pulls everything the ring logged on its own: sleep, temperature, SpO₂,
    /// then heart rate, HRV, stress and steps for the last week. No live
    /// capture involved.
    func syncAll(backfillDays: Int = 7) async {
        guard ring.isConnected, !isSyncing else {
            if !ring.isConnected { status = "Ring not connected" }
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        status = "Syncing…"
        ring.syncTime()

        // Wait for each big-data reply to finish rather than a fixed 2.5 s:
        // temperature arrives as one message per day, and the next request
        // used to cut it off mid-reply.
        for type in BigDataType.allCases {
            ring.requestBigData(type)
            let started = Date()
            while !Task.isCancelled && ring.isConnected && Date().timeIntervalSince(started) < 8 {
                try? await Task.sleep(for: .milliseconds(200))
                let quiet = Date().timeIntervalSince(ring.lastBigDataActivity) > 1.2
                if ring.bigDataTypesReceived.contains(type.rawValue) && quiet { break }
            }
        }

        status = "Fetching HRV and stress…"
        emptyDays.removeAll()
        for offset in 0..<max(1, min(7, backfillDays)) {
            for request in [ring.requestHRVHistory, ring.requestStressHistory] {
                historyArrived = false
                request(offset)
                let started = Date()
                while !historyArrived && !Task.isCancelled && Date().timeIntervalSince(started) < 4 {
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            // An all-zero reply means that day has no data; older days won't either.
            if emptyDays.contains(offset) { break }
        }

        status = "Fetching heart rate…"
        for offset in 0..<max(1, min(7, backfillDays)) {
            heartRateDay = nil
            ring.requestHeartRateLog(daysAgo: offset)
            // Up to 12 s: a full day is ~24 packets, and cutting the wait
            // short truncates the day rather than failing.
            let deadline = Date().addingTimeInterval(12)
            while heartRateDay == nil && Date() < deadline && ring.isConnected {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if heartRateDay != true { break }      // no data, or no reply
        }

        status = "Fetching steps…"
        for offset in 0..<max(1, min(7, backfillDays)) {
            noStepsDay = false
            ring.requestSteps(dayOffset: offset)
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            ring.finishSteps()
            if noStepsDay { break }
        }

        ring.requestBattery()
        lastSync = Date()
        status = "Updated " + Format.time(Date())
    }

    /// Just today's steps — quick enough to run every few minutes for
    /// inactivity alerts without a full sync.
    func syncTodaySteps() async {
        guard ring.isConnected, !isSyncing else { return }
        ring.requestSteps(dayOffset: 0)
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        ring.finishSteps()
    }

    private func handle(heartRateLog reply: HeartRateLogReply) {
        switch reply {
        case .noData:
            heartRateDay = false
        case .readings(let readings):
            store.merge(heartRates: readings)
            heartRateDay = true
        }
    }

    private func handle(steps reply: StepsReply) {
        switch reply {
        case .noData:          noStepsDay = true
        case .rows(let rows):  store.merge(steps: rows)
        }
    }

    private func handle(series: HistorySeries) {
        historyArrived = true
        guard !series.isEmpty else {
            emptyDays.insert(series.dayOffset)
            return
        }
        let kind = series.command == UARTCommand.hrvHistory.rawValue ? "hrv" : "stress"
        let samples = series.timestamps().map {
            SeriesSample(kind: kind, time: $0.0, value: Double($0.1))
        }
        store.merge(samples: samples)
    }

    private func handle(type: UInt8, payload: [UInt8]) {
        guard payload.count > 1 else {
            if payload.first == BigDataStatus.unsupported.rawValue {
                status = "Ring rejected 0x\(String(type, radix: 16))"
            }
            return
        }
        switch BigDataType(rawValue: type) {
        case .sleep:
            let nights = SleepNight.parse(payload)
            store.merge(nights: nights)
            Task { for night in nights { await health.save(night: night) } }
        case .temperature:
            let readings = TemperatureParser.parse(payload)
            store.merge(temperatures: readings)
            Task { await health.save(temperatures: readings) }
        case .spo2:
            let readings = SpO2Parser.parse(payload)
            store.merge(spo2: readings)
            Task { await health.save(spo2: readings) }
        case .none:
            break
        }
    }
}
