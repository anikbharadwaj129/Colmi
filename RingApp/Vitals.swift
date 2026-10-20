import SwiftUI
import Charts

// MARK: - Sections
//
// Laid out like Oura's Vitals: cards grouped by health area, a day strip you
// can swipe or open as a calendar, and a pencil to reorder the groups.
// Metabolic and women's health are left out — no data source for them yet.

enum VitalsSection: String, CaseIterable, Identifiable {
    case readiness, sleep, activity, stress, heart, core

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readiness: return "Readiness"
        case .sleep:     return "Sleep"
        case .activity:  return "Activity"
        case .stress:    return "Stress"
        case .heart:     return "Heart health"
        case .core:      return "Core metrics"
        }
    }

    var symbol: String {
        switch self {
        case .readiness: return Section2.readiness.symbol
        case .sleep:     return Section2.sleep.symbol
        case .activity:  return Section2.activity.symbol
        case .stress:    return Section2.stress.symbol
        case .heart:     return Section2.heart.symbol
        case .core:      return "waveform.path.ecg"
        }
    }

    static func encode(_ sections: [VitalsSection]) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }

    /// Stored order first; anything missing (say, a section added later) after.
    static func decode(_ raw: String) -> [VitalsSection] {
        var seen = Set<VitalsSection>()
        let stored = raw.split(separator: ",")
            .compactMap { VitalsSection(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
        return stored + allCases.filter { !seen.contains($0) }
    }
}

enum CoreMetric: String, CaseIterable, Identifiable {
    case restingHR, hrv, temperature, respiratoryRate, bloodOxygen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restingHR:       return "Resting heart rate"
        case .hrv:             return "Heart rate variability"
        case .temperature:     return "Body temperature"
        case .respiratoryRate: return "Respiratory rate"
        case .bloodOxygen:     return "Blood oxygen"
        }
    }

    /// Fits a half-width card.
    var shortTitle: String { self == .hrv ? "HRV" : title }

    var unit: String {
        switch self {
        case .restingHR:       return "bpm"
        case .hrv:             return "ms"
        case .temperature:     return TemperatureUnit.current.symbol
        case .respiratoryRate: return "br/min"
        case .bloodOxygen:     return "%"
        }
    }

    var keyPath: KeyPath<DailyMetrics, Double?> {
        switch self {
        case .restingHR:       return \.restingHR
        case .hrv:             return \.rmssd
        case .temperature:     return \.nightTemperature
        case .respiratoryRate: return \.respiratoryRate
        case .bloodOxygen:     return \.spo2Average
        }
    }

    var accent: Color {
        switch self {
        case .restingHR, .hrv: return Section2.heart.accent
        case .temperature:     return Section2.stress.accent
        case .respiratoryRate: return Section2.bodyClock.accent
        case .bloodOxygen:     return Section2.readiness.accent
        }
    }

    /// Which way is the good way, if there is one.
    var higherIsBetter: Bool? {
        switch self {
        case .restingHR: return false
        case .hrv:       return true
        default:         return nil
        }
    }

    /// Temperature reads as a deviation from your own baseline, like Oura's.
    var isDeviation: Bool { self == .temperature }

    /// Stored values are °C; charts scale temperature into the chosen unit.
    var displayScale: Double { self == .temperature ? TemperatureUnit.current.deltaScale : 1 }

    func format(_ value: Double) -> String {
        switch self {
        case .temperature:     return Format.temperatureDelta(value, symbol: false)
        case .respiratoryRate: return String(format: "%.1f", value)
        default:               return String(format: "%.0f", value)
        }
    }

    var about: String {
        switch self {
        case .restingHR:
            return "Your lowest heart rate overnight — the lowest 15-minute stretch of the ring's 5-minute log. Lower usually means better recovery."
        case .hrv:
            return "RMSSD from the ring's overnight HRV log, or beat-to-beat data when a capture covered the night. Higher is generally better — compare it with your own normal, not anyone else's."
        case .temperature:
            return "How far last night's skin temperature sat from your long-term average. Small swings are normal; a sustained rise can mean your body is fighting something."
        case .respiratoryRate:
            return "Breaths per minute, estimated from how your heart rhythm speeds up on each inhale and slows on each exhale. Needs beat-to-beat data: turn on Overnight capture in Settings, or take an unguided session."
        case .bloodOxygen:
            return "Average overnight SpO₂. Most people sit between 95 and 100%."
        }
    }
}

