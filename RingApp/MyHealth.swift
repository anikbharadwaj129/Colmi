import SwiftUI
import Charts

// MARK: - My Health
//
// Laid out after Oura's My Health tab: the Health Areas chart up top (icons on
// an arc, with 90-day rating lines), a card per area leading to its hub, then
// Habits and Routines as rolling 30-day averages, then Trends. Women's,
// metabolic and blood-pressure areas are left out — this ring has no data
// for them.

extension HealthRating {
    var color: Color {
        switch self {
        case .thriving:      return Palette.good
        case .lookingGood:   return Palette.optimal
        case .worthWatching: return Palette.fair
        case .needsCare:     return Palette.low
        }
    }
}

enum HealthArea: String, CaseIterable, Identifiable {
    case sleep, stress, heart

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sleep:  return "Sleep Health"
        case .stress: return "Stress Management"
        case .heart:  return "Heart Health"
        }
    }

    var symbol: String {
        switch self {
        case .sleep:  return "moon.fill"
        case .stress: return "waveform.path"
        case .heart:  return "heart.fill"
        }
    }

    var accent: Color {
        switch self {
        case .sleep:  return Section2.sleep.accent
        case .stress: return Section2.stress.accent
        case .heart:  return Section2.heart.accent
        }
    }

    /// What Oura says each rating rests on.
    var basis: String {
        switch self {
        case .sleep:  return "Based on your median Sleep Score from the past 14 days. Updated daily."
        case .stress: return "Based on your latest Cumulative Stress. Updated weekly."
        case .heart:  return "Based on your Cardiovascular Age. Updated weekly."
        }
    }
}

extension RingStore {
    func rating(_ area: HealthArea, on dayKey: String) -> HealthRating? {
        switch area {
        case .sleep:  return sleepHealth(on: dayKey)?.rating
        case .stress: return cumulativeStress(on: dayKey)?.rating
        case .heart:  return cardiovascularAge(on: dayKey)?.rating
        }
    }
}

struct MyHealthTab: View {
    @EnvironmentObject private var store: RingStore
    @State private var day = DayKey.of(Date())

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HealthAreasChart(day: day)

                    VStack(spacing: 10) {
                        ForEach(HealthArea.allCases) { area in
                            NavigationLink { hub(area) } label: { HealthAreaCard(area: area, day: day) }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        header("Habits and routines", "Your rolling 30-day averages")
                        LazyVGrid(columns: columns, spacing: 10) { HabitCards(day: $day) }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        header("Trends", "Day, week, month and year views")
                        VStack(spacing: 0) {
                            ForEach(TrendMetric.allCases) { metric in
                                NavigationLink { TrendsView(metric: metric) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: metric.symbol)
                                            .foregroundStyle(metric.accent)
                                            .frame(width: 24)
                                        Text(metric.title).font(.subheadline)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                if metric != TrendMetric.allCases.last {
                                    Divider().overlay(Palette.hairline).padding(.leading, 36)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.hairline, lineWidth: 1))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("My Health")
            .buttonStyle(.plain)
        }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 22, weight: .regular))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func hub(_ area: HealthArea) -> some View {
        switch area {
        case .sleep:  SleepHealthHub(day: $day)
        case .stress: StressManagementHub(day: $day)
        case .heart:  HeartHealthHub(day: $day)
        }
    }
}

// MARK: - Health Areas chart

/// Oura's arc: each area's icon sits on it in its rating colour, and a line
/// trails back through the last 90 days of ratings.
struct HealthAreasChart: View {
    @EnvironmentObject private var store: RingStore
    let day: String

    private struct Point: Identifiable {
        let area: HealthArea
        let week: Date
        let rating: HealthRating
        var id: String { "\(area.rawValue)-\(week.timeIntervalSince1970)" }
    }

