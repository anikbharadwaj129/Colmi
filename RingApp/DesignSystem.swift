import SwiftUI
import Charts

// MARK: - Sections
//
// Each area of the app carries its own accent, so a screen's identity is
// readable before you've parsed a single number.

enum Section2: String {
    case readiness, sleep, activity, stress, heart, bodyClock

    var accent: Color {
        switch self {
        case .readiness: return Color(red: 0.42, green: 0.69, blue: 0.97)   // blue
        case .sleep:     return Color(red: 0.36, green: 0.82, blue: 0.64)   // green
        case .activity:  return Color(red: 0.98, green: 0.66, blue: 0.40)   // amber
        case .stress:    return Color(red: 0.66, green: 0.55, blue: 0.96)   // purple
        case .heart:     return Color(red: 0.96, green: 0.52, blue: 0.55)   // rose
        case .bodyClock: return Color(red: 0.38, green: 0.78, blue: 0.82)   // teal
        }
    }

    /// Hero backdrop — a deep wash of the accent rather than flat color.
    var gradient: LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.28), accent.opacity(0.06), .clear],
            startPoint: .top, endPoint: .bottom)
    }

    var symbol: String {
        switch self {
        case .readiness: return "leaf"
        case .sleep:     return "moon"
        case .activity:  return "flame"
        case .stress:    return "waveform.path"
        case .heart:     return "heart"
        case .bodyClock: return "clock"
        }
    }
}

enum Palette {
    static let background = Color(red: 0.04, green: 0.04, blue: 0.055)
    static let card       = Color(red: 0.093, green: 0.095, blue: 0.12)
    static let hairline   = Color.white.opacity(0.07)

    static let optimal = Color(red: 0.36, green: 0.81, blue: 0.63)
    static let good    = Color(red: 0.45, green: 0.72, blue: 0.95)
    static let fair    = Color(red: 0.96, green: 0.76, blue: 0.36)
    static let low     = Color(red: 0.95, green: 0.50, blue: 0.44)

    static let deep  = Color(red: 0.23, green: 0.36, blue: 0.75)
    static let rem   = Color(red: 0.36, green: 0.66, blue: 0.93)
    static let light = Color(red: 0.55, green: 0.76, blue: 0.96)
    static let awake = Color(red: 0.93, green: 0.93, blue: 0.95)

    static func color(_ band: ScoreBand) -> Color {
        switch band {
        case .optimal:      return optimal
        case .good:         return good
        case .fair:         return fair
        case .payAttention: return low
        }
    }

    static func color(_ stage: SleepStage) -> Color {
        switch stage {
        case .deep:  return deep
        case .rem:   return rem
        case .light: return light
        case .awake: return awake
        }
    }
}

// MARK: - Day navigator
//
// A swipeable day strip that every detail screen shares, so moving back a day
// moves the whole screen rather than one card.

struct DayNavigator: View {
    @Binding var selection: String
    let days: [String]
    var accent: Color = .white

    private var index: Int { days.firstIndex(of: selection) ?? days.count - 1 }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if index > 0 { select(days[index - 1]) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 44, height: 36)
            }
            .disabled(index <= 0)
            .opacity(index <= 0 ? 0.25 : 1)

            Spacer(minLength: 0)

            VStack(spacing: 1) {
                Text(DayKey.friendly(selection))
                    .font(.subheadline.weight(.semibold))
                if !DayKey.isToday(selection) {
                    Text(DayKey.full(selection))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 130)
            .contentTransition(.numericText())

            Spacer(minLength: 0)

            Button {
                if index < days.count - 1 { select(days[index + 1]) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 44, height: 36)
            }
            .disabled(index >= days.count - 1)
            .opacity(index >= days.count - 1 ? 0.25 : 1)
        }
        .tint(accent)
        .padding(.horizontal, 4)
        .background(Palette.card.opacity(0.6), in: Capsule())
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.translation.width > 0, index > 0 {
                        select(days[index - 1])
                    } else if value.translation.width < 0, index < days.count - 1 {
                        select(days[index + 1])
                    }
                })
    }

    private func select(_ day: String) {
        withAnimation(.snappy(duration: 0.25)) { selection = day }
    }
}

// MARK: - Gauges