// MARK: - Colors

extension DaytimeStress.Zone {
    var color: Color {
        switch self {
        case .restored: return Palette.optimal
        case .relaxed:  return Palette.good
        case .engaged:  return Palette.fair
        case .stressed: return Palette.low
        }
    }
}

extension DaytimeStress.Summary {
    var color: Color {
        switch self {
        case .restored:  return Palette.optimal
        case .normal:    return Palette.good
        case .stressful: return Palette.low
        }
    }
}

extension Resilience.Level {
    var color: Color {
        switch self {
        case .limited:     return Palette.low
        case .adequate:    return Palette.fair
        case .solid:       return Palette.good
        case .strong, .exceptional: return Palette.optimal
        }
    }
}

extension SleepDebt.Level {
    var color: Color {
        switch self {
        case .none:     return Palette.optimal
        case .low:      return Palette.good
        case .moderate: return Palette.fair
        case .high:     return Palette.low
        }
    }
}

extension SymptomRadar.Level {
    var color: Color {
        switch self {
        case .none:  return Palette.good
        case .minor: return Palette.fair
        case .major: return Palette.low
        }
    }
}

// MARK: - Vitals tab

struct VitalsTab: View {
    @EnvironmentObject private var store: RingStore
    @Binding var day: String

    @AppStorage("vitalsOrder") private var orderRaw = VitalsSection.encode(VitalsSection.allCases)
    @State private var editing = false
    @State private var showCalendar = false

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var days: [String] { store.availableDays }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    ForEach(VitalsSection.decode(orderRaw)) { section in
                        VStack(alignment: .leading, spacing: 14) {
                            Label(section.title, systemImage: section.symbol)
                                .font(.system(size: 22, weight: .regular))
                                .labelStyle(SectionLabelStyle())
                            LazyVGrid(columns: columns, spacing: 10) { cards(section) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .simultaneousGesture(swipe)
            .safeAreaInset(edge: .top, spacing: 0) {
                VitalsDateStrip(selection: $day, days: days) { showCalendar = true }
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Vitals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = true } label: { Image(systemName: "pencil") }
                        .accessibilityLabel("Reorder sections")
                }
            }
            .sheet(isPresented: $editing) {
                VitalsEditor(order: Binding(
                    get: { VitalsSection.decode(orderRaw) },
                    set: { orderRaw = VitalsSection.encode($0) }))
            }
            .sheet(isPresented: $showCalendar) {
                VitalsCalendar(selection: $day, firstDay: days.first)
            }
            .buttonStyle(.plain)
        }
    }

    /// Swipe the page sideways to move a day, as in Oura.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30).onEnded { value in
            let dx = value.translation.width
            guard abs(dx) > 70, abs(dx) > abs(value.translation.height) * 1.5,
                  let index = days.firstIndex(of: day) else { return }
            let target = dx > 0 ? index - 1 : index + 1
            guard days.indices.contains(target) else { return }
            withAnimation(.snappy) { day = days[target] }
        }
    }

    @ViewBuilder
    private func cards(_ section: VitalsSection) -> some View {
        switch section {
        case .readiness: readinessCards
        case .sleep:     sleepCards
        case .activity:  activityCards
        case .stress:    stressCards
        case .heart:     heartCards
        case .core:
            ForEach(CoreMetric.allCases) { metric in
                NavigationLink { CoreMetricDetail(metric: metric, day: $day) } label: {
                    CoreMetricTile(metric: metric, day: day)
                }
            }
        }
    }

    // Readiness

    @ViewBuilder
    private var readinessCards: some View {
        let readiness = store.readiness(on: day)
        NavigationLink { ReadinessDetail(day: $day) } label: {
            VitalTile(title: "Readiness Score", reading: .score(readiness))
        }
        let radar = store.symptomRadar(on: day)
        NavigationLink { SymptomRadarDetail(day: $day) } label: {
            VitalTile(title: "Symptom Radar",
                      reading: VitalReading(headline: radar?.level.rawValue, isWord: true)) {
                EmptyView()
            } backdrop: {
                RadarSphere(color: radar?.level.color ?? .white.opacity(0.3))
            }
        }
    }

    // Sleep

    @ViewBuilder
    private var sleepCards: some View {
        NavigationLink { SleepDetail(day: $day) } label: {
            VitalTile(title: "Sleep Score", reading: .score(store.sleepScore(on: day)))
        }
        let clock = store.bodyClock(on: day)
        NavigationLink { SleepDetail(day: $day) } label: {
            VitalTile(title: "Body Clock",
                      reading: VitalReading(headline: clock?.alignment.rawValue, isWord: true)) {
                if let clock { BodyClockArcs(clock: clock) }
            }
        }
        let debt = store.sleepDebt(on: day)
        NavigationLink { SleepDebtDetail(day: $day) } label: {
            VitalTile(title: "Sleep Debt",
                      reading: VitalReading(status: debt?.level.rawValue,
                                            statusColor: debt?.level.color ?? .secondary,
                                            headline: debt.map { Format.duration(Int($0.minutes.rounded())) },
                                            caption: debt == nil ? "Needs 5 nights in 2 weeks" : nil))
        }
        let metrics = store.metrics(on: day)
        NavigationLink { SleepDetail(day: $day) } label: {
            VitalTile(title: "Total Sleep",
                      reading: VitalReading(headline: metrics?.asleepMinutes.map(Format.duration),
                                            caption: metrics?.sleepEfficiency
                                                .map { "Efficiency \(Int($0 * 100))%" }))
        }
    }

    // Activity

    @ViewBuilder
    private var activityCards: some View {
        // Before 4 AM today, the activity day still running is yesterday's.
        let activityDay = store.activityDayKey(showing: day)
        let activity = store.activity(on: activityDay)
        NavigationLink { ActivityDetail(day: $day) } label: {
            VitalTile(title: "Activity Score",
                      reading: store.isRestMode(on: day)
                        ? VitalReading(status: "Rest Mode", statusColor: Section2.stress.accent,
                                       headline: "Paused", isWord: true)
                        : .score(store.activityScore(on: activityDay)))
        }
        NavigationLink { ActivityDetail(day: $day) } label: {
            VitalTile(title: "Steps",
                      reading: VitalReading(headline: activity.map { $0.steps.formatted(.number.precision(.fractionLength(0))) },
                                            caption: "Goal \(Int(ActivityScore.stepGoal).formatted())")) {
                ProgressBar(fraction: (activity?.steps ?? 0) / ActivityScore.stepGoal,
                            color: Section2.activity.accent)
            }
        }
        NavigationLink { ActivityDetail(day: $day) } label: {
            VitalTile(title: "Active Calories",
                      reading: VitalReading(headline: activity.flatMap { $0.activeCalories > 0
                                                ? String(format: "%.0f", $0.activeCalories) : nil },
                                            unit: "kcal",
                                            caption: store.weight == nil ? "Add weight in Settings"
                                                : "Goal \(Int(ActivityScore.calorieGoal))")) {
                ProgressBar(fraction: (activity?.activeCalories ?? 0) / ActivityScore.calorieGoal,
                            color: Section2.activity.accent)
            }
        }
        let workouts = store.sessions(on: day, [.workout])
        NavigationLink { ActivityDetail(day: $day) } label: {
            VitalTile(title: "Workouts",
                      reading: VitalReading(
                        headline: workouts.isEmpty ? nil
                            : Format.duration(Int((workouts.reduce(0) { $0 + $1.duration } / 60).rounded())),
                        caption: workouts.isEmpty ? "Record one from Today's +"
                            : "\(workouts.count) recorded"))
        }
    }

    // Stress

    @ViewBuilder
    private var stressCards: some View {
        let stress = store.daytimeStress(on: day)
        NavigationLink { StressDetail(day: $day) } label: {
            VitalTile(title: "Daytime Stress",
                      reading: VitalReading(headline: stress?.summary.rawValue, isWord: true,
                                            caption: stress.map {
                                                "\(Format.duration(Int($0.stressedMinutes))) stressed · \(Format.duration(Int($0.restoredMinutes))) restored"
                                            })) {
                if let stress { StressBars(samples: stress.samples) }
            }
        }
        let resilience = store.resilience(on: day)
        NavigationLink { ResilienceDetail(day: $day) } label: {
            VitalTile(title: "Resilience",
                      reading: VitalReading(headline: resilience?.level.rawValue, isWord: true,
                                            caption: resilience == nil ? "Needs 5 full days" : nil)) {
                if let resilience { ResilienceMeter(level: resilience.level) }
            }
        }
    }

    // Heart health

    @ViewBuilder
    private var heartCards: some View {
        let cv = store.cardiovascular(on: day)
        // Oura's weekly figure from 30 nights, not one night's index — a
        // single night swung it from 13 to 39.
        let cva = store.cardiovascularAge(on: day)
        NavigationLink { HeartHealthHub(day: $day) } label: {
            VitalTile(title: "Cardiovascular Age",
                      reading: VitalReading(status: cva.map { "\($0.range.rawValue) · \(Int(abs($0.delta).rounded())) yrs \($0.delta < 0 ? "younger" : "older")" },
                                            statusColor: cva?.rating.color ?? .secondary,
                                            headline: cva.map { String(format: "%.0f", $0.age) },
                                            unit: "yrs",
                                            caption: store.age == nil ? "Add birth year in Settings"
                                                : (cva == nil ? "Needs 14 nights in 30" : "Updated weekly")))
        }
        NavigationLink { HeartDetail(day: $day) } label: {
            VitalTile(title: "Cardio Capacity",
                      reading: VitalReading(status: cv?.capacityLevel?.rawValue,
                                            statusColor: Section2.heart.accent,
                                            headline: cv?.vo2max.map { String(format: "%.1f", $0) },
                                            caption: cv?.vo2max == nil ? nil : "VO₂max, mL/kg/min"))
        }
        let latest = store.latestHeartRate(on: day)
        let logged = store.heartRates(on: day)
        NavigationLink { HeartDetail(day: $day) } label: {
            VitalTile(title: "Heart Rate",
                      reading: VitalReading(headline: latest.map { String($0.bpm) }, unit: "bpm",
                                            caption: latest.map { "Latest · \(Format.time($0.time))" })) {
                if logged.count >= 2 {
                    Chart(logged) { reading in
                        LineMark(x: .value("Time", reading.time), y: .value("bpm", reading.bpm))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Section2.heart.accent)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 34)
                }
            }
        }
    }
}

