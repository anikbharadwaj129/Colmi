import SwiftUI
import Charts
import AudioToolbox

// MARK: - Presentation
//
// On-demand measurements, laid out the way Oura places them: Live heart rate
// on Today's heart rate card, unguided sessions and workout heart rate behind
// the + button, and everything recorded landing in Today's timeline.

extension CaptureSession.Kind {
    var title: String {
        switch self {
        case .capture:   return "Capture"
        case .spotCheck: return "Live heart rate"
        case .session:   return "Unguided session"
        case .workout:   return "Workout"
        }
    }

    var symbol: String {
        switch self {
        case .capture:   return "waveform.path.ecg"
        case .spotCheck: return "heart.fill"
        case .session:   return "figure.mind.and.body"
        case .workout:   return "figure.run"
        }
    }

    var accent: Color {
        switch self {
        case .capture:   return .white
        case .spotCheck: return Section2.heart.accent
        case .session:   return Section2.stress.accent       // restorative purple
        case .workout:   return Section2.activity.accent
        }
    }
}

extension CaptureSession {
    var title: String { activity ?? resolvedKind.title }
    var symbol: String {
        activity.map(WorkoutActivity.symbol(for:)) ?? resolvedKind.symbol
    }
}

enum WorkoutActivity: String, CaseIterable, Identifiable {
    case walking  = "Walking"
    case running  = "Running"
    case cycling  = "Cycling"
    case strength = "Strength training"
    case hiit     = "HIIT"
    case yoga     = "Yoga"
    case dancing  = "Dancing"
    case other    = "Other"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .walking:  return "figure.walk"
        case .running:  return "figure.run"
        case .cycling:  return "figure.outdoor.cycle"
        case .strength: return "figure.strengthtraining.traditional"
        case .hiit:     return "figure.highintensity.intervaltraining"
        case .yoga:     return "figure.yoga"
        case .dancing:  return "figure.dance"
        case .other:    return "figure.mixed.cardio"
        }
    }

    static func symbol(for name: String) -> String {
        WorkoutActivity(rawValue: name)?.symbol ?? WorkoutActivity.other.symbol
    }
}

extension HeartZones {
    static func color(_ zone: Int) -> Color {
        switch zone {
        case 1:  return Palette.light
        case 2:  return Palette.optimal
        case 3:  return Palette.fair
        case 4:  return Color(red: 0.98, green: 0.56, blue: 0.32)
        case 5:  return Palette.low
        default: return .white.opacity(0.4)
        }
    }
}

extension Format {
    /// 4:05, or 1:04:05 past the hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Heart rate card

/// Today's 24-hour heart rate graph with the Live heart rate button. The base
/// layer is the ring's own 5-minute log; sessions, workouts and spot checks sit
/// on top. Each dot is a five-minute reading, coloured by what you were doing.
struct HeartRateCard: View {
    @EnvironmentObject private var ring: RingConnection
    @EnvironmentObject private var store: RingStore
    @ObservedObject var capture: RingCapture
    @Binding var day: String

    @State private var failure: String?

    private struct Reading: Identifiable {
        let id: Int
        let time: Date
        let bpm: Double
        let style: Style
    }

    private struct Style: Hashable {
        let label: String
        let color: Color
        var isLive = false
    }

    private var isMeasuring: Bool { capture.activeKind == .spotCheck }

    private func readingStyle(_ session: CaptureSession) -> Style {
        switch session.resolvedKind {
        case .spotCheck: return Style(label: "Live", color: Section2.heart.accent, isLive: true)
        case .session:   return Style(label: "Restorative", color: Section2.stress.accent)
        case .workout:   return Style(label: "Workout", color: Section2.activity.accent)
        case .capture:
            let asleep = store.nights.contains { session.started >= $0.start && session.started <= $0.end }
            return asleep ? Style(label: "Sleep", color: Palette.rem)
                          : Style(label: "Capture", color: .white.opacity(0.7))
        }
    }