    var body: some View {
        let weeks = HealthWeek.updateDays(through: day, weeks: 13)
        let points: [Point] = HealthArea.allCases.flatMap { area in
            weeks.compactMap { key in
                guard let date = DayKey.date(key),
                      let rating = store.rating(area, on: key == weeks.last ? day : key) else { return nil }
                return Point(area: area, week: date, rating: rating)
            }
        }
        VStack(spacing: 18) {
            arc
            if points.count >= 2 {
                Chart {
                    ForEach(HealthRating.allCases, id: \.self) { rating in
                        RectangleMark(yStart: .value("Low", Double(rating.rawValue) - 0.5),
                                      yEnd: .value("High", Double(rating.rawValue) + 0.5))
                            .foregroundStyle(rating.color.opacity(0.06))
                    }
                    ForEach(points) { point in
                        LineMark(x: .value("Week", point.week),
                                 y: .value("Rating", Double(point.rating.rawValue) + offset(point.area)),
                                 series: .value("Area", point.area.rawValue))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(point.area.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    }
                }
                .chartYScale(domain: -0.5...3.5)
                .chartYAxis {
                    AxisMarks(position: .leading, values: HealthRating.allCases.map { Double($0.rawValue) }) { value in
                        AxisValueLabel {
                            if let raw = value.as(Double.self), let rating = HealthRating(rawValue: Int(raw)) {
                                Text(rating.label).font(.system(size: 9)).foregroundStyle(rating.color)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated)).font(.system(size: 9))
                    }
                }
                .chartXScale(range: .plotDimension(startPadding: 4, endPadding: 18))
                .frame(height: 150)
                HStack(spacing: 14) {
                    ForEach(HealthArea.allCases) { area in
                        HStack(spacing: 5) {
                            Capsule().fill(area.accent).frame(width: 12, height: 3)
                            Text(area.title).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Each line is an area's rating over the last 90 days.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.hairline, lineWidth: 1))
    }

    private func offset(_ area: HealthArea) -> Double {
        switch area {
        case .sleep: return 0.12
        case .stress: return 0
        case .heart: return -0.12
        }
    }

    private var arc: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let radius = w * 0.42
            let center = CGPoint(x: w / 2, y: radius + 26)
            let angles: [Double] = [205, 270, 335]
            ZStack {
                Path { p in
                    p.addArc(center: center, radius: radius, startAngle: .degrees(190),
                             endAngle: .degrees(350), clockwise: false)
                }
                .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 2, dash: [2, 5]))
                ForEach(Array(HealthArea.allCases.enumerated()), id: \.element) { index, area in
                    let a = angles[index] * .pi / 180
                    let rating = store.rating(area, on: day)
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill((rating?.color ?? .white).opacity(rating == nil ? 0.06 : 0.2))
                            Circle().stroke(rating?.color ?? Color.white.opacity(0.2), lineWidth: 2)
                            Image(systemName: area.symbol)
                                .font(.system(size: 18))
                                .foregroundStyle(rating?.color ?? .secondary)
                        }
                        .frame(width: 50, height: 50)
                        Text(rating?.label ?? "Learning")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(rating?.color ?? .secondary)
                    }
                    .position(x: center.x + radius * cos(a), y: center.y + radius * sin(a) + 12)
                }
            }
        }
        .frame(height: 150)
    }
}

struct HealthAreaCard: View {
    @EnvironmentObject private var store: RingStore
    let area: HealthArea
    let day: String

    private var summary: (rating: HealthRating?, line: String) {
        switch area {
        case .sleep:
            if let health = store.sleepHealth(on: day) {
                return (health.rating, "Typical sleep score \(health.typical)")
            }
            let have = store.sleepScores(through: day, days: SleepHealth.windowDays).count
            return (nil, "Needs \(SleepHealth.minimumScores - have) more nights of sleep scores")
        case .stress:
            if let stress = store.cumulativeStress(on: day) {
                return (stress.rating, "Cumulative stress: \(stress.level.rawValue)")
            }
            return (nil, "Needs \(CumulativeStress.minimumDays) days of data in the past month")
        case .heart:
            if store.age == nil { return (nil, "Add your birth year in Settings") }
            if let cva = store.cardiovascularAge(on: day) {
                return (cva.rating, "Cardiovascular age \(Int(cva.age.rounded())) · \(cva.range.rawValue)")
            }
            return (nil, "Needs \(CardiovascularAgeReading.minimumNights) nights in the past 30")
        }
    }