private struct SectionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 17))
            configuration.title
        }
    }
}

// MARK: - Tile

struct VitalReading {
    var status: String? = nil
    var statusColor: Color = .secondary
    var headline: String? = nil
    var unit: String? = nil
    var isWord = false          // a status word rather than a number
    var crown = false
    var caption: String? = nil

    /// A score card: band word in its colour, the number, a crown when optimal.
    static func score(_ score: Score?) -> VitalReading {
        VitalReading(status: score?.band.rawValue,
                     statusColor: score.map { Palette.color($0.band) } ?? .secondary,
                     headline: score.map { String($0.value) },
                     crown: score?.band == .optimal)
    }
}

/// Oura-style card: title and chevron, a coloured status, an optional
/// graphic, and the big value at the bottom.
struct VitalTile<Accessory: View, Backdrop: View>: View {
    let title: String
    let reading: VitalReading
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var backdrop: Backdrop

    private static var crownColor: Color { Color(red: 0.88, green: 0.72, blue: 0.38) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.card
            RadialGradient(colors: [Color.white.opacity(0.045), .clear],
                           center: UnitPoint(x: 0.35, y: 0.6), startRadius: 0, endRadius: 170)
            backdrop

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if let status = reading.status {
                    Text(status).font(.subheadline).foregroundStyle(reading.statusColor)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 6)
                accessory
                Spacer(minLength: 6)
                headline
                if let caption = reading.caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(16)
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private var headline: some View {
        if let value = reading.headline {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: reading.isWord ? 26 : 40, weight: .light))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit = reading.unit {
                    Text(unit).font(.subheadline).foregroundStyle(.secondary)
                }
                if reading.crown {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Self.crownColor)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 18 }
                }
            }
        } else {
            Text("—").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
        }
    }
}

