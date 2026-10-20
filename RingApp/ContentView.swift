import SwiftUI
import Charts

// MARK: - App

@main
struct RingAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services.ring)
                .environmentObject(services.store)
                .environmentObject(services.health)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var ring: RingConnection
    @EnvironmentObject private var store: RingStore
    @EnvironmentObject private var health: HealthService
    @Environment(\.scenePhase) private var scenePhase

    private let sync: RingSync? = AppServices.shared.sync
    private let capture: RingCapture? = AppServices.shared.capture
    @State private var day = DayKey.of(Date())

    var body: some View {
        TabView {
            TodayTab(day: $day, sync: sync, capture: capture)
                .tabItem { Label("Today", systemImage: "sun.horizon") }
            VitalsTab(day: $day)
                .tabItem { Label("Vitals", systemImage: "leaf") }
            MyHealthTab()
                .tabItem { Label("My Health", systemImage: "tree") }
            DebugTab(capture: capture)
                .tabItem { Label("Debug", systemImage: "terminal") }
        }
        .tint(.white)
        .task {
            await health.requestAuthorization()
            if store.weight == nil, let kg = await health.latestBodyMass() { store.weightKg = kg }
            // Battery and inactivity are on by default, as in Oura.
            let notifier = AppServices.shared.notifier
            if notifier.enabled.values.contains(true) { await notifier.requestPermission() }
        }
        // Opening the app reconnects if needed and syncs if the last sync is
        // stale; leaving it hands over to background refresh.
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                day = DayKey.of(Date())
                AppServices.shared.monitor.appBecameActive()
            case .background:
                AppServices.shared.monitor.appEnteredBackground()
            default:
                break
            }
        }
    }
}

// MARK: - Today

struct TodayTab: View {
    @EnvironmentObject private var ring: RingConnection
    @EnvironmentObject private var store: RingStore
    @EnvironmentObject private var health: HealthService
    @Binding var day: String
    let sync: RingSync?
    let capture: RingCapture?