    private var readings: [Reading] {
        var out: [Reading] = []
        let sleep = Style(label: "Sleep", color: Palette.rem)
        let daytime = Style(label: "Daytime", color: .white.opacity(0.7))
        for reading in store.heartRates(on: day) {
            out.append(Reading(id: out.count, time: reading.time, bpm: Double(reading.bpm),
                               style: store.isAsleep(at: reading.time) ? sleep : daytime))
        }
        for session in store.sessions(on: day).reversed() {
            let style = readingStyle(session)
            if session.resolvedKind == .spotCheck {
                if let bpm = session.settledHR {
                    out.append(Reading(id: out.count, time: session.ended, bpm: Double(bpm), style: style))
                }
                continue
            }
            let buckets = Dictionary(grouping: session.heartRateTrack) {
                Int($0.0.timeIntervalSince1970 / 300)
            }
            for (bucket, values) in buckets.sorted(by: { $0.key < $1.key }) {
                out.append(Reading(id: out.count,
                                   time: Date(timeIntervalSince1970: Double(bucket) * 300 + 150),
                                   bpm: HRV.mean(values.map(\.1)),
                                   style: style))
            }
        }
        return out
    }


    var body: some View {
        let readings = readings
        Card {
            NavigationLink { HeartDetail(day: $day) } label: {
                HStack {
                    Text("HEART RATE")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if readings.isEmpty {
                Text(DayKey.isToday(day)
                     ? "No readings yet. Pull down to sync the ring's log, or tap the heart for one now."
                     : "No heart rate recorded this day.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else {
                chart(readings)
                legend(readings)
                let logged = store.heartRates(on: day).map(\.bpm)
                if let low = logged.min() {
                    Text("Lowest \(low) bpm · Average \(Int(HRV.mean(logged.map(Double.init)).rounded())) bpm")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            Divider().overlay(Palette.hairline)
            liveRow
        }
    }

    private func chart(_ readings: [Reading]) -> some View {
        let start = DayKey.date(day) ?? Calendar.current.startOfDay(for: Date())
        let end = start.addingTimeInterval(86_400)
        let average = HRV.mean(readings.map(\.bpm))
        return Chart {
            ForEach(readings) { reading in
                PointMark(x: .value("Time", reading.time), y: .value("bpm", reading.bpm))
                    .foregroundStyle(reading.style.color)
                    .symbolSize(reading.style.isLive ? 70 : 16)
            }
            RuleMark(y: .value("Average", average))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(.white.opacity(0.25))
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9))
            }
        }
        .frame(height: 140)
    }

    private func legend(_ readings: [Reading]) -> some View {
        var seen = Set<String>()
        let styles = readings.map(\.style).filter { seen.insert($0.label).inserted }
        return HStack(spacing: 14) {
            ForEach(styles, id: \.label) { style in
                HStack(spacing: 5) {
                    Circle().fill(style.color).frame(width: 6, height: 6)
                    Text(style.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var liveRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                if isMeasuring {
                    Text(capture.liveHeartRate.map { "\($0) bpm" } ?? "—")
                        .font(.system(size: 28, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("Measuring heart rate, hold still")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let failure {
                    Text("No reading").font(.subheadline)
                    Text(failure).font(.caption).foregroundStyle(Palette.fair)
                } else if let latest = store.latestHeartRate(on: day) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(latest.bpm)")
                            .font(.system(size: 28, weight: .light, design: .rounded))
                            .monospacedDigit()
                        Text("bpm").font(.subheadline).foregroundStyle(.secondary)
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text("Latest · " + latest.time.formatted(.relative(presentation: .named)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Live heart rate").font(.subheadline)
                    Text("Takes about ten seconds").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if DayKey.isToday(day) { heartButton }
        }
    }

    private var heartButton: some View {
        Button { measure() } label: {
            ZStack {
                Circle().fill(Section2.heart.accent.opacity(isMeasuring ? 0.18 : 1))
                if isMeasuring {
                    Circle()
                        .trim(from: 0, to: min(1, capture.elapsed / RingCapture.spotCheckSeconds))
                        .stroke(Section2.heart.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: capture.elapsed)
                }
                Image(systemName: "heart.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: isMeasuring)
            }
            .frame(width: 54, height: 54)
        }
        .buttonStyle(.plain)
        .disabled(!ring.isConnected || capture.isCapturing)
        .opacity(ring.isConnected ? 1 : 0.35)
        .accessibilityLabel("Measure heart rate")
    }

    private func measure() {
        failure = nil
        Task {
            if await capture.measureHeartRate() != nil {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                failure = capture.status
            }
        }
    }
}

// MARK: - Logged heart rate chart

/// The ring's 5-minute log as a line, broken wherever readings are missing,
/// with the lowest point marked.
struct LoggedHeartRateChart: View {
    let readings: [HeartRateReading]
    var color: Color = Section2.heart.accent

    /// A new segment wherever two readings are more than 15 minutes apart.
    private var segments: [(reading: HeartRateReading, segment: Int)] {
        var segment = 0
        var previous: Date?
        return readings.map { reading in
            if let previous, reading.time.timeIntervalSince(previous) > 900 { segment += 1 }
            previous = reading.time
            return (reading, segment)
        }
    }

    var body: some View {
        let lowest = readings.min { $0.bpm < $1.bpm }
        Chart {
            ForEach(segments, id: \.reading.id) { item in
                LineMark(x: .value("Time", item.reading.time), y: .value("bpm", item.reading.bpm),
                         series: .value("Segment", item.segment))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color)
            }
            if let lowest {
                PointMark(x: .value("Time", lowest.time), y: .value("bpm", lowest.bpm))
                    .foregroundStyle(.white)
                    .symbolSize(40)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9))
            }
        }
        .frame(height: 140)
    }
}

/// Lowest / average / highest across a set of readings.
struct HeartRateStats: View {
    let readings: [HeartRateReading]
    var showHighest = true

    var body: some View {
        let bpm = readings.map(\.bpm)
        HStack {
            stat("Lowest", bpm.min())
            stat("Average", bpm.isEmpty ? nil : Int(HRV.mean(bpm.map(Double.init)).rounded()))
            if showHighest { stat("Highest", bpm.max()) }
        }
    }

    private func stat(_ title: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.map(String.init) ?? "—")
                    .font(.system(size: 24, weight: .light, design: .rounded))
                    .monospacedDigit()
                Text("bpm").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Timeline

/// Today's recent events, newest first: sleep, sessions, workouts and tags.
struct TimelineCard: View {
    @EnvironmentObject private var store: RingStore
    @Binding var day: String

    private enum Event: Identifiable {
        case night(SleepNight)
        case session(CaptureSession)
        case tag(DayTag)

        var id: String {
            switch self {
            case .night(let n):   return "night-\(n.id)"
            case .session(let s): return "session-\(s.id)"
            case .tag(let t):     return "tag-\(t.id)"
            }
        }

        var time: Date {
            switch self {
            case .night(let n):   return n.end
            case .session(let s): return s.started
            case .tag(let t):     return t.time
            }
        }
    }

    private var events: [Event] {
        var out: [Event] = store.sessions(on: day, [.session, .workout]).map(Event.session)
        out += store.tags(on: day).map(Event.tag)
        if let night = store.night(on: day) { out.append(.night(night)) }
        return out.sorted { $0.time > $1.time }
    }

    var body: some View {
        Card(title: "Timeline") {
            let events = events
            if events.isEmpty {
                Text("Nothing yet. Tap + to add a tag, start a session or record a workout.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { Divider().overlay(Palette.hairline).padding(.leading, 46) }
                        row(event)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ event: Event) -> some View {
        switch event {
        case .night(let night):
            NavigationLink { SleepDetail(day: $day) } label: {
                TimelineRow(symbol: Section2.sleep.symbol, accent: Section2.sleep.accent,
                            title: "Slept \(Format.duration(night.asleepMinutes))",
                            subtitle: "\(Format.time(night.start)) – \(Format.time(night.end))",
                            time: night.end, chevron: true)
            }
            .buttonStyle(.plain)
        case .session(let session):
            NavigationLink { SessionDetail(session: session) } label: {
                TimelineRow(symbol: session.symbol, accent: session.resolvedKind.accent,
                            title: session.title,
                            subtitle: summary(session),
                            time: session.started, chevron: true)
            }
            .buttonStyle(.plain)
        case .tag(let tag):
            TimelineRow(symbol: tag.symbol, accent: .white.opacity(0.8),
                        title: tag.label, subtitle: "Tag", time: tag.time, chevron: false)
                .contextMenu {
                    Button("Delete tag", systemImage: "trash", role: .destructive) {
                        store.remove(tag: tag)
                    }
                }
        }
    }

    private func summary(_ session: CaptureSession) -> String {
        let length = Format.duration(Int((session.duration / 60).rounded()))
        switch session.resolvedKind {
        case .workout:
            return session.meanHR.map { String(format: "%@ · avg %.0f bpm", length, $0) } ?? length
        default:
            return session.lowestHR.map { String(format: "%@ · lowest %.0f bpm", length, $0) } ?? length
        }
    }
}

private struct TimelineRow: View {
    let symbol: String
    let accent: Color
    let title: String
    let subtitle: String
    let time: Date
    let chevron: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(accent.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.time(time)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Unguided session

/// Pick a length, stay still, answer "How do you feel?", see results.
struct UnguidedSessionFlow: View {
    @EnvironmentObject private var ring: RingConnection
    @ObservedObject var capture: RingCapture
    @Environment(\.dismiss) private var dismiss

    private enum Stage { case setup, running, feeling, results }

    @State private var stage = Stage.setup
    @State private var session: CaptureSession?
    @State private var breathe = false
    @AppStorage("sessionMinutes") private var minutes = 5
    @AppStorage("sessionChime") private var chime = true

    private static let durations = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180]
    private let accent = Section2.stress.accent

    private var total: TimeInterval { TimeInterval(minutes * 60) }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            RadialGradient(colors: [accent.opacity(0.32), .clear],
                           center: .top, startRadius: 0, endRadius: 520)
                .ignoresSafeArea()
            switch stage {
            case .setup:   setup
            case .running: running
            case .feeling: feeling
            case .results: results
            }
        }
        .animation(.easeInOut(duration: 0.3), value: stage)
        .interactiveDismissDisabled(stage == .running)
    }

    // Setup

    private var setup: some View {
        VStack(spacing: 18) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                }
                Spacer()
            }
            Spacer(minLength: 0)
            Image(systemName: "figure.mind.and.body")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(accent)
            Text("Unguided session")
                .font(.system(size: 34, weight: .regular, design: .serif))
            Text("Sit or lie down somewhere comfortable and keep your hand still. Your ring measures how your body settles.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)

            Picker("Duration", selection: $minutes) {
                ForEach(Self.durations, id: \.self) { Text("\($0) min").tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(height: 140)

            Text(unlocks)
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 36)

            Toggle("End chime", isOn: $chime)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))

            Button { start() } label: {
                Text("Start").font(.headline)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.black)
            }
            .disabled(!ring.isConnected || capture.isCapturing)
            .opacity(ring.isConnected && !capture.isCapturing ? 1 : 0.4)

            if !ring.isConnected {
                Text("Connect your ring to start a session.")
                    .font(.caption).foregroundStyle(Palette.fair)
            } else if capture.isCapturing {
                Text("Another recording is running.")
                    .font(.caption).foregroundStyle(Palette.fair)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var unlocks: String {
        switch minutes {
        case ..<3: return "Results: lowest resting heart rate."
        case ..<5: return "Results: lowest resting heart rate and average HRV."
        default:   return "Results: lowest resting heart rate, average HRV, and how both moved through the session."
        }
    }

    private func start() {
        stage = .running
        breathe = false
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            let result = await capture.record(.session, duration: total)
            UIApplication.shared.isIdleTimerDisabled = false
            if let result, result.duration >= total - 1 {
                if chime { AudioServicesPlaySystemSound(1013) }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            session = result
            stage = result == nil ? .results : .feeling
        }
    }

    // Running

    private var running: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle()
                    .fill(accent.opacity(0.14))
                    .scaleEffect(breathe ? 0.94 : 0.72)
                    .animation(.easeInOut(duration: 5).repeatForever(autoreverses: true), value: breathe)
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: min(1, capture.elapsed / total))
                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: capture.elapsed)
                VStack(spacing: 6) {
                    Text(Format.clock(total - capture.elapsed))
                        .font(.system(size: 56, weight: .thin, design: .rounded))
                        .monospacedDigit()
                    HStack(spacing: 5) {
                        Image(systemName: "heart.fill").font(.caption)
                            .foregroundStyle(Section2.heart.accent)
                        Text(capture.liveHeartRate.map { "\($0) bpm" } ?? "Finding pulse…")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
            }
            .frame(width: 270, height: 270)
            .onAppear { breathe = true }

            Text(ring.isConnected ? "Stay still and breathe naturally." : "Ring disconnected")
                .font(.subheadline)
                .foregroundStyle(ring.isConnected ? Color.secondary : Palette.fair)
            Spacer()
            Button { capture.finish() } label: {
                Text("End early").font(.subheadline.weight(.medium))
                    .padding(.horizontal, 28).frame(height: 46)
                    .background(Color.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
    }

    // How do you feel?

    private var feeling: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("How do you feel?")
                .font(.system(size: 32, weight: .regular, design: .serif))
            Text("Compared with before the session.")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.bottom, 14)
            ForEach(CaptureSession.Feeling.allCases.reversed(), id: \.self) { feeling in
                Button { answer(feeling) } label: {
                    Text(feeling.label).font(.body.weight(.medium))
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(Palette.card, in: Capsule())
                        .overlay(Capsule().stroke(Palette.hairline))
                }
                .buttonStyle(.plain)
            }
            Button("Skip") { stage = .results }
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.top, 6)
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func answer(_ feeling: CaptureSession.Feeling) {
        if var session {
            session.feeling = feeling
            capture.update(session)
            self.session = session
        }
        stage = .results
    }

    // Results

    private var results: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 4) {
                        Text(session == nil ? "No reading" : "Session complete")
                            .font(.system(size: 30, weight: .regular, design: .serif))
                        if let session {
                            Text("\(Format.clock(session.duration)) · \(Format.time(session.started))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 36).padding(.bottom, 8)

                    if let session {
                        SessionResults(session: session)
                    } else {
                        Card {
                            Text(capture.status).font(.subheadline)
                            Text("Make sure the ring sits snugly with the sensors on the palm side, and keep your hand still.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            Button { dismiss() } label: {
                Text("Done").font(.headline)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.black)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
}

/// What a still session shows. Oura's thresholds: a minute or more for lowest
/// resting heart rate, three for HRV, five for trends.
struct SessionResults: View {
    @EnvironmentObject private var store: RingStore
    let session: CaptureSession

    var body: some View {
        VStack(spacing: 14) {
            if session.duration < 60 {
                Card(title: "Too short") {
                    Text("Sessions need at least a minute to show results.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                if let low = session.lowestHR {
                    metric("Lowest resting heart rate", value: low, unit: "bpm",
                           comparison: comparison(low, baseline: store.baseline(\.restingHR, before: session.dayKey),
                                                  unit: "bpm", lowerIsBetter: true))
                }
                if session.duration >= 180, let rmssd = session.rmssd {
                    metric("Average HRV", value: rmssd, unit: "ms",
                           comparison: comparison(rmssd, baseline: store.baseline(\.rmssd, before: session.dayKey),
                                                  unit: "ms", lowerIsBetter: false))
                }
                if session.duration >= 300 { trends }
            }
            if let feeling = session.feeling {
                Card(title: "How you felt") {
                    Text(feeling.label).font(.title3)
                }
            }
        }
    }

    private func metric(_ title: String, value: Double, unit: String,
                        comparison: (String, Color)?) -> some View {
        Card(title: title) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.0f", value))
                    .font(.system(size: 44, weight: .light, design: .rounded))
                    .monospacedDigit()
                Text(unit).font(.subheadline).foregroundStyle(.secondary)
            }
            if let comparison {
                Text(comparison.0).font(.footnote).foregroundStyle(comparison.1)
            }
        }
    }

    /// Against the nighttime baseline, coloured by whether the move is a good one.
    private func comparison(_ value: Double, baseline: Baseline?, unit: String,
                            lowerIsBetter: Bool) -> (String, Color)? {
        guard let baseline else { return nil }
        let delta = value - baseline.mean
        let average = String(format: "%.0f", baseline.mean)
        guard abs(delta) >= 1 else { return ("In line with your nighttime average of \(average) \(unit)", .secondary) }
        let better = lowerIsBetter ? delta < 0 : delta > 0
        let text = String(format: "%.0f %@ %@ your nighttime average of %@",
                          abs(delta), unit, delta < 0 ? "below" : "above", average)
        return (text, better ? Palette.optimal : .secondary)
    }

    private var trends: some View {
        Card(title: "Through the session",
             footnote: "Oura also plots skin temperature here. This ring doesn't stream temperature live, so it's left out.") {
            let hr = session.heartRateTrack
            if hr.count >= 2 {
                Text("Heart rate").font(.caption).foregroundStyle(.secondary)
                Chart(Array(hr.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("Time", point.0), y: .value("bpm", point.1))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Section2.heart.accent)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis(.hidden)
                .frame(height: 90)
            }
            let hrv = session.hrvTrack
            if hrv.count >= 2 {
                Text("HRV").font(.caption).foregroundStyle(.secondary)
                Chart(Array(hrv.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("Time", point.0), y: .value("ms", point.1))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Section2.stress.accent)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis(.hidden)
                .frame(height: 90)
            }
        }
    }
}

// MARK: - Workout heart rate

/// Choose an activity, record, end, see heart rate and zones.
struct WorkoutFlow: View {
    @EnvironmentObject private var ring: RingConnection
    @EnvironmentObject private var store: RingStore
    @ObservedObject var capture: RingCapture
    @Environment(\.dismiss) private var dismiss

    private enum Stage { case setup, running, summary }

    @State private var stage = Stage.setup
    @State private var activity = WorkoutActivity.running
    @State private var session: CaptureSession?
    @State private var confirmEnd = false

    private let accent = Section2.activity.accent
    private var zones: HeartZones? { HeartZones(age: store.age) }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            RadialGradient(colors: [accent.opacity(0.26), .clear],
                           center: .top, startRadius: 0, endRadius: 520)
                .ignoresSafeArea()
            switch stage {
            case .setup:   setup
            case .running: running
            case .summary: summary
            }
        }
        .animation(.easeInOut(duration: 0.3), value: stage)
        .interactiveDismissDisabled(stage == .running)
    }

    private var setup: some View {
        VStack(spacing: 18) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                }
                Spacer()
            }
            Text("Record workout heart rate")
                .font(.system(size: 28, weight: .regular, design: .serif))
                .multilineTextAlignment(.center)
            Text("Your ring streams heart rate for the whole workout. Keep the phone nearby.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(WorkoutActivity.allCases) { option in
                    Button { activity = option } label: {
                        HStack(spacing: 10) {
                            Image(systemName: option.symbol).frame(width: 22)
                            Text(option.rawValue).font(.subheadline).lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14).frame(height: 50)
                        .background(activity == option ? accent.opacity(0.22) : Palette.card,
                                    in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(activity == option ? accent : Palette.hairline, lineWidth: 1))
                        .foregroundStyle(activity == option ? accent : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if zones == nil {
                Text("Add your birth year in Settings to see heart rate zones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)

            Button { start() } label: {
                Text("Start").font(.headline)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.black)
            }
            .disabled(!ring.isConnected || capture.isCapturing)
            .opacity(ring.isConnected && !capture.isCapturing ? 1 : 0.4)

            if !ring.isConnected {
                Text("Connect your ring to record a workout.")
                    .font(.caption).foregroundStyle(Palette.fair)
            } else if capture.isCapturing {
                Text("Another recording is running.")
                    .font(.caption).foregroundStyle(Palette.fair)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func start() {
        stage = .running
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            let result = await capture.record(.workout, activity: activity.rawValue)
            UIApplication.shared.isIdleTimerDisabled = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            session = result
            stage = .summary
        }
    }

    private var running: some View {
        VStack(spacing: 22) {
            HStack {
                Label(activity.rawValue, systemImage: activity.symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(accent)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(Palette.low).frame(width: 7, height: 7)
                    Text(ring.isConnected ? "Recording" : "Ring disconnected")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 12)

            Text(Format.clock(capture.elapsed))
                .font(.system(size: 52, weight: .thin, design: .rounded))
                .monospacedDigit()

            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "heart.fill").font(.title3)
                        .foregroundStyle(Section2.heart.accent)
                    Text(capture.liveHeartRate.map(String.init) ?? "—")
                        .font(.system(size: 76, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("bpm").font(.title3).foregroundStyle(.secondary)
                }
                if let zones, let bpm = capture.liveHeartRate {
                    let zone = zones.zone(Double(bpm))
                    Text(zone == 0 ? "Below zone 1" : "Zone \(zone) · \(HeartZones.names[zone - 1])")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(HeartZones.color(zone))
                }
            }

            if let zones, let bpm = capture.liveHeartRate {
                ZoneBar(zone: zones.zone(Double(bpm)))
            }

            if capture.liveHeartRates.count >= 2 {
                Chart(Array(capture.liveHeartRates.suffix(240).enumerated()), id: \.offset) { i, bpm in
                    LineMark(x: .value("Reading", i), y: .value("bpm", bpm))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(accent)
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 110)
            }

            Spacer()
            Button { confirmEnd = true } label: {
                Text("End workout").font(.headline)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
            .confirmationDialog("End this workout?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End workout") { capture.finish() }
                Button("Keep going", role: .cancel) {}
            }
        }
        .padding(.horizontal, 20)
    }

    private var summary: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 4) {
                        Image(systemName: activity.symbol)
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(accent)
                        Text(session == nil ? "No reading" : activity.rawValue)
                            .font(.system(size: 30, weight: .regular, design: .serif))
                    }
                    .padding(.top, 36).padding(.bottom, 8)

                    if let session {
                        WorkoutSummary(session: session)
                    } else {
                        Card {
                            Text(capture.status).font(.subheadline)
                            Text("Make sure the ring sits snugly with the sensors on the palm side.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            Button { dismiss() } label: {
                Text("Done").font(.headline)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.black)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
}

/// Five segments with the current zone lit.
private struct ZoneBar: View {
    let zone: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { z in
                Capsule()
                    .fill(HeartZones.color(z).opacity(z == zone ? 1 : 0.2))
                    .frame(height: z == zone ? 10 : 6)
            }
        }
        .animation(.snappy, value: zone)
    }
}

struct WorkoutSummary: View {
    @EnvironmentObject private var store: RingStore
    let session: CaptureSession

    var body: some View {
        VStack(spacing: 14) {
            Card {
                HStack {
                    stat("Duration", Format.clock(session.duration))
                    stat("Average", session.meanHR.map { String(format: "%.0f", $0) } ?? "—", unit: "bpm")
                    stat("Maximum", session.maxHR.map(String.init) ?? "—", unit: "bpm")
                }
            }

            let track = session.heartRateTrack
            if track.count >= 2 {
                Card(title: "Heart rate") {
                    Chart(Array(track.enumerated()), id: \.offset) { _, point in
                        AreaMark(x: .value("Time", point.0), y: .value("bpm", point.1))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(
                                colors: [Section2.activity.accent.opacity(0.3), .clear],
                                startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", point.0), y: .value("bpm", point.1))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Section2.activity.accent)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine().foregroundStyle(.white.opacity(0.06))
                            AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 9))
                        }
                    }
                    .frame(height: 140)
                }
            }

            if let zones = HeartZones(age: store.age) {
                let time = zones.timeInZones(session)
                let longest = max(time.max() ?? 0, 1)
                Card(title: "Time in zones",
                     footnote: String(format: "Zones assume a maximum of %.0f bpm, from your age.", zones.maxHR)) {
                    ForEach((1...5).reversed(), id: \.self) { z in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("Zone \(z)").font(.subheadline)
                                Text(HeartZones.names[z - 1]).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(zones.range(z).lowerBound)–\(zones.range(z).upperBound) bpm")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                Text(Format.clock(time[z - 1]))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 48, alignment: .trailing)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.07))
                                    Capsule().fill(HeartZones.color(z))
                                        .frame(width: geo.size.width * CGFloat(time[z - 1] / longest))
                                }
                            }
                            .frame(height: 6)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                Card(title: "Time in zones") {
                    Text("Add your birth year in Settings to see heart rate zones.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .light, design: .rounded))
                    .monospacedDigit()
                if let unit { Text(unit).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Session detail

/// Opened from the timeline or the Activity screen. Sessions can be deleted
/// from here, as in Oura.
struct SessionDetail: View {
    @EnvironmentObject private var store: RingStore
    @Environment(\.dismiss) private var dismiss
    let session: CaptureSession

    @State private var confirmDelete = false

    /// The stored copy, so an added feeling shows up.
    private var current: CaptureSession {
        store.sessions.first { $0.id == session.id } ?? session
    }

    var body: some View {
        let session = current
        let accent = session.resolvedKind.accent
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Image(systemName: session.symbol)
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(accent)
                    Text("\(Format.time(session.started)) – \(Format.time(session.ended))")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(DayKey.full(session.dayKey))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)

                switch session.resolvedKind {
                case .workout:
                    WorkoutSummary(session: session)
                case .spotCheck:
                    Card(title: "Heart rate") {
                        Text(session.settledHR.map { "\($0) bpm" } ?? "—")
                            .font(.system(size: 44, weight: .light, design: .rounded))
                    }
                case .session, .capture:
                    SessionResults(session: session)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .background(
            ZStack(alignment: .top) {
                Palette.background
                LinearGradient(colors: [accent.opacity(0.24), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 360)
            }
            .ignoresSafeArea())
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Delete session", systemImage: "trash", role: .destructive) {
                        confirmDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.remove(session: session)
                dismiss()
            }
        }
    }
}

// MARK: - Overnight capture

/// The old always-on capture, now a setting: Oura has no equivalent because
/// its ring logs beat-to-beat data itself, and this one doesn't.
struct OvernightCaptureSection: View {
    @EnvironmentObject private var ring: RingConnection
    @ObservedObject var capture: RingCapture

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { capture.isOvernight },
                set: { $0 ? capture.startOvernight() : capture.stop() })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Overnight capture")
                        Text(capture.isOvernight ? capture.status : "Off")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!ring.isConnected && !capture.isOvernight)
        } header: {
            Text("Beat-to-beat")
        } footer: {
            Text("Streams for \(Int(capture.windowSeconds / 60)) minutes every \(Int((capture.windowSeconds + capture.gapSeconds) / 60)) to collect RR intervals, which the ring doesn't store. Optional — nightly HRV already comes from the ring's own log. Keep the phone nearby and charging.")
        }
    }
}