extension VitalTile where Accessory == EmptyView, Backdrop == EmptyView {
    init(title: String, reading: VitalReading) {
        self.init(title: title, reading: reading, accessory: { EmptyView() }, backdrop: { EmptyView() })
    }
}

extension VitalTile where Backdrop == EmptyView {
    init(title: String, reading: VitalReading, @ViewBuilder accessory: () -> Accessory) {
        self.init(title: title, reading: reading, accessory: accessory, backdrop: { EmptyView() })
    }
}

// MARK: - Tile graphics

/// The glowing horizon on Oura's Symptom Radar card.
struct RadarSphere: View {
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let r = w
            ZStack {
                Circle()
                    .stroke(color.opacity(0.28), lineWidth: 1)
                    .frame(width: r * 2 + 22, height: r * 2 + 22)
                Circle()
                    .fill(RadialGradient(colors: [.clear, color.opacity(0.08), color.opacity(0.5)],
                                         center: .center, startRadius: r * 0.55, endRadius: r))
                    .frame(width: r * 2, height: r * 2)
                Circle()
                    .stroke(LinearGradient(colors: [color, color.opacity(0)],
                                           startPoint: .top, endPoint: .center),
                            lineWidth: 2.5)
                    .frame(width: r * 2, height: r * 2)
            }
            .position(x: w * 0.92, y: w * 1.23)
        }
        .allowsHitTesting(false)
    }
}

