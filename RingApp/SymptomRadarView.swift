import SwiftUI

// MARK: - Symptom Radar detail
//
// Laid out after Oura's: the level in Oura's wording, last night's biometrics
// with the ones that moved highlighted, recovery guidance and Rest Mode when
// there are signs, and the caveats Oura gives alongside it.

struct SymptomRadarDetail: View {
    @EnvironmentObject private var store: RingStore
    @Binding var day: String

    var body: some View {
        DetailScaffold(title: "Symptom Radar", section: .readiness,
                       day: $day, days: store.availableDays) {
            if let radar = store.symptomRadar(on: day) {
                summary(radar)
                if radar.level != .none { recovery }
                biometrics(radar)
            } else {
                notEnoughData
            }
            // The recovery card carries the switch when there are signs.
            if store.isRestMode(on: day),
               store.symptomRadar(on: day).map({ $0.level == .none }) ?? true {
                RestModeCard()
            }
            history
            about
        }
    }

    private func summary(_ radar: SymptomRadar) -> some View {
        ZStack(alignment: .bottomLeading) {
            Palette.card
            RadarSphere(color: radar.level.color)
            VStack(alignment: .leading, spacing: 8) {
                Spacer(minLength: 0)
                Text(radar.level.rawValue)
                    .font(.system(size: 34, weight: .regular, design: .serif))
                    .foregroundStyle(radar.level == .none ? Color.primary : radar.level.color)
                Text(radar.level.summary)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if radar.awaitingConfirmation {
                    Label("Last night alone looked like major signs. If tonight agrees, this moves to major.",
                          systemImage: "moon.stars")
                        .font(.caption).foregroundStyle(SymptomRadar.Level.major.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
        }
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.hairline, lineWidth: 1))
    }

    private var recovery: some View {
        Card(title: "Prioritize recovery") {
            ForEach([("bed.double", "Get to bed a little earlier tonight."),
                     ("figure.walk", "Keep activity light and skip hard training."),
                     ("drop", "Drink water and eat well."),
                     ("eye", "Notice how you feel. In TemPredict, changes showed up days before people sought a test.")],
                    id: \.0) { symbol, text in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .frame(width: 20)
                        .foregroundStyle(Section2.readiness.accent)
                    Text(text).font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().overlay(Palette.hairline)
            RestModeToggle()
        }
    }

    private func biometrics(_ radar: SymptomRadar) -> some View {
        Card(title: "Last night",
             footnote: "Highlighted: more than one standard deviation from your 28-day normal in the direction of strain — or, for resting heart rate, 3 bpm or more over your median.") {
            ForEach(radar.signals) { signal in
                BiometricRow(signal: signal)
                if signal.id != radar.signals.last?.id {
                    Divider().overlay(Palette.hairline)
                }
            }
        }
    }

    private var notEnoughData: some View {
        let nights = nightsInLastTwoWeeks
        return Card(title: "Getting to know you") {
            Text("Symptom Radar needs at least \(SymptomRadar.requiredNights) nights of sleep in the past two weeks, plus last night's biometrics.")
                .font(.subheadline)
            ProgressBar(fraction: Double(nights) / Double(SymptomRadar.requiredNights),
                        color: Section2.readiness.accent)
            Text("\(min(nights, SymptomRadar.requiredNights)) of \(SymptomRadar.requiredNights) nights")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var nightsInLastTwoWeeks: Int {
        guard let date = DayKey.date(day),
              let start = Calendar.current.date(byAdding: .day, value: -13, to: date) else { return 0 }
        let from = DayKey.of(start)
        return store.daily.filter { $0.dayKey >= from && $0.dayKey <= day && $0.asleepMinutes != nil }.count
    }

    /// One dot per morning for the last two weeks.
    private var history: some View {
        let days: [String] = {
            guard let date = DayKey.date(day) else { return [] }
            return (0..<14).reversed().compactMap {
                Calendar.current.date(byAdding: .day, value: -$0, to: date).map(DayKey.of)
            }
        }()
        return Card(title: "Past two weeks") {
            HStack(spacing: 5) {
                ForEach(days, id: \.self) { key in
                    let level = store.symptomRadar(on: key)?.level
                    Capsule()
                        .fill(level.map { $0 == .none ? Color.white.opacity(0.18) : $0.color }
                              ?? Color.white.opacity(0.05))
                        .frame(height: level == nil ? 10 : (level == .major ? 34 : (level == .minor ? 24 : 14)))
                        .frame(maxWidth: .infinity, maxHeight: 34, alignment: .bottom)
                        .overlay(alignment: .bottom) {
                            if key == day {
                                Circle().fill(.white).frame(width: 4, height: 4).offset(y: 9)
                            }
                        }
                }
            }
            .padding(.bottom, 8)
            HStack(spacing: 12) {
                legend(Color.white.opacity(0.18), "No signs")
                legend(SymptomRadar.Level.minor.color, "Minor")
                legend(SymptomRadar.Level.major.color, "Major")
                legend(Color.white.opacity(0.05), "No data")
            }
        }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var about: some View {
        Card(title: "How it works") {
            Text("Each morning, Symptom Radar compares last night with your own 28-day normal: body temperature and its three-night trend, resting heart rate, HRV, respiratory rate, and yesterday's inactive time. It looks for several of these shifting together, so it can pick up strain while each number still sits inside its usual range.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Two rules come from Stanford's NightSignal study: a resting heart rate 3 bpm or more above your median always counts, and 4 bpm counts strongly. And major signs need two nights in a row, so one rough night can't raise the strongest alert on its own.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("The approach follows UCSF's TemPredict study with Oura, where temperature, heart rate, HRV and respiratory rate together flagged COVID-19 an average of 2.75 days before people sought testing.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Not a medical device, and it can't diagnose anything. It may be less reliable with pre-existing conditions or during pregnancy, and it won't always agree with your Readiness score.")
                .font(.footnote).foregroundStyle(.tertiary)
        }
    }
}

private struct BiometricRow: View {
    let signal: SymptomRadar.Signal

    private var color: Color {
        signal.z >= 2 ? Palette.low : (signal.isFlagged ? Palette.fair : .secondary)
    }

    private var direction: String {
        let delta = signal.value - signal.normal
        guard signal.isFlagged else { return "Within your normal" }
        return delta > 0 ? "Higher than usual" : "Lower than usual"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if signal.isFlagged {
                        Circle().fill(color).frame(width: 7, height: 7)
                    }
                    Text(signal.metric.name).font(.subheadline)
                }
                Text("Normal \(signal.metric.format(signal.normal))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(signal.metric.format(signal.value))
                    .font(.subheadline.monospacedDigit())
                Text(direction).font(.caption).foregroundStyle(color)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Today card

/// Shown on Today only when there are signs, as Oura does.
struct SymptomRadarCard: View {
    @EnvironmentObject private var store: RingStore
    @Binding var day: String

    var body: some View {
        if let radar = store.symptomRadar(on: day), radar.level != .none {
            NavigationLink { SymptomRadarDetail(day: $day) } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(radar.level.color.opacity(0.18))
                        Circle().stroke(radar.level.color, lineWidth: 1.5)
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(radar.level.color)
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SYMPTOM RADAR")
                            .font(.caption2.weight(.semibold)).tracking(1.1)
                            .foregroundStyle(.secondary)
                        Text(radar.level.rawValue)
                            .font(.title3)
                            .foregroundStyle(radar.level.color)
                        Text(radar.detail)
                            .font(.footnote).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(radar.level.color.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Rest Mode

struct RestModeToggle: View {
    @EnvironmentObject private var store: RingStore

    var body: some View {
        Button {
            withAnimation { store.restModeSince = store.restModeSince == nil ? Date() : nil }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bed.double.fill")
                    .foregroundStyle(Section2.stress.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.restModeSince == nil ? "Turn on Rest Mode" : "Rest Mode is on")
                        .font(.subheadline.weight(.medium))
                    Text(store.restModeSince == nil
                         ? "Pauses your Activity score and goals while Symptom Radar keeps watching."
                         : "Tap to turn off when you're feeling better.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: store.restModeSince == nil ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(store.restModeSince == nil ? Color.secondary : Section2.stress.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Today's reminder while Rest Mode is on.
struct RestModeCard: View {
    @EnvironmentObject private var store: RingStore

    var body: some View {
        if let since = store.restModeSince {
            Card(title: "Rest Mode", accent: Section2.stress.accent) {
                Text("Activity goals are paused while you recover.")
                    .font(.subheadline)
                Text("On since \(since.formatted(.dateTime.weekday(.wide).hour().minute()))")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Turn off Rest Mode") { withAnimation { store.restModeSince = nil } }
                    .font(.subheadline.weight(.medium))
                    .tint(Section2.stress.accent)
            }
        }
    }
}