    @AppStorage("todayShortcuts") private var shortcutsRaw = Shortcut.encode(Shortcut.allCases)
    @State private var showTags = false
    @State private var showSettings = false
    @State private var showShortcutEditor = false
    @State private var showSession = false
    @State private var showWorkout = false

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    shortcuts
                    SymptomRadarCard(day: $day)
                    RestModeCard()
                    hero
                    if let capture { HeartRateCard(capture: capture, day: $day) }
                    TimelineCard(day: $day)
                    ringCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 96)       // clear of the + button
            }
            .overlay(alignment: .bottomTrailing) { plusButton }
            .background(heroBackdrop)
            .navigationTitle(greeting)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "person.circle") }
                }
            }
            .refreshable { await sync?.syncAll() }
            .sheet(isPresented: $showTags) { TagSheet(day: day) }
            .sheet(isPresented: $showSettings) { SettingsSheet(capture: capture) }
            .fullScreenCover(isPresented: $showSession) {
                if let capture { UnguidedSessionFlow(capture: capture) }
            }
            .fullScreenCover(isPresented: $showWorkout) {
                if let capture { WorkoutFlow(capture: capture) }
            }
            .sheet(isPresented: $showShortcutEditor) {
                ShortcutEditor(selection: Binding(
                    get: { Shortcut.decode(shortcutsRaw) },
                    set: { shortcutsRaw = Shortcut.encode($0) }))
            }
        }
    }

    /// Oura's + menu: the things you start rather than wait for.
    private var plusButton: some View {
        Menu {
            Button { showSession = true } label: {
                Label("Unguided session", systemImage: "figure.mind.and.body")
            }
            Button { showTags = true } label: {
                Label("Add a tag", systemImage: "tag")
            }
            Button { showWorkout = true } label: {
                Label("Record workout heart rate", systemImage: "figure.run")
            }
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.medium))
                .foregroundStyle(.black)
                .frame(width: 56, height: 56)
                .background(.white, in: Circle())
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        }
        .menuOrder(.fixed)
        .disabled(capture == nil)
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .accessibilityLabel("Add")
    }

    private var heroBackdrop: some View {
        ZStack(alignment: .top) {
            Palette.background
            Section2.readiness.gradient.frame(height: 420)
        }
        .ignoresSafeArea()
    }

    /// Swipe to the end of the row to reach Customize.
    private var shortcuts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(Shortcut.decode(shortcutsRaw)) { shortcut in
                    NavigationLink { destination(shortcut) } label: {
                        let reading = reading(shortcut)
                        ShortcutCircle(title: shortcut.title,
                                       value: reading.value,
                                       symbol: shortcut.section.symbol,
                                       accent: shortcut.section.accent,
                                       isOptimal: reading.isOptimal)
                    }
                }
                Button { showShortcutEditor = true } label: {
                    VStack(spacing: 9) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 20, weight: .light))
                            .frame(width: 68, height: 68)
                            .overlay(Circle().stroke(Color.white.opacity(0.18),
                                                     style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        Text("Customize").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(width: 82)
                    .contentShape(Rectangle())
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .padding(.horizontal, -16)
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private func reading(_ shortcut: Shortcut) -> (value: String?, isOptimal: Bool) {
        let metrics = store.metrics(on: day)
        let score: Score?
        switch shortcut {
        case .readiness: score = store.readiness(on: day)
        case .sleep:     score = store.sleepScore(on: day)
        case .activity:
            if store.isRestMode(on: day) { return ("Rest", false) }
            score = store.activityScore(on: store.activityDayKey(showing: day))
        case .heartRate:
            return (metrics?.restingHR.map { String(format: "%.0f", $0) }, false)
        case .stress:
            return (metrics?.stressAverage.map { String(format: "%.0f", $0) }, false)
        }
        return (score.map { String($0.value) }, score?.band == .optimal)
    }

    @ViewBuilder
    private func destination(_ shortcut: Shortcut) -> some View {
        switch shortcut {
        case .readiness: ReadinessDetail(day: $day)
        case .sleep:     SleepDetail(day: $day)
        case .activity:  ActivityDetail(day: $day)
        case .heartRate: HeartDetail(day: $day)
        case .stress:    StressDetail(day: $day)
        }
    }

    /// One prominent thing, chosen by time of day and by what the data says.
    @ViewBuilder
    private var hero: some View {
        let hour = Calendar.current.component(.hour, from: Date())

        if hour >= 20, let night = store.night(on: day) {
            Card(accent: Section2.sleep.accent) {
                Text("Wind down").font(.caption).foregroundStyle(.secondary)
                Text("You slept \(Format.duration(night.asleepMinutes)) last night.")
                    .font(.title3)
                if let clock = store.bodyClock(on: day) {
                    Text(clock.alignment == .aligned
                         ? "Keeping tonight's bedtime near \(Circadian.label(clock.chronotypeHour - 4)) holds your rhythm steady."
                         : clock.detail)
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } else if let readiness = store.readiness(on: day) {
            Card {
                VStack(spacing: 14) {
                    ScoreGauge(score: readiness.value, label: "Readiness",
                               accent: Section2.readiness.accent)
                        .frame(maxWidth: .infinity)
                    Text(readiness.band.rawValue)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Palette.color(readiness.band))
                    if readiness.isProvisional {
                        Text("Still learning your baseline — scores settle after about two weeks.")
                            .font(.caption).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    if let weakest = readiness.contributors.first {
                        Divider().overlay(Palette.hairline)
                        HStack {
                            Text("Lowest contributor").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(weakest.name).font(.caption.weight(.medium))
                            Text("\(weakest.score)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Palette.color(weakest.band))
                        }
                    }
                }
            }
        } else if DayKey.isToday(day), !store.nights.isEmpty {
            // As in Oura: today's scores come from tonight's sleep, so between
            // midnight and the morning sync there's nothing to score yet.
            Card {
                VStack(spacing: 10) {
                    Image(systemName: "moon.stars")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Section2.readiness.accent)
                    Text("Readiness will be ready after you wake")
                        .font(.title3)
                        .multilineTextAlignment(.center)
                    Text("Today's Readiness and Sleep scores come from tonight's sleep. They'll appear once the ring syncs in the morning.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let yesterday = DayKey.date(day)
                        .flatMap({ Calendar.current.date(byAdding: .day, value: -1, to: $0) })
                        .map(DayKey.of),
                       let previous = store.readiness(on: yesterday) {
                        Text("Yesterday's Readiness: \(previous.value) · \(previous.band.rawValue)")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            Card(title: "Get started") {
                Text("Wear the ring overnight, then pull down to sync.").font(.subheadline)
                Text("Readiness needs one night of sleep. Resting heart rate comes from the ring's overnight heart rate log.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var ringCard: some View {
        Card(title: "Ring") {
            HStack {
                Circle().fill(ring.isConnected ? Palette.optimal : .gray)
                    .frame(width: 8, height: 8)
                Text(ring.state.label).font(.subheadline)
                Spacer()
                if let b = ring.battery {
                    if b.isCharging {
                        Image(systemName: "bolt.fill").font(.caption)
                            .foregroundStyle(Palette.optimal)
                    }
                    Text("\(b.level)%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(b.level < 20 ? Palette.low : .secondary)
                }
            }
            if let sync {
                HStack {
                    Text(sync.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync") { Task { await sync.syncAll() } }
                        .font(.caption)
                        .disabled(!ring.isConnected || sync.isSyncing)
                }
            }
        }
    }
}

// MARK: - Shortcuts

/// The metrics that can sit in the Today row. Order and selection persist as
/// a comma-separated list in AppStorage.
enum Shortcut: String, CaseIterable, Identifiable {
    case readiness, sleep, activity, heartRate, stress

    static let minimum = 3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readiness: return "Readiness"
        case .sleep:     return "Sleep"
        case .activity:  return "Activity"
        case .heartRate: return "Heart rate"
        case .stress:    return "Stress"
        }
    }

    var section: Section2 {
        switch self {
        case .readiness: return .readiness
        case .sleep:     return .sleep
        case .activity:  return .activity
        case .heartRate: return .heart
        case .stress:    return .stress
        }
    }

    static func encode(_ shortcuts: [Shortcut]) -> String {
        shortcuts.map(\.rawValue).joined(separator: ",")
    }

    /// Falls back to the full set if what's stored is unreadable or too short.
    static func decode(_ raw: String) -> [Shortcut] {
        var seen = Set<Shortcut>()
        let parsed = raw.split(separator: ",")
            .compactMap { Shortcut(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
        return parsed.count >= minimum ? parsed : allCases
    }
}

/// Pick which shortcuts show and drag to reorder. At least three stay on.
struct ShortcutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: [Shortcut]

    @State private var order: [Shortcut] = []
    @State private var enabled: Set<Shortcut> = []

    private var isValid: Bool { enabled.count >= Shortcut.minimum }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order) { shortcut in
                        Button { toggle(shortcut) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: enabled.contains(shortcut)
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(enabled.contains(shortcut)
                                                     ? shortcut.section.accent : .secondary)
                                Image(systemName: shortcut.section.symbol)
                                    .frame(width: 22)
                                    .foregroundStyle(shortcut.section.accent)
                                Text(shortcut.title).foregroundStyle(.primary)
                            }
                        }
                    }
                    .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("Select at least \(Shortcut.minimum). Drag to reorder.")
                        .foregroundStyle(isValid ? Color.secondary : Palette.fair)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        selection = order.filter(enabled.contains)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
            .onAppear {
                // Selected first in their current order, the rest after.
                order = selection + Shortcut.allCases.filter { !selection.contains($0) }
                enabled = Set(selection)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggle(_ shortcut: Shortcut) {
        if enabled.contains(shortcut) { enabled.remove(shortcut) } else { enabled.insert(shortcut) }
    }
}

// MARK: - Detail scaffold

/// Every detail screen shares the same shape: accent wash, day navigator,
/// then content for the selected day.
struct DetailScaffold<Content: View>: View {
    let title: String
    let section: Section2
    @Binding var day: String
    let days: [String]
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                DayNavigator(selection: $day, days: days, accent: section.accent)
                    .padding(.bottom, 2)
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .background(
            ZStack(alignment: .top) {
                Palette.background
                section.gradient.frame(height: 360)
            }
            .ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Readiness detail

struct ReadinessDetail: View {
    @EnvironmentObject private var store: RingStore
    @Binding var day: String

    /// Oura's wording for each band.
    static func message(_ band: ScoreBand) -> String {
        switch band {
        case .optimal:      return "You're ready for action."
        case .good:         return "You've recovered well enough."
        case .fair, .payAttention: return "You're not fully recovered."
        }
    }

    var body: some View {
        DetailScaffold(title: "Readiness", section: .readiness,
                       day: $day, days: store.availableDays) {
            if let score = store.readiness(on: day) {
                Card {
                    ScoreGauge(score: score.value, label: "Readiness",
                               accent: Section2.readiness.accent)
                        .frame(maxWidth: .infinity)
                    Text(score.band.rawValue)
                        .font(.title3)
                        .foregroundStyle(Palette.color(score.band))
                        .frame(maxWidth: .infinity)
                    Text(ReadinessDetail.message(score.band))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                if let radar = store.symptomRadar(on: day) {
                    NavigationLink { SymptomRadarDetail(day: $day) } label: {
                        Card(title: "Symptom Radar") {
                            HStack {
                                Text(radar.level.rawValue)
                                    .font(.title3)
                                    .foregroundStyle(radar.level == .none ? Color.primary : radar.level.color)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(radar.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Card(title: "Contributors",
                     footnote: store.isRestMode(on: day)
                        ? "Activity contributors are paused while Rest Mode is on."
                        : nil) {
                    ForEach(score.inOrder) { ContributorRow(contributor: $0) }
                }
                Card(title: "How it works") {
                    Text("Readiness weighs Oura's nine contributors. Overnight ones — resting heart rate, body temperature, recovery index and sleep — compare last night with your usual. Balance ones look at the last two weeks, recent days counting more, against your longer-term average: two months, or three for HRV.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Scores near your normal sit in the high 80s and 90s; 100 is meant to be rare. Optimal is 85+, Good 70–84, Fair 60–69, Pay attention below 60.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Card(title: "No score") {
                    Text("No data for this day.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Sleep detail

struct SleepDetail: View {
    @EnvironmentObject private var store: RingStore
    @Binding var day: String

    var body: some View {
        DetailScaffold(title: "Sleep", section: .sleep,
                       day: $day, days: store.availableDays) {
            if let night = store.night(on: day), let score = store.sleepScore(on: day) {
                Card {
                    HStack(alignment: .center, spacing: 18) {
                        ScoreGauge(score: score.value, label: "", accent: Section2.sleep.accent,
                                   size: 96, lineWidth: 7)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(score.band.rawValue)
                                .font(.title3)
                                .foregroundStyle(Palette.color(score.band))
                            Text(Format.duration(night.asleepMinutes))
                                .font(.system(size: 30, weight: .light, design: .rounded))
                            Text("\(Format.time(night.start)) – \(Format.time(night.end))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }

                Card(title: "Sleep stages",
                     footnote: "The movement track marks wake episodes and abrupt stage changes — the ring doesn't expose raw accelerometer data.") {
                    SteppedHypnogram(night: night)
                    Divider().overlay(Palette.hairline)
                    StageLegend(night: night)
                }

                if let clock = store.bodyClock(on: day) {
                    Card(title: "Body clock",
                         footnote: "Your rhythm is the average sleep midpoint of the last two weeks.") {
                        HStack {
                            Text(clock.alignment.rawValue)
                                .font(.title3)
                                .foregroundStyle(clock.alignment == .aligned
                                                 ? Palette.optimal : Palette.fair)
                            Spacer()
                            Text(Circadian.label(clock.lastNightHour))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        BodyClockDial(clock: clock)
                        HStack {
                            Text("Earlier").font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Text("Your rhythm · \(Circadian.label(clock.chronotypeHour))")
                                .font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Text("Later").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(clock.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Card(title: "Contributors") {
                    ForEach(score.contributors) { ContributorRow(contributor: $0) }
                }

                sleepingHeartRate(night)
                temperatureCard
            } else {
                Card(title: "No sleep data") {
                    Text("Nothing recorded for this night.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Oura reads the shape of the night: a heart rate that bottoms out early
    /// suggests recovery got going; a late low often follows a late meal,
    /// drink or workout.
    @ViewBuilder
    private func sleepingHeartRate(_ night: SleepNight) -> some View {
        let sleeping = store.heartRates(during: night)
        if sleeping.count >= 6, let lowest = sleeping.min(by: { $0.bpm < $1.bpm }) {
            // Timed by the lowest 15-minute stretch, as the recovery index is.
            let lowTime = store.metrics(on: day)?.lowestHRTime ?? lowest.time
            let position = lowTime.timeIntervalSince(night.start)
                / max(night.end.timeIntervalSince(night.start), 1)
            Card(title: "Heart rate") {
                HeartRateStats(readings: sleeping, showHighest: false)
                LoggedHeartRateChart(readings: sleeping, color: Palette.rem)
                Text(position < 0.5
                     ? "Lowest at \(Format.time(lowTime)), in the first half of the night — usually a sign your body recovered well."
                     : "Lowest at \(Format.time(lowTime)), late in the night. Late meals, alcohol or evening workouts can push it later.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var temperatureCard: some View {
        let readings = store.temperatures(on: day)
        if readings.count >= 2 {
            Card(title: "Overnight temperature") {
                let unit = TemperatureUnit.current
                Chart(readings) { reading in
                    LineMark(x: .value("Time", reading.time),
                             y: .value(unit.symbol, unit.absolute(reading.celsius)))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Section2.sleep.accent)
                    AreaMark(x: .value("Time", reading.time),
                             y: .value(unit.symbol, unit.absolute(reading.celsius)))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(
                            colors: [Section2.sleep.accent.opacity(0.22), .clear],
                            startPoint: .top, endPoint: .bottom))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 130)
            }
        }
    }
}

// MARK: - Heart detail

struct HeartDetail: View {
    @EnvironmentObject private var store: RingStore
    @Binding var day: String

    var body: some View {
        DetailScaffold(title: "Heart health", section: .heart,
                       day: $day, days: store.availableDays) {
            let logged = store.heartRates(on: day)
            if logged.count >= 2 {
                Card(title: "Heart rate",
                     footnote: "The ring's own log, one reading every 5 minutes. The white dot marks the day's lowest.") {
                    HeartRateStats(readings: logged)
                    LoggedHeartRateChart(readings: logged)
                }
            }
            if let cv = store.cardiovascular(on: day) {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(cv.band == .optimal ? "THRIVING" : "BUILDING")
                            .font(.caption2.weight(.semibold))
                            .tracking(1.2)
                            .foregroundStyle(Section2.heart.accent)
                        Text(cv.headline)
                            .font(.system(size: 26, weight: .regular, design: .serif))
                        if let vo2 = cv.vo2max {
                            Text(String(format: "Estimated VO₂max %.1f mL/kg/min", vo2))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if store.age == nil {
                            Text("Add your birth year in settings to get a cardiovascular age.")
                                .font(.footnote).foregroundStyle(Palette.fair)
                        }
                    }
                }

                if let age = cv.cardiovascularAge, let chrono = cv.chronologicalAge {
                    Card(title: "Cardiovascular age",
                         footnote: "Oura derives this from arterial pulse wave velocity, which needs the raw PPG waveform. This ring only exposes computed values, so the estimate here is built from resting heart rate, HRV and blood oxygen instead — a different route to a similar question.") {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(String(format: "%.0f", age))
                                .font(.system(size: 44, weight: .light, design: .rounded))
                                .monospacedDigit()
                            Text("vs \(chrono) actual")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        ageScale(delta: cv.ageDelta ?? 0)
                    }
                }

                Card(title: "Index contributors") {
                    ForEach(cv.contributors) { ContributorRow(contributor: $0) }
                }

                trendCard("Resting heart rate", \.restingHR, unit: "bpm")
                trendCard("HRV (RMSSD)", \.rmssd, unit: "ms")
            } else {
                Card(title: "Not enough data") {
                    Text("Wear the ring overnight and sync: resting heart rate comes from its heart rate log, HRV from its HRV log.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func ageScale(delta: Double) -> some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Palette.optimal.opacity(0.6), Color.white.opacity(0.1),
                                     Palette.low.opacity(0.6)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(height: 6)
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .offset(x: geo.size.width * CGFloat((delta + 15) / 30) - 6)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 16)
            HStack {
                Text("Younger").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("Older").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func trendCard(_ title: String,
                           _ keyPath: KeyPath<DailyMetrics, Double?>,
                           unit: String) -> some View {
        let series = store.series(keyPath, days: 30)
        if series.count >= 2 {
            Card(title: title) {
                Chart(series, id: \.0) { dayKey, value in
                    LineMark(x: .value("Day", dayKey), y: .value(unit, value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Section2.heart.accent)
                    if let baseline = Baseline(series.map(\.1)) {
                        RuleMark(y: .value("Baseline", baseline.mean))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.white.opacity(0.22))
                    }
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 110)
            }
        }
    }
}

// MARK: - Activity detail

struct ActivityDetail: View {
    @EnvironmentObject private var store: RingStore
    @Binding var day: String

    private var days: [String] {
        Set(store.availableDays)
            .union(store.sessions.filter { $0.resolvedKind == .workout }.map(\.dayKey))
            .sorted()
    }

    var body: some View {
        DetailScaffold(title: "Activity", section: .activity, day: $day, days: days) {
            if store.isRestMode(on: day) {
                RestModeCard()
            }
            if let activity = store.activity(on: activityDay),
               let score = store.activityScore(on: activityDay) {
                Card {
                    HStack(alignment: .center, spacing: 18) {
                        ScoreGauge(score: score.value, label: "", accent: Section2.activity.accent,
                                   size: 96, lineWidth: 7)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(score.band.rawValue)
                                .font(.title3)
                                .foregroundStyle(Palette.color(score.band))
                            Text(activity.steps.formatted(.number.precision(.fractionLength(0))))
                                .font(.system(size: 30, weight: .light, design: .rounded))
                                .monospacedDigit()
                            Text(activity.activeCalories > 0
                                 ? String(format: "steps · %.0f active kcal", activity.activeCalories)
                                 : "steps")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(Measurement(value: activity.metres, unit: UnitLength.meters)
                                    .formatted(.measurement(width: .abbreviated, usage: .road)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }

                if store.weight == nil {
                    Card {
                        Text("Add your weight in Settings to see active calories.")
                            .font(.subheadline).foregroundStyle(Palette.fair)
                    }
                }

                Card(title: "Contributors") {
                    ForEach(score.contributors) { ContributorRow(contributor: $0) }
                }

                throughTheDay
                stepsCard
            } else {
                Card(title: "No activity",
                     footnote: "Steps come from your ring. Pull down on Today to sync the last week.") {
                    Text("Nothing recorded for this day.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            workoutsCard
        }
    }

    @ViewBuilder
    private var workoutsCard: some View {
        let workouts = store.sessions(on: day, [.workout])
        if !workouts.isEmpty {
            Card(title: "Workouts") {
                ForEach(workouts) { workout in
                    NavigationLink { SessionDetail(session: workout) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: workout.symbol)
                                .foregroundStyle(Section2.activity.accent)
                                .frame(width: 34, height: 34)
                                .background(Section2.activity.accent.opacity(0.14), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workout.title).font(.subheadline)
                                Text("\(Format.time(workout.started)) · \(Format.clock(workout.duration))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let avg = workout.meanHR {
                                Text(String(format: "%.0f bpm avg", avg))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var activityDay: String { store.activityDayKey(showing: day) }

    /// The ring's 15-minute buckets, summed by hour across the activity day —
    /// 4 AM to 4 AM, so the small hours sit at the end, not the start.
    @ViewBuilder
    private var throughTheDay: some View {
        let hours = Dictionary(grouping: store.stepBuckets(on: activityDay)) {
            (Calendar.current.component(.hour, from: $0.time) + 20) % 24 + 4
        }
        .map { hour, buckets in (hour, buckets.reduce(0) { $0 + $1.steps }) }
        .sorted { $0.0 < $1.0 }
        if !hours.isEmpty {
            Card(title: "Through the day",
                 footnote: "Active calories use the ring's distance: 0.0005 × metres × your weight for walking, twice that for running — the MET walking equation with duration cancelled out.") {
                Chart(hours, id: \.0) { hour, steps in
                    BarMark(x: .value("Hour", hour), y: .value("Steps", steps))
                        .foregroundStyle(Section2.activity.accent)
                        .cornerRadius(2)
                }
                .chartXScale(domain: 4...28)
                .chartXAxis {
                    AxisMarks(values: [4, 10, 16, 22, 28]) { value in
                        AxisValueLabel {
                            if let hour = value.as(Int.self) {
                                Text(Calendar.current.date(bySettingHour: hour % 24, minute: 0, second: 0, of: Date())!
                                        .formatted(.dateTime.hour()))
                            }
                        }
                        .font(.system(size: 9))
                    }
                }
                .frame(height: 120)
            }
        }
    }

    @ViewBuilder
    private var stepsCard: some View {
        let recent = store.activityDays.prefix(14).reversed().map { ($0.dayKey, $0.steps) }
        if recent.count >= 2 {
            Card(title: "Steps, last two weeks",
                 footnote: "Dashed line marks \(Int(ActivityScore.stepGoal).formatted()) steps.") {
                Chart(recent, id: \.0) { dayKey, steps in
                    BarMark(x: .value("Day", dayKey), y: .value("Steps", steps))
                        .foregroundStyle(Section2.activity.accent
                            .opacity(dayKey == day ? 1 : 0.45))
                        .cornerRadius(3)
                    RuleMark(y: .value("Goal", ActivityScore.stepGoal))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.white.opacity(0.22))
                }
                .chartXAxis(.hidden)
                .frame(height: 130)
            }
        }
    }
}

// MARK: - Sheets

struct TagSheet: View {
    @EnvironmentObject private var store: RingStore
    @Environment(\.dismiss) private var dismiss
    let day: String

    var body: some View {
        NavigationStack {
            List {
                ForEach(DayTag.presets, id: \.0) { label, symbol in
                    Button {
                        store.add(tag: DayTag(label: label, symbol: symbol,
                                              time: DayKey.isToday(day) ? Date()
                                                  : DayKey.date(day) ?? Date()))
                        dismiss()
                    } label: { Label(label, systemImage: symbol) }
                }
            }
            .navigationTitle("Add tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct SettingsSheet: View {
    @EnvironmentObject private var store: RingStore
    @EnvironmentObject private var health: HealthService
    @EnvironmentObject private var ring: RingConnection
    @Environment(\.dismiss) private var dismiss
    var capture: RingCapture?

    private let years = Array((1930...Calendar.current.component(.year, from: Date()) - 10).reversed())

    private var usesPounds: Bool { Locale.current.measurementSystem == .us }
    private var weightRange: [Int] { usesPounds ? Array(80...400) : Array(35...180) }

    /// Shown in the locale's unit, stored in kg.
    private var weightBinding: Binding<Int> {
        Binding(
            get: { store.weight.map { Int((usesPounds ? $0 * 2.20462 : $0).rounded()) } ?? 0 },
            set: { store.weightKg = $0 == 0 ? 0 : (usesPounds ? Double($0) / 2.20462 : Double($0)) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Birth year", selection: $store.birthYear) {
                        Text("Not set").tag(0)
                        ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                    }
                    Picker("Temperature", selection: $store.temperatureUnit) {
                        ForEach(TemperatureUnit.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Weight", selection: weightBinding) {
                        Text("Not set").tag(0)
                        ForEach(weightRange, id: \.self) { Text("\($0) \(usesPounds ? "lb" : "kg")").tag($0) }
                    }
                } header: {
                    Text("You")
                } footer: {
                    Text("Birth year feeds the VO₂max estimate (208 − 0.7 × age for max heart rate) and cardiovascular age. Weight turns steps into active calories.")
                }

                Section {
                    ForEach(MonitoringKind.allCases) { kind in
                        MonitoringControl(kind: kind)
                    }
                    Button("Re-read from ring") { ring.readAllMonitoring() }
                        .font(.footnote)
                        .disabled(!ring.isConnected)
                } header: {
                    Text("Ring monitoring")
                } footer: {
                    Text("These live on the ring itself, so it keeps logging whether or not this app is open, and the app pulls the logs whenever it syncs. Blood oxygen, stress and HRV are on/off only — the ring picks its own cadence (about hourly for blood oxygen and HRV, every 30 minutes for stress). Heart rate's logging interval is yours to set. Each change is read back, so the switch shows what the ring actually reports.")
                }

                NotificationsSection(notifier: AppServices.shared.notifier)

                BackgroundMonitoringSection(monitor: AppServices.shared.monitor)

                if let capture { OvernightCaptureSection(capture: capture) }

                Section("Health") {
                    LabeledContent("Apple Health",
                                   value: health.isAuthorized ? "Connected" : "Not granted")
                    if let error = health.lastError {
                        Text(error).font(.caption).foregroundStyle(Palette.low)
                    }
                }

                Section("Data") {
                    LabeledContent("Nights", value: "\(store.nights.count)")
                    LabeledContent("Capture sessions", value: "\(store.sessions.count)")
                    LabeledContent("Logged samples", value: "\(store.samples.count)")
                    LabeledContent("Temperature points", value: "\(store.temperatures.count)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { ring.readAllMonitoring() }
        }
    }
}

/// One toggle plus interval picker, driven by what the ring reports.
struct MonitoringControl: View {
    @EnvironmentObject private var ring: RingConnection
    let kind: MonitoringKind

    private var setting: MonitoringSetting? { ring.monitoring[kind.label] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { setting?.isEnabled ?? false },
                set: { enabled in
                    ring.setMonitoring(kind, enabled: enabled,
                                       intervalMinutes: setting?.intervalMinutes
                                        ?? kind.intervals.first ?? 5)
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.label)
                        if let setting {
                            Text(setting.isEnabled
                                 ? "Every \(setting.intervalMinutes) min"
                                 : "Off")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(ring.isConnected ? "No response — command may differ"
                                                  : "Connect to read")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .disabled(!ring.isConnected)

            if kind.intervals.count > 1, let setting, setting.isEnabled {
                Picker("Interval", selection: Binding(
                    get: { setting.intervalMinutes },
                    set: { ring.setMonitoring(kind, enabled: true, intervalMinutes: $0) })) {
                        ForEach(kind.intervals, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .pickerStyle(.segmented)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Debug

struct DebugTab: View {
    @EnvironmentObject private var ring: RingConnection
    let capture: RingCapture?

    @State private var uartHex = "03"
    @State private var bigDataHex = "25"

    var body: some View {
        NavigationStack {
            List {
                Section("UART") {
                    HStack {
                        TextField("hex e.g. 69 05 01", text: $uartHex)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Send") { sendUART() }.disabled(!ring.isConnected)
                    }
                    Button("Battery") { ring.requestBattery() }
                    Button("Heart rate log (today)") { ring.requestHeartRateLog() }
                    Button("Set time") { ring.syncTime() }
                }
                Section("Real-time subtypes") {
                    ForEach(RealtimeSubtype.allCases) { subtype in
                        Button(subtype.label) { capture?.captureOnce(subtype, seconds: 60) }
                    }
                }
                Section("Big data") {
                    HStack {
                        TextField("type hex e.g. 25", text: $bigDataHex)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Request") { sendBigData() }.disabled(!ring.isConnected)
                    }
                    ForEach(BigDataType.allCases) { type in
                        Button(type.label) { ring.requestBigData(type) }
                    }
                }
                Section {
                    ForEach(ring.log.suffix(80).reversed()) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: line.isOutgoing ? "arrow.up.right" : "arrow.down.left")
                                .font(.system(size: 9))
                                .foregroundStyle(line.isOutgoing ? Section2.readiness.accent : .secondary)
                            Text(line.text).font(.system(size: 10, design: .monospaced))
                        }
                    }
                } header: {
                    HStack {
                        Text("Packet log")
                        Spacer()
                        Button("Clear") { ring.clearLog() }.font(.caption)
                    }
                }
            }
            .navigationTitle("Debug")
        }
    }

    private func bytes(_ text: String) -> [UInt8] {
        text.split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { UInt8($0, radix: 16) }
    }

    private func sendUART() {
        let parsed = bytes(uartHex)
        guard let command = parsed.first else { return }
        ring.send(UARTPacket.make(command, payload: Array(parsed.dropFirst())))
    }

    private func sendBigData() {
        let parsed = bytes(bigDataHex)
        guard let type = parsed.first else { return }
        ring.requestBigData(type, payload: Array(parsed.dropFirst()))
    }
}