/// Two arcs: the upper is your rhythm with its ideal window lit, the lower
/// last night's sleep midpoint. ±8 hours around your usual midpoint spans
/// the card.
struct BodyClockArcs: View {
    let clock: BodyClock

    private func position(_ hour: Double) -> CGFloat {
        var delta = hour - clock.chronotypeHour
        if delta > 12 { delta -= 24 } else if delta < -12 { delta += 24 }
        return CGFloat(max(0, min(1, (delta + 8) / 16)))
    }

    /// y on a symmetric quadratic arc whose ends sit `sag` below its peak.
    private func arcY(_ t: CGFloat, base: CGFloat, sag: CGFloat) -> CGFloat {
        base + sag * (1 - 2 * t) * (1 - 2 * t)
    }

    private func arc(width: CGFloat, base: CGFloat, sag: CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: base + sag))
            p.addQuadCurve(to: CGPoint(x: width, y: base + sag),
                           control: CGPoint(x: width / 2, y: base - sag))
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width + 32           // run under the card padding
            let sag: CGFloat = 12
            let upper: CGFloat = 14, lower: CGFloat = 30
            let ideal = (position(clock.chronotypeHour - 4), position(clock.chronotypeHour + 4))
            let mine = position(clock.chronotypeHour)
            let lastNight = position(clock.lastNightHour)

            ZStack(alignment: .topLeading) {
                arc(width: w, base: upper, sag: sag)
                    .stroke(Color.white.opacity(0.14), lineWidth: 4)
                arc(width: w, base: upper, sag: sag)
                    .trimmedPath(from: ideal.0, to: ideal.1)
                    .stroke(Palette.rem, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                arc(width: w, base: lower, sag: sag)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1.5)

                Circle()
                    .stroke(.white, lineWidth: 2)
                    .background(Circle().fill(Palette.card))
                    .frame(width: 11, height: 11)
                    .position(x: mine * w, y: arcY(mine, base: upper, sag: sag))
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .position(x: lastNight * w, y: arcY(lastNight, base: lower, sag: sag))
            }
            .offset(x: -16)
        }
        .frame(height: 48)
        .allowsHitTesting(false)
    }
}

/// The day's stress readings as small bars in their zone colours.
struct StressBars: View {
    let samples: [SeriesSample]

    var body: some View {
        let shown = samples.count > 40
            ? stride(from: 0, to: samples.count, by: Int(ceil(Double(samples.count) / 40))).map { samples[$0] }
            : samples
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(shown) { sample in
                Capsule()
                    .fill(DaytimeStress.Zone(sample.value).color)
                    .frame(maxWidth: 6)
                    .frame(height: max(4, 34 * sample.value / 100))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 34, alignment: .bottomLeading)
    }
}

struct ResilienceMeter: View {
    let level: Resilience.Level

    var body: some View {
        let index = Resilience.Level.allCases.firstIndex(of: level) ?? 0
        HStack(spacing: 4) {
            ForEach(Array(Resilience.Level.allCases.enumerated()), id: \.offset) { i, _ in
                Capsule()
                    .fill(i <= index ? level.color : Color.white.opacity(0.1))
                    .frame(height: 6)
            }
        }
    }
}

struct ProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color)
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Core metric tile

struct CoreMetricTile: View {
    @EnvironmentObject private var store: RingStore
    let metric: CoreMetric
    let day: String