    var body: some View {
        let summary = summary
        HStack(spacing: 14) {
            Image(systemName: area.symbol)
                .font(.system(size: 17))
                .foregroundStyle(summary.rating?.color ?? area.accent)
                .frame(width: 44, height: 44)
                .background((summary.rating?.color ?? area.accent).opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(area.title).font(.subheadline)
                Text(summary.rating?.label ?? "Learning")
                    .font(.title3)
                    .foregroundStyle(summary.rating?.color ?? .secondary)
                Text(summary.line).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.hairline, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

/// The rating at the top of each hub.
private struct HubHeader: View {
    let area: HealthArea
    let rating: HealthRating?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: area.symbol).foregroundStyle(rating?.color ?? area.accent)
                Text(area.title.uppercased())
                    .font(.caption2.weight(.semibold)).tracking(1.1)
                    .foregroundStyle(.secondary)
            }
            Text(rating?.label ?? "Still learning")
                .font(.system(size: 34, weight: .regular, design: .serif))
                .foregroundStyle(rating?.color ?? .primary)
            if let rating {
                Text(rating.meaning).font(.subheadline)
            }
            Text(area.basis).font(.caption).foregroundStyle(.secondary)
            ratingScale
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            ZStack {
                Palette.card
                LinearGradient(colors: [(rating?.color ?? area.accent).opacity(0.18), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22))
        }
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.hairline, lineWidth: 1))
    }

    /// The four steps, with the current one lit.
    private var ratingScale: some View {
        HStack(spacing: 4) {
            ForEach(HealthRating.allCases, id: \.self) { step in
                VStack(spacing: 4) {
                    Capsule()
                        .fill(step.color.opacity(step == rating ? 1 : 0.2))
                        .frame(height: step == rating ? 8 : 5)
                    Text(step.label)
                        .font(.system(size: 9))
                        .foregroundStyle(step == rating ? step.color : Color.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .padding(.top, 6)
    }
}

/// A tappable row inside a hub: label, value, status, chevron.
private struct HubRow<Destination: View>: View {
    let symbol: String
    let title: String
    let value: String
    var status: String? = nil
    var statusColor: Color = .secondary
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink { destination } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline)
                    if let status { Text(status).font(.caption).foregroundStyle(statusColor) }
                }
                Spacer()
                Text(value).font(.subheadline.monospacedDigit())
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct HubScaffold<Content: View>: View {
    let title: String
    let accent: Color
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 14) { content }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
        }
        .background(
            ZStack(alignment: .top) {
                Palette.background
                LinearGradient(colors: [accent.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 360)
            }
            .ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sleep Health hub

struct SleepHealthHub: View {
    @EnvironmentObject private var store: RingStore
    @Binding var day: String

    var body: some View {
        HubScaffold(title: "Sleep Health", accent: HealthArea.sleep.accent) {
            HubHeader(area: .sleep, rating: store.sleepHealth(on: day)?.rating)
            typicalScoreCard
            keyMetrics
            profile
        }
    }

    /// Oura: each point is the median Sleep Score of a 14-day window.
    private var typicalScoreCard: some View {
        let series = store.typicalSleepScores(through: day, days: 90)
            .compactMap { key, value in DayKey.date(key).map { (date: $0, value: value) } }
            .sorted { $0.date < $1.date }
        return Card(title: "Typical sleep score",
                    footnote: "Each point is your median Sleep Score over the 14 days before it.") {
            if let latest = series.last {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(latest.value)")
                        .font(.system(size: 40, weight: .light, design: .rounded))
                    Text(SleepHealth.rating(latest.value).label)
                        .font(.subheadline).foregroundStyle(SleepHealth.rating(latest.value).color)
                }
            }
            if series.count >= 2 {
                Chart(series, id: \.date) { point in
                    LineMark(x: .value("Day", point.date), y: .value("Score", point.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(HealthArea.sleep.accent)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated)).font(.system(size: 9))
                    }
                }
                .chartXScale(range: .plotDimension(startPadding: 4, endPadding: 18))
                .frame(height: 130)
            } else {
                Text("Needs \(SleepHealth.minimumScores) sleep scores in 14 days.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var keyMetrics: some View {
        let debt = store.sleepDebt(on: day)
        let regularity = ReadinessScore.sleepRegularity(store.daily, through: day)
        let breathing = store.daily.prefix(30).compactMap(\.respiratoryRate)
        return Card(title: "Key metrics") {
            HubRow(symbol: "hourglass", title: "Sleep debt",
                   value: debt.map { Format.duration(Int($0.minutes.rounded())) } ?? "—",
                   status: debt?.level.rawValue, statusColor: debt?.level.color ?? .secondary) {
                SleepDebtDetail(day: $day)
            }
            Divider().overlay(Palette.hairline)
            HubRow(symbol: "clock.arrow.2.circlepath", title: "Sleep regularity",
                   value: regularity.map { "±\(Int($0.rounded())) min" } ?? "—",
                   status: regularity.map(regularityLabel),
                   statusColor: regularity.map { $0 <= 45 ? Palette.optimal : ($0 <= 75 ? Palette.fair : Palette.low) } ?? .secondary) {
                SleepDetail(day: $day)
            }
            Divider().overlay(Palette.hairline)
            HubRow(symbol: "lungs", title: "Breathing rate",
                   value: breathing.isEmpty ? "—" : String(format: "%.1f br/min", HRV.mean(breathing)),
                   status: breathing.count >= 3
                       ? String(format: "30-day average · steady within ±%.1f", HRV.standardDeviation(breathing))
                       : "Needs overnight capture or unguided sessions") {
                CoreMetricDetail(metric: .respiratoryRate, day: $day)
            }
        }
    }

    private func regularityLabel(_ minutes: Double) -> String {
        minutes <= 45 ? "Regular" : (minutes <= 75 ? "Somewhat irregular" : "Irregular")
    }

    private var profile: some View {
        let need = store.sleepNeed(asOf: day)
        let chronotype = store.chronotype(on: day)
        return Card(title: "Sleep profile") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Daily sleep need").font(.caption).foregroundStyle(.secondary)
                Text(Format.duration(Int(need.minutes)))
                    .font(.system(size: 28, weight: .light, design: .rounded))
                Text(need.isLearned
                     ? "Learned from recent nights after which your body read as recovered."
                     : "8 hours until there are enough recovered nights to learn yours.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Divider().overlay(Palette.hairline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Chronotype").font(.caption).foregroundStyle(.secondary)
                if let chronotype {
                    Text(chronotype.kind.label)
                        .font(.system(size: 24, weight: .regular, design: .serif))
                    Text(chronotype.kind.detail).font(.subheadline)
                    Text("Typical mid-sleep \(Circadian.label(chronotype.midpointHour)) · \(chronotype.nights) nights")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    let have = store.daily.prefix(Chronotype.windowDays).filter { ($0.asleepMinutes ?? 0) >= 180 }.count
                    Text("Needs \(max(0, Chronotype.minimumNights - have)) more nights")
                        .font(.subheadline)
                    Text("Oura works out your chronotype from 90 days with at least 30 main sleeps.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Stress Management hub

struct StressManagementHub: View {
    @EnvironmentObject private var store: RingStore
    @Binding var day: String
    @State private var showResilience = false

    var body: some View {
        let stress = store.cumulativeStress(on: day)
        HubScaffold(title: "Stress Management", accent: HealthArea.stress.accent) {
            HubHeader(area: .stress, rating: stress?.rating)
            chartCard
            keyMetric(stress)
            Card(title: "Related") {
                let resilience = store.resilience(on: day)
                HubRow(symbol: "shield.lefthalf.filled", title: "Resilience",
                       value: resilience?.level.rawValue ?? "—",
                       status: resilience == nil ? "Needs 5 full days" : nil) {
                    ResilienceDetail(day: $day)
                }
                Divider().overlay(Palette.hairline)
                let daytime = store.daytimeStress(on: day)
                HubRow(symbol: "sun.max", title: "Daytime stress",
                       value: daytime?.summary.rawValue ?? "—",
                       status: daytime.map { "\(Format.duration(Int($0.stressedMinutes))) stressed today" }) {
                    StressDetail(day: $day)
                }
            }
        }
    }

    /// Oura's hub chart toggles between Cumulative Stress and Resilience.
    private var chartCard: some View {
        let weeks = HealthWeek.updateDays(through: day, weeks: 13)
        return Card {
            Picker("Chart", selection: $showResilience) {
                Text("Cumulative stress").tag(false)
                Text("Resilience").tag(true)
            }
            .pickerStyle(.segmented)
            if showResilience {
                let points = weeks.compactMap { key -> (Date, Resilience.Level)? in
                    guard let date = DayKey.date(key), let r = store.resilience(on: key) else { return nil }
                    return (date, r.level)
                }
                if points.count >= 2 {
                    Chart(points, id: \.0) { date, level in
                        let index = Resilience.Level.allCases.firstIndex(of: level) ?? 0
                        LineMark(x: .value("Week", date), y: .value("Level", index))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(HealthArea.stress.accent)
                        PointMark(x: .value("Week", date), y: .value("Level", index))
                            .foregroundStyle(level.color)
                    }
                    .chartYScale(domain: 0...4)
                    .chartXScale(range: .plotDimension(startPadding: 4, endPadding: 18))
                    .chartYAxis {
                        AxisMarks(values: [0, 1, 2, 3, 4]) { value in
                            AxisValueLabel {
                                if let i = value.as(Int.self) {
                                    Text(Resilience.Level.allCases[i].rawValue).font(.system(size: 9))
                                }
                            }
                        }
                    }
                    .frame(height: 140)
                } else {
                    Text("Needs a few weeks of resilience.").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                let points = weeks.compactMap { key -> (Date, CumulativeStress)? in
                    guard let date = DayKey.date(key), let s = store.cumulativeStress(on: key) else { return nil }
                    return (date, s)
                }
                if !points.isEmpty {
                    Chart(points, id: \.0) { date, stress in
                        BarMark(x: .value("Week", date, unit: .weekOfYear), y: .value("Strain", 100 - stress.score))
                            .foregroundStyle(stress.rating.color)
                            .cornerRadius(3)
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis(.hidden)
                    .chartXScale(range: .plotDimension(startPadding: 4, endPadding: 18))
                    .frame(height: 140)
                    Text("Weekly. Taller bars mean more strain built up over the month before.")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text("Needs \(CumulativeStress.minimumDays) days of data in a month.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func keyMetric(_ stress: CumulativeStress?) -> some View {
        Card(title: "Key metric · Cumulative stress",
             footnote: "Looks at the past 31 days and updates weekly. Oura also uses sleep micromotions, which needs raw motion data this ring doesn't share.") {
            if let stress {
                HStack(alignment: .firstTextBaseline) {
                    Text(stress.level.rawValue)
                        .font(.system(size: 30, weight: .regular, design: .serif))
                        .foregroundStyle(stress.rating.color)
                    Spacer()
                    Text("Week of \(DayKey.full(stress.asOf))").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(stress.contributors) { ContributorRow(contributor: $0) }
            } else {
                Text("Cumulative stress needs at least \(CumulativeStress.minimumDays) days of data in the past \(CumulativeStress.windowDays).")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Heart Health hub

struct HeartHealthHub: View {
    @EnvironmentObject private var store: RingStore
    @Binding var day: String

    var body: some View {
        let cva = store.cardiovascularAge(on: day)
        HubScaffold(title: "Heart Health", accent: HealthArea.heart.accent) {
            HubHeader(area: .heart, rating: cva?.rating)
            cvaCard(cva)
            capacityCard
            Card(title: "Related") {
                HubRow(symbol: "heart", title: "Resting heart rate",
                       value: store.metrics(on: day)?.restingHR.map { String(format: "%.0f bpm", $0) } ?? "—") {
                    TrendsView(metric: .restingHR)
                }
                Divider().overlay(Palette.hairline)
                HubRow(symbol: "waveform.path.ecg", title: "Heart rate variability",
                       value: store.metrics(on: day)?.rmssd.map { String(format: "%.0f ms", $0) } ?? "—") {
                    TrendsView(metric: .hrv)
                }
            }
        }
    }

    private func cvaCard(_ cva: CardiovascularAgeReading?) -> some View {
        let readings = HealthWeek.updateDays(through: day, weeks: 13).compactMap { store.cardiovascularAge(on: $0) }
        return Card(title: "Cardiovascular age",
                    footnote: "Oura estimates this from pulse wave velocity, which needs the raw PPG waveform. This ring only shares computed values, so it's built from resting heart rate, HRV and blood oxygen instead.") {
            if let cva {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(cva.age.rounded()))")
                        .font(.system(size: 44, weight: .light, design: .rounded))
                    Text("vs \(cva.chronologicalAge) actual").font(.subheadline).foregroundStyle(.secondary)
                }
                Text("\(cva.range.rawValue) — \(cva.range.detail)")
                    .font(.subheadline).foregroundStyle(cva.rating.color)
                if readings.count >= 2 {
                    Chart {
                        ForEach(readings, id: \.asOf) { reading in
                            if let date = DayKey.date(reading.asOf) {
                                LineMark(x: .value("Week", date), y: .value("Age", reading.age))
                                    .interpolationMethod(.monotone)
                                    .foregroundStyle(HealthArea.heart.accent)
                                PointMark(x: .value("Week", date), y: .value("Age", reading.age))
                                    .foregroundStyle(HealthArea.heart.accent)
                            }
                        }
                        RuleMark(y: .value("Actual", cva.chronologicalAge))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.white.opacity(0.4))
                            .annotation(position: .top, alignment: .leading) {
                                Text("Actual age").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXScale(range: .plotDimension(startPadding: 4, endPadding: 18))
                    .frame(height: 140)
                }
            } else if store.age == nil {
                Text("Add your birth year in Settings to see your cardiovascular age.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Needs \(CardiovascularAgeReading.minimumNights) nights in the past 30. Updates weekly.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func capacityColor(_ level: CardiovascularIndex.CapacityLevel?) -> Color {
        switch level {
        case .peak:  return Palette.good
        case .high:  return Palette.optimal
        case .fair:  return Palette.fair
        case .low:   return Palette.low
        case nil:    return .secondary
        }
    }

    private var capacityCard: some View {
        let cv = store.cardiovascular(on: day)
        return Card(title: "Cardio capacity") {
            HubRow(symbol: "lungs.fill", title: "VO₂max",
                   value: cv?.vo2max.map { String(format: "%.1f", $0) } ?? "—",
                   status: cv?.capacityLevel.map { "\($0.rawValue) for your age group" },
                   statusColor: capacityColor(cv?.capacityLevel)) {
                HeartDetail(day: $day)
            }
        }
    }
}

// MARK: - Habits and routines

struct HabitCards: View {
    @EnvironmentObject private var store: RingStore
    @Binding var day: String

    /// Last 30 days and the 30 before, for the change line.
    private func windows<T>(_ values: [String: T]) -> (current: [T], previous: [T]) {
        let current = dayKeys(endingOn: day, count: 30).compactMap { values[$0] }
        let previousEnd = DayKey.date(day).flatMap { Calendar.current.date(byAdding: .day, value: -30, to: $0) }
            .map(DayKey.of) ?? day
        let previous = dayKeys(endingOn: previousEnd, count: 30).compactMap { values[$0] }
        return (current, previous)
    }

    private func change(_ current: [Double], _ previous: [Double], format: (Double) -> String) -> String? {
        guard !current.isEmpty, previous.count >= 7 else { return nil }
        let delta = HRV.mean(current) - HRV.mean(previous)
        return (delta >= 0 ? "▲ " : "▼ ") + format(abs(delta)) + " vs prior 30 days"
    }

    var body: some View {
        let steps = Dictionary(uniqueKeysWithValues: store.activityDays.map { ($0.dayKey, $0.steps) })
        let burn = Dictionary(uniqueKeysWithValues: store.activityDays.filter { $0.activeCalories > 0 }
            .map { ($0.dayKey, $0.activeCalories) })
        let sleep = Dictionary(uniqueKeysWithValues: store.daily.compactMap { m in
            m.asleepMinutes.map { (m.dayKey, Double($0)) } })
        let s = windows(steps), b = windows(burn), t = windows(sleep)
        let regularity = ReadinessScore.sleepRegularity(store.daily, through: day, days: 30)

        NavigationLink { TrendsView(metric: .steps) } label: {
            VitalTile(title: "Step average",
                      reading: VitalReading(headline: s.current.isEmpty ? nil : Int(HRV.mean(s.current)).formatted(),
                                            unit: "/day",
                                            caption: change(s.current, s.previous) { Int($0).formatted() }))
        }
        NavigationLink { TrendsView(metric: .activityBurn) } label: {
            VitalTile(title: "Activity burn",
                      reading: VitalReading(headline: b.current.isEmpty ? nil : String(format: "%.0f", HRV.mean(b.current)),
                                            unit: "kcal",
                                            caption: store.weight == nil ? "Add weight in Settings"
                                                : change(b.current, b.previous) { String(format: "%.0f kcal", $0) }))
        }
        NavigationLink { SleepHealthHub(day: $day) } label: {
            VitalTile(title: "Sleep regularity",
                      reading: VitalReading(status: regularity.map { $0 <= 45 ? "Regular" : ($0 <= 75 ? "Somewhat irregular" : "Irregular") },
                                            statusColor: regularity.map { $0 <= 45 ? Palette.optimal : ($0 <= 75 ? Palette.fair : Palette.low) } ?? .secondary,
                                            headline: regularity.map { "±\(Int($0.rounded()))" },
                                            unit: "min",
                                            caption: "Bedtime and wake time spread"))
        }
        NavigationLink { TrendsView(metric: .totalSleep) } label: {
            VitalTile(title: "Total sleep",
                      reading: VitalReading(headline: t.current.isEmpty ? nil : Format.duration(Int(HRV.mean(t.current))),
                                            caption: change(t.current, t.previous) { Format.duration(Int($0)) }))
        }
    }
}

// MARK: - Trends

enum TrendMetric: String, CaseIterable, Identifiable {
    case readiness, sleepScore, activityScore, steps, activityBurn, totalSleep,
         restingHR, hrv, temperature, respiratoryRate, daytimeStress

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readiness:       return "Readiness"
        case .sleepScore:      return "Sleep score"
        case .activityScore:   return "Activity score"
        case .steps:           return "Steps"
        case .activityBurn:    return "Activity burn"
        case .totalSleep:      return "Total sleep"
        case .restingHR:       return "Resting heart rate"
        case .hrv:             return "Heart rate variability"
        case .temperature:     return "Body temperature"
        case .respiratoryRate: return "Respiratory rate"
        case .daytimeStress:   return "Daytime stress"
        }
    }

    var symbol: String {
        switch self {
        case .readiness:       return Section2.readiness.symbol
        case .sleepScore, .totalSleep: return Section2.sleep.symbol
        case .activityScore, .steps, .activityBurn: return Section2.activity.symbol
        case .restingHR:       return "heart"
        case .hrv:             return "waveform.path.ecg"
        case .temperature:     return "thermometer.medium"
        case .respiratoryRate: return "lungs"
        case .daytimeStress:   return Section2.stress.symbol
        }
    }

    var accent: Color {
        switch self {
        case .readiness:       return Section2.readiness.accent
        case .sleepScore, .totalSleep: return Section2.sleep.accent
        case .activityScore, .steps, .activityBurn: return Section2.activity.accent
        case .restingHR, .hrv: return Section2.heart.accent
        case .temperature, .daytimeStress: return Section2.stress.accent
        case .respiratoryRate: return Section2.bodyClock.accent
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .readiness, .sleepScore, .activityScore, .daytimeStress: return String(format: "%.0f", value)
        case .steps:           return Int(value).formatted()
        case .activityBurn:    return String(format: "%.0f kcal", value)
        case .totalSleep:      return Format.duration(Int(value))
        case .restingHR:       return String(format: "%.0f bpm", value)
        case .hrv:             return String(format: "%.0f ms", value)
        case .temperature:     return Format.temperatureDelta(value, decimals: 2)
        case .respiratoryRate: return String(format: "%.1f br/min", value)
        }
    }

    /// Every day with a value, by day key.
    @MainActor
    func series(_ store: RingStore) -> [String: Double] {
        let days = store.availableDays
        func each(_ value: (String) -> Double?) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: days.compactMap { key in value(key).map { (key, $0) } })
        }
        func metric(_ keyPath: KeyPath<DailyMetrics, Double?>) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: store.daily.compactMap { m in m[keyPath: keyPath].map { (m.dayKey, $0) } })
        }
        switch self {
        case .readiness:     return each { store.readiness(on: $0).map { Double($0.value) } }
        case .sleepScore:    return each { store.sleepScore(on: $0).map { Double($0.value) } }
        case .activityScore: return each { store.activityScore(on: $0).map { Double($0.value) } }
        case .steps:
            return Dictionary(uniqueKeysWithValues: store.activityDays.map { ($0.dayKey, $0.steps) })
        case .activityBurn:
            return Dictionary(uniqueKeysWithValues: store.activityDays.filter { $0.activeCalories > 0 }
                .map { ($0.dayKey, $0.activeCalories) })
        case .totalSleep:
            return Dictionary(uniqueKeysWithValues: store.daily.compactMap { m in
                m.asleepMinutes.map { (m.dayKey, Double($0)) } })
        case .restingHR:       return metric(\.restingHR)
        case .hrv:             return metric(\.rmssd)
        case .respiratoryRate: return metric(\.respiratoryRate)
        case .daytimeStress:   return metric(\.stressAverage)
        case .temperature:
            // As a deviation from your two-month normal, the way Oura shows it.
            return each { key in
                guard let t = store.metrics(on: key)?.nightTemperature,
                      let b = store.baseline(\.nightTemperature, before: key) else { return nil }
                return t - b.mean
            }
        }
    }
}

struct TrendsView: View {
    @EnvironmentObject private var store: RingStore
    let metric: TrendMetric
    @State private var span = TrendSpan.day

    var body: some View {
        let series = metric.series(store)
        let points = Trends.aggregate(series, span: span)
        let average = Trends.average(series, span: span)
        HubScaffold(title: metric.title, accent: metric.accent) {
            Picker("Span", selection: $span) {
                ForEach(TrendSpan.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.top, 8)

            Card {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(points.last?.start))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(points.last.map { metric.format($0.value) } ?? "—")
                            .font(.system(size: 36, weight: .light, design: .rounded))
                            .monospacedDigit()
                    }
                    Spacer()
                    if let average {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(span == .day ? "90-day average" : "All-time average")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(metric.format(average))
                                .font(.subheadline.monospacedDigit())
                        }
                    }
                }
                if points.count >= 2 {
                    Chart {
                        ForEach(points) { point in
                            if span == .day {
                                BarMark(x: .value("Day", point.start, unit: .day), y: .value(metric.title, point.value))
                                    .foregroundStyle(metric.accent.opacity(point.id == points.last?.id ? 1 : 0.55))
                                    .cornerRadius(2)
                            } else {
                                LineMark(x: .value("Period", point.start), y: .value(metric.title, point.value))
                                    .interpolationMethod(.monotone)
                                    .foregroundStyle(metric.accent)
                                PointMark(x: .value("Period", point.start), y: .value(metric.title, point.value))
                                    .foregroundStyle(metric.accent)
                                    .symbolSize(24)
                            }
                        }
                        if let average {
                            RuleMark(y: .value("Average", average))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: metric == .steps || metric == .activityBurn))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel(format: axisFormat).font(.system(size: 9))
                        }
                    }
                    .chartXScale(range: .plotDimension(startPadding: 4, endPadding: 28))
                    .frame(height: 200)
                } else {
                    Text("Not enough data yet.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Card {
                Text(span == .day
                     ? "Day view shows the last 30 days; the dashed line is your 90-day average."
                     : "Each point averages the \(span.rawValue.lowercased()). The dashed line is your average since your data began.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var axisFormat: Date.FormatStyle {
        switch span {
        case .day, .week: return .dateTime.month(.abbreviated).day()
        case .month:      return .dateTime.month(.abbreviated)
        case .year:       return .dateTime.year()
        }
    }

    private func label(_ start: Date?) -> String {
        guard let start else { return "Latest" }
        switch span {
        case .day:   return start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        case .week:  return "Week of " + start.formatted(.dateTime.month(.abbreviated).day())
        case .month: return start.formatted(.dateTime.month(.wide).year())
        case .year:  return start.formatted(.dateTime.year())
        }
    }
}