struct ScoreGauge: View {
    let score: Int
    let label: String
    var accent: Color = Palette.good
    var size: CGFloat = 180
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.06), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(score, 2)) / 100)
                .stroke(
                    AngularGradient(colors: [accent.opacity(0.45), accent], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: score)

            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: size * 0.33, weight: .thin, design: .rounded))
                    .monospacedDigit()
                if !label.isEmpty {
                    Text(label.uppercased())
                        .font(.system(size: size * 0.062, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// One circle in the Shortcuts row at the top of Today: symbol over the
/// value, label underneath. An optimal score swaps its symbol for a crown.
struct ShortcutCircle: View {
    let title: String
    let value: String?
    let symbol: String
    let accent: Color
    var isOptimal = false

    var body: some View {
        VStack(spacing: 9) {
            VStack(spacing: 1) {
                Image(systemName: isOptimal ? "crown.fill" : symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isOptimal ? .white : accent)
                Text(value ?? "–")
                    .font(.system(size: 24, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(value == nil ? .tertiary : .primary)
            }
            .padding(.horizontal, 8)
            .frame(width: 68, height: 68)
            .background(Color.white.opacity(0.035), in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))

            Text(title)
                .font(.footnote)
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
        }
        .frame(width: 82)
        .contentShape(Rectangle())
    }
}

// MARK: - Cards

struct Card<Content: View>: View {
    var title: String? = nil
    var accent: Color = .white
    var footnote: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
            }
            content
            if let footnote {
                Text(footnote).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.hairline, lineWidth: 1))
    }
}

struct ContributorRow: View {
    let contributor: Contributor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(contributor.name).font(.subheadline)
                Spacer()
                Text(contributor.detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07)).frame(height: 6)
                    Capsule()
                        .fill(Palette.color(contributor.band))
                        .frame(width: geo.size.width * CGFloat(contributor.score) / 100, height: 6)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Stepped hypnogram
//
// Stage drawn as columns stepping down from awake to deep, with a movement
// track underneath. The ring doesn't expose raw accelerometer data, so the
// movement track is derived from stage transitions and wake episodes — it
// marks disturbances rather than measuring motion directly.

struct SteppedHypnogram: View {
    let night: SleepNight
    var height: CGFloat = 170

    private func level(_ stage: SleepStage) -> Int {
        switch stage {
        case .awake: return 3
        case .rem:   return 2
        case .light: return 1
        case .deep:  return 0
        }
    }

    /// A disturbance is a wake episode, or any jump of two or more stage levels.
    private var disturbances: [Date] {
        var out: [Date] = []
        for (previous, current) in zip(night.segments, night.segments.dropFirst()) {
            if current.stage == .awake || abs(level(current.stage) - level(previous.stage)) >= 2 {
                out.append(current.start)
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 10) {
            Chart {
                ForEach(night.segments) { segment in
                    RectangleMark(
                        xStart: .value("Start", segment.start),
                        xEnd: .value("End", segment.end),
                        yStart: .value("Floor", level(segment.stage)),
                        yEnd: .value("Top", level(segment.stage) + 1))
                    .foregroundStyle(Palette.color(segment.stage))
                }
            }
            .chartYScale(domain: 0...4)
            .chartYAxis {
                AxisMarks(values: [0.5, 1.5, 2.5, 3.5]) { value in
                    AxisValueLabel {
                        Text(stageLabel(value.index))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 2)) { value in
                    AxisValueLabel(format: .dateTime.hour())
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: height)

            VStack(alignment: .leading, spacing: 4) {
                Text("MOVEMENT")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)

                GeometryReader { geo in
                    let span = night.end.timeIntervalSince(night.start)
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 1)
                            .frame(maxHeight: .infinity, alignment: .center)
                        ForEach(Array(disturbances.enumerated()), id: \.offset) { _, time in
                            Rectangle()
                                .fill(Color.white.opacity(0.65))
                                .frame(width: 1.5, height: 14)
                                .offset(x: geo.size.width
                                        * CGFloat(time.timeIntervalSince(night.start) / max(span, 1)))
                        }
                    }
                }
                .frame(height: 18)
            }
        }
    }

    private func stageLabel(_ index: Int) -> String {
        ["Deep", "Light", "REM", "Awake"][min(max(index, 0), 3)]
    }
}

struct StageLegend: View {
    let night: SleepNight

    var body: some View {
        VStack(spacing: 9) {
            ForEach([SleepStage.awake, .rem, .light, .deep], id: \.rawValue) { stage in
                let minutes = night.minutes(in: stage)
                if minutes > 0 {
                    HStack(spacing: 10) {
                        Capsule()
                            .fill(Palette.color(stage))
                            .frame(width: 22, height: 7)
                        Text(stage.label).font(.subheadline)
                        Spacer()
                        Text(Format.duration(minutes))
                            .font(.subheadline.monospacedDigit())
                        Text("\(Int(Double(minutes) / Double(max(night.totalMinutes, 1)) * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - Body clock dial

/// Two arcs: your established rhythm and last night's actual sleep, so the
/// shift between them is visible rather than stated.
struct BodyClockDial: View {
    let clock: BodyClock

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let scale: (Double) -> CGFloat = { hour in
                // Map −6h…+6h around the chronotype onto the width.
                let offset = (hour - clock.chronotypeHour + 6) / 12
                return width * CGFloat(max(0, min(1, offset)))
            }

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 8)

                Capsule()
                    .fill(Section2.bodyClock.accent.opacity(0.35))
                    .frame(width: width / 6, height: 8)
                    .offset(x: scale(clock.chronotypeHour) - width / 12)

                Circle()
                    .fill(Section2.bodyClock.accent)
                    .frame(width: 13, height: 13)
                    .offset(x: scale(clock.lastNightHour) - 6.5)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 30)
    }
}