    var body: some View {
        let raw = store.metrics(on: day)?[keyPath: metric.keyPath]
        let baseline = store.baseline(metric.keyPath, before: day)
        let shown = raw.map { metric.isDeviation ? $0 - (baseline?.mean ?? $0) : $0 }
        let status = raw.flatMap { value in baseline.map { CoreMetricStatus(metric: metric, z: $0.z(value)) } }

        VitalTile(title: metric.shortTitle,
                  reading: VitalReading(status: status?.label,
                                        statusColor: status?.color ?? .secondary,
                                        headline: shown.map(metric.format),
                                        unit: metric.unit)) {
            Sparkline(metric: metric, day: day)
        }
    }
}

/// Where a value sits against your normal range (±1 SD).
struct CoreMetricStatus {
    let label: String
    let color: Color

    init(metric: CoreMetric, z: Double) {
        if abs(z) < 1 {
            label = "Normal"; color = Palette.optimal
        } else {
            let above = z > 0
            label = above ? "Above normal" : "Below normal"
            let good = metric.higherIsBetter.map { $0 == above } ?? false
            color = good ? Palette.good : Palette.fair
        }
    }
}

/// Last two weeks to the selected day, over your normal band.
private struct Sparkline: View {
    @EnvironmentObject private var store: RingStore
    let metric: CoreMetric
    let day: String

    var body: some View {
        let series = store.daily.filter { $0.dayKey <= day }.prefix(14).reversed()
            .compactMap { m in m[keyPath: metric.keyPath].map { (m.dayKey, $0) } }
        let baseline = store.baseline(metric.keyPath, before: day)
        if series.count >= 2 {
            Chart {
                if let baseline {
                    ForEach(series, id: \.0) { key, _ in
                        AreaMark(x: .value("Day", key),
                                 yStart: .value("Low", baseline.mean - baseline.sd),
                                 yEnd: .value("High", baseline.mean + baseline.sd))
                            .foregroundStyle(Color.white.opacity(0.06))
                    }
                }
                ForEach(series, id: \.0) { key, value in
                    LineMark(x: .value("Day", key), y: .value(metric.unit, value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(metric.accent)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 34)
        }
    }
}

// MARK: - Date strip

/// Days run left to right with the selected one centred and underlined.
/// Swipe the strip, tap a day, or tap the selected day for a calendar.
struct VitalsDateStrip: View {
    @Binding var selection: String
    let days: [String]
    let openCalendar: () -> Void

    private let itemWidth: CGFloat = 128

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(days, id: \.self) { day in
                            item(day).frame(width: itemWidth).id(day)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, max(0, (geo.size.width - itemWidth) / 2), for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: Binding(
                    get: { Optional(selection) },
                    set: { if let day = $0, day != selection { selection = day } }),
                    anchor: .center)
                .task { proxy.scrollTo(selection, anchor: .center) }
                .onChange(of: selection) { _, day in
                    withAnimation(.snappy) { proxy.scrollTo(day, anchor: .center) }
                }
            }
        }
        .frame(height: 46)
        .background(Palette.background)
    }

    private func item(_ day: String) -> some View {
        let selected = day == selection
        return Button {
            if selected { openCalendar() } else { withAnimation(.snappy) { selection = day } }
        } label: {
            VStack(spacing: 9) {
                HStack(spacing: 5) {
                    Text(DayKey.friendly(day))
                    if selected { Image(systemName: "calendar").font(.footnote) }
                }
                .font(.subheadline.weight(selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                Rectangle()
                    .fill(selected ? Color.white : .clear)
                    .frame(height: 1.5)
                    .padding(.horizontal, 18)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct VitalsCalendar: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    let firstDay: String?

    var body: some View {
        NavigationStack {
            DatePicker("Day",
                       selection: Binding(
                        get: { DayKey.date(selection) ?? Date() },
                        set: { selection = DayKey.of($0); dismiss() }),
                       in: (firstDay.flatMap(DayKey.date) ?? .distantPast)...Date(),
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal)
                .navigationTitle("Go to day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Today") { selection = DayKey.of(Date()); dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Drag sections into order and tap Done, like Oura's pencil editor.
struct VitalsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var order: [VitalsSection]
    @State private var draft: [VitalsSection] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(draft) { section in
                        Label(section.title, systemImage: section.symbol)
                    }
                    .onMove { draft.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("Drag to reorder.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .tint(.white)
            .navigationTitle("Edit Vitals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { order = draft; dismiss() }
                }
            }
            .onAppear { draft = order }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Core metric detail

struct CoreMetricDetail: View {
    @EnvironmentObject private var store: RingStore
    let metric: CoreMetric
    @Binding var day: String

    @State private var span = 30

    var body: some View {
        let baseline = store.baseline(metric.keyPath, before: day)
        let raw = store.metrics(on: day)?[keyPath: metric.keyPath]
        let shift = metric.isDeviation ? (baseline?.mean ?? 0) : 0
        let series = store.daily.filter { $0.dayKey <= day }.prefix(span).reversed()
            .compactMap { m in m[keyPath: metric.keyPath].map { (m.dayKey, $0 - shift) } }
        let scale = metric.displayScale

        DetailScaffold(title: metric.title, section: .readiness,
                       day: $day, days: store.availableDays) {
            Card {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(raw.map { metric.format($0 - shift) } ?? "—")
                        .font(.system(size: 44, weight: .light, design: .rounded))
                        .monospacedDigit()
                    Text(metric.unit).font(.subheadline).foregroundStyle(.secondary)
                }
                if let raw, let baseline {
                    let status = CoreMetricStatus(metric: metric, z: baseline.z(raw))
                    Text(status.label).font(.subheadline).foregroundStyle(status.color)
                }
                if let baseline {
                    Text("Your normal range: \(metric.format(baseline.mean - baseline.sd - shift)) to \(metric.format(baseline.mean + baseline.sd - shift)) \(metric.unit)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Picker("Range", selection: $span) {
                Text("Week").tag(7)
                Text("Month").tag(30)
                Text("Year").tag(365)
            }
            .pickerStyle(.segmented)

            Card(title: "Trend") {
                if series.count >= 2 {
                    Chart {
                        if let baseline {
                            ForEach(series, id: \.0) { key, _ in
                                AreaMark(x: .value("Day", key),
                                         yStart: .value("Low", (baseline.mean - baseline.sd - shift) * scale),
                                         yEnd: .value("High", (baseline.mean + baseline.sd - shift) * scale))
                                    .foregroundStyle(Color.white.opacity(0.07))
                            }
                        }
                        ForEach(series, id: \.0) { key, value in
                            LineMark(x: .value("Day", key), y: .value(metric.unit, value * scale))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(metric.accent)
                            PointMark(x: .value("Day", key), y: .value(metric.unit, value * scale))
                                .foregroundStyle(key == day ? Color.white : metric.accent)
                                .symbolSize(key == day ? 60 : (span > 30 ? 6 : 18))
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 170)
                    Text("Shaded band is your normal range.").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text("Need a few more days.").font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Card(title: "About") {
                Text(metric.about).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Sleep debt detail

struct SleepDebtDetail: View {
    @EnvironmentObject private var store: RingStore
    @Binding var day: String

    var body: some View {
        DetailScaffold(title: "Sleep Debt", section: .sleep,
                       day: $day, days: store.availableDays) {
            let debt = store.sleepDebt(on: day)
            let need = store.sleepNeed(asOf: day)
            Card {
                HStack(alignment: .top) {
                    summary("Sleep debt",
                            debt.map { Format.duration(Int($0.minutes.rounded())) } ?? "—",
                            note: debt?.level.rawValue, color: debt?.level.color)
                    summary("Sleep need", Format.duration(Int(need.minutes)),
                            note: need.isLearned ? "Learned" : "Default")
                    summary("Total sleep",
                            store.metrics(on: day)?.asleepMinutes.map(Format.duration) ?? "—")
                }
            }

            let history = trailingDays(14).map { key in
                (key, store.metrics(on: key)?.asleepMinutes, store.sleepDebt(on: key)?.minutes)
            }
            Card(title: "Last two weeks",
                 footnote: "Bars are total sleep; the dashed line is your sleep need and the line on top your running debt.") {
                Chart {
                    ForEach(history, id: \.0) { key, asleep, _ in
                        if let asleep {
                            BarMark(x: .value("Day", key), y: .value("Hours", Double(asleep) / 60))
                                .foregroundStyle(Section2.sleep.accent.opacity(key == day ? 1 : 0.45))
                                .cornerRadius(3)
                        }
                    }
                    RuleMark(y: .value("Need", need.minutes / 60))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.white.opacity(0.35))
                    ForEach(history, id: \.0) { key, _, debt in
                        if let debt {
                            LineMark(x: .value("Day", key), y: .value("Hours", debt / 60),
                                     series: .value("Series", "Debt"))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(Palette.fair)
                        }
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: 160)
            }

            Card(title: "How it works") {
                Text(need.isLearned
                     ? "Your sleep need is learned from how long you slept on recent nights after which your resting heart rate and HRV came out at or better than your normal."
                     : "Until there are five recent nights after which your resting heart rate and HRV came out at or better than normal, sleep need assumes 8 hours.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Debt looks back two weeks. Each short night adds to it, extra sleep pays it back, and older nights count for less. It needs five nights in that window.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func trailingDays(_ count: Int) -> [String] {
        guard let date = DayKey.date(day) else { return [] }
        return (0..<count).reversed().compactMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: date).map(DayKey.of)
        }
    }

    private func summary(_ title: String, _ value: String,
                         note: String? = nil, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .light, design: .rounded)).monospacedDigit()
            if let note { Text(note).font(.caption).foregroundStyle(color ?? .secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Stress detail

struct StressDetail: View {
    @EnvironmentObject private var store: RingStore
    @Binding var day: String

    var body: some View {
        DetailScaffold(title: "Daytime Stress", section: .stress,
                       day: $day, days: store.availableDays) {
            if let stress = store.daytimeStress(on: day) {
                Card {
                    Text(stress.summary.rawValue.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(stress.summary.color)
                    HStack(spacing: 0) {
                        total("Stressed", stress.stressedMinutes, DaytimeStress.Zone.stressed.color)
                        total("Restored", stress.restoredMinutes, DaytimeStress.Zone.restored.color)
                    }
                }

                Card(title: "Through the day",
                     footnote: "Logged by the ring while you're awake and still, so gaps are often activity rather than calm.") {
                    Chart(stress.samples) { sample in
                        BarMark(x: .value("Time", sample.time, unit: .minute),
                                y: .value("Stress", sample.value),
                                width: .fixed(4))
                            .foregroundStyle(DaytimeStress.Zone(sample.value).color)
                            .cornerRadius(2)
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                            AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9))
                        }
                    }
                    .frame(height: 150)
                    HStack(spacing: 12) {
                        ForEach(DaytimeStress.Zone.allCases.reversed(), id: \.self) { zone in
                            HStack(spacing: 5) {
                                Circle().fill(zone.color).frame(width: 6, height: 6)
                                Text(zone.label).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Card(title: "No stress data",
                     footnote: "Turn on stress monitoring in Settings › Ring monitoring, then sync.") {
                    Text("Nothing logged for this day.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func total(_ title: String, _ minutes: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(Format.duration(Int(minutes)))
                .font(.system(size: 30, weight: .light, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Resilience detail

struct ResilienceDetail: View {
    @EnvironmentObject private var store: RingStore
    @Binding var day: String

    var body: some View {
        DetailScaffold(title: "Resilience", section: .stress,
                       day: $day, days: store.availableDays) {
            if let resilience = store.resilience(on: day) {
                Card {
                    Text(resilience.level.rawValue)
                        .font(.system(size: 34, weight: .regular, design: .serif))
                        .foregroundStyle(resilience.level.color)
                    ResilienceMeter(level: resilience.level)
                    Text("Based on \(resilience.days.count) of the last 14 days")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Card(title: "Contributors") {
                    ForEach(resilience.contributors) { ContributorRow(contributor: $0) }
                }

                let days = resilience.days.reversed()
                Card(title: "Stress and recovery",
                     footnote: "Restored time and unguided sessions above the line, stressed time below.") {
                    Chart {
                        ForEach(days, id: \.dayKey) { d in
                            BarMark(x: .value("Day", d.dayKey),
                                    y: .value("Minutes", d.stress.restoredMinutes + d.sessionMinutes))
                                .foregroundStyle(DaytimeStress.Zone.restored.color)
                                .cornerRadius(2)
                            BarMark(x: .value("Day", d.dayKey),
                                    y: .value("Minutes", -d.stress.stressedMinutes))
                                .foregroundStyle(DaytimeStress.Zone.stressed.color)
                                .cornerRadius(2)
                        }
                        RuleMark(y: .value("Zero", 0)).foregroundStyle(.white.opacity(0.2))
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 150)
                }

                Card(title: "How it works") {
                    Text("Resilience weighs how much daytime stress you carry against how well you recover — restored time and sessions during the day, readiness overnight — averaged over two weeks.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Card(title: "Not enough data") {
                    Text("Resilience needs five days in the last two weeks with daytime stress logged and a scored night after it.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}
