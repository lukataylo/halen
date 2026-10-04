import Charts
import EQCore
import SwiftUI

enum SidebarItem: Hashable { case overview, session(UUID) }

struct MainWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Overview", systemImage: "circle.circle").tag(SidebarItem.overview)
                ForEach(days, id: \.0) { day, rs in
                    Section(day) {
                        ForEach(rs) { r in
                            SessionRow(record: r).tag(SidebarItem.session(r.id))
                                .contextMenu { Button("Delete", role: .destructive) { model.delete(r.id) } }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            switch selection {
            case .session(let id):
                if let r = model.session(id) { SessionDetail(record: r) } else { overview }
            default:
                overview
            }
        }
        .frame(minWidth: 760, minHeight: 540)
    }

    private var overview: some View { Overview().navigationTitle("Overview").toolbar(removing: .title) }

    private var days: [(String, [SessionRecord])] {
        let groups = Dictionary(grouping: model.sessions) { Calendar.current.startOfDay(for: $0.startedAt) }
        return groups.keys.sorted(by: >).map { ($0.dayTitle, groups[$0]!) }
    }
}

struct SessionRow: View {
    let record: SessionRecord
    var body: some View {
        HStack(spacing: 8) {
            SourceIcon(bundleID: record.source, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.startedAt.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                Text("\(record.title) · \(record.minutes) min")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            // Mini score: one dot per dimension, lit when on target (≥ 70).
            HStack(spacing: 3) {
                ForEach(Insights.Dimension.allCases, id: \.self) { d in
                    let v = d.score(record.effectiveScores).value
                    Circle().fill(v.map { $0 >= 70 } == true ? Palette.color(d) : Dot.off).frame(width: 5, height: 5)
                }
            }
            .accessibilityHidden(true)
            Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 7, height: 7)
                .opacity(record.rating == nil ? 1 : 0)
                .help("Not rated yet")
        }
        .padding(.vertical, 2)
    }
}

// MARK: Overview

struct Overview: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No conversations yet", systemImage: "waveform")
                    } description: {
                        Text("Join a call — Halen starts on its own, hears only you, and forgets the audio.")
                    }
                    .padding(.top, 60)
                } else {
                    TodayHero()
                    WeekDots()
                    HStack(alignment: .top, spacing: 16) { focus; outcome }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var focus: some View {
        let f = Insights.focus(model.sessions)
        return Card(title: "This week's focus", accent: f.flatMap { Insights.Dimension(factorID: $0.id) }) {
            if let f {
                Text(f.label).font(.title3.weight(.semibold))
                Text("Most often off-target in the last 7 days.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Nothing stands out").font(.title3.weight(.semibold))
                Text("No habit has been consistently off-target this week.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var outcome: some View {
        let rated = model.sessions.filter { $0.rating != nil }.count
        let link = Insights.whatPredictsGoodCalls(model.sessions)
        return Card(title: "Your good calls", accent: link.flatMap { Insights.Dimension(factorID: $0.factorID) }) {
            if let link {
                Text(link.label).font(.title3.weight(.semibold))
                Text("When this was on target, you rated the call higher (\(link.n) rated calls).")
                    .font(.callout).foregroundStyle(.secondary)
            } else if rated >= 6 {
                Text("No clear pattern yet").font(.title3.weight(.semibold))
                Text("None of your habits lines up with your ratings so far. Keep rating.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("\(rated) of 6 rated").font(.title3.weight(.semibold)).monospacedDigit()
                DotBars(values: (0 ..< 6).map { $0 < rated ? 100 : nil }, color: .primary, rows: 1, dot: 7)
                    .frame(width: 120)
                Text("Rate a few calls and Halen learns what *your* good calls have in common.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Today, Nothing-widget style: a black card, coloured dot rings, white
/// dot-matrix numerals. High contrast in light and dark mode alike.
struct TodayHero: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let today = model.today
        let talked = Int(today.reduce(0) { $0 + $1.metrics.speakingSeconds } / 60)
        let tone = today.compactMap(\.metrics.tone)
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("TODAY").font(Dot.font(26)).tracking(3).foregroundStyle(.white)
                Text(today.isEmpty ? "No calls yet" : "\(today.count) call\(today.count == 1 ? "" : "s") · you spoke \(talked) min")
                    .font(.callout).foregroundStyle(.white.opacity(0.7))
                if let mood = Tone.mood(tone.isEmpty ? nil : tone.reduce(0, +) / Double(tone.count)) {
                    HStack(spacing: 8) {
                        DotFace(mood: mood, size: 18).colorScheme(.dark)
                        Text(mood.label.uppercased()).font(Dot.font(12)).tracking(1.5).foregroundStyle(.white)
                        let laughs = today.reduce(0) { $0 + $1.metrics.laughs }
                        if laughs > 0 { Text("· LAUGHED \(laughs)×").font(Dot.font(12)).tracking(1.5).foregroundStyle(.white.opacity(0.75)) }
                    }
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 22) {
                ForEach(Insights.Dimension.allCases, id: \.self) { d in
                    DotRing(value: Insights.score(d, today), label: d.rawValue, size: 76, dots: 32,
                            color: Palette.color(d), labelColor: .white.opacity(0.75))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(22)
        .background(Color.black, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }
}

/// Last seven days, one dot-bar row per dimension.
struct WeekDots: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DotLabel("Last 7 days", size: 11)
            ForEach(Insights.Dimension.allCases, id: \.self) { d in
                let days = Insights.daily(d, model.sessions)
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(Palette.color(d)).frame(width: 8, height: 8)
                            Text(d.rawValue).font(.headline)
                        }
                        Text(trend(days.map(\.value))).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 140, alignment: .leading)
                    DotBars(values: days.map(\.value), color: Palette.color(d), rows: 5, dot: 5)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(d.rawValue), last 7 days")
                .accessibilityValue(days.map { "\($0.day.formatted(.dateTime.weekday(.wide))) \($0.value.map(String.init) ?? "no calls")" }.joined(separator: ", "))
            }
            HStack(spacing: 16) {
                Color.clear.frame(width: 140, height: 1)
                HStack(spacing: 0) {
                    ForEach(Insights.daily(.presence, model.sessions), id: \.day) { d in
                        let today = Calendar.current.isDateInToday(d.day)
                        Text(today ? "Today" : d.day.formatted(.dateTime.weekday(.abbreviated)))
                            .textCase(.uppercase)
                            .font(Dot.font(11, today ? .black : .bold))
                            .foregroundStyle(today ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .padding(16)
        .dotCard()
    }

    /// "↑ 8 vs your week" — today vs the mean of the earlier days.
    private func trend(_ v: [Int?]) -> String {
        guard let today = v.last ?? nil else { return "No calls today" }
        let before = v.dropLast().compactMap { $0 }
        guard !before.isEmpty else { return "First day this week" }
        let delta = today - before.reduce(0, +) / before.count
        return delta == 0 ? "Same as your week" : "\(delta > 0 ? "↑" : "↓") \(abs(delta)) vs your week"
    }
}

struct Card<Content: View>: View {
    let title: String
    var accent: Insights.Dimension? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let accent { Circle().fill(Palette.color(accent)).frame(width: 7, height: 7) }
                DotLabel(title, size: 10)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .dotCard()
    }
}

// MARK: Session detail

struct SessionDetail: View {
    let record: SessionRecord
    @EnvironmentObject var model: AppModel
    @State private var rating = 0.5
    @State private var touched = false
    @State private var note = ""
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let t = record.takeaway {
                    Text(t).font(.body).fixedSize(horizontal: false, vertical: true)
                }
                feedback
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Insights.Dimension.allCases, id: \.self) { d in
                        DimensionCard(record: record, dimension: d)
                    }
                }
                timeline
                footnote
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(record.title)
        .navigationSubtitle(record.startedAt.formatted(date: .abbreviated, time: .shortened))
        .toolbar {
            ToolbarItem {
                Button("Delete", systemImage: "trash") { confirmDelete = true }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help("Delete this conversation (⌘⌫)")
            }
        }
        .confirmationDialog("Delete this conversation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete(record.id) }
        } message: { Text("Its scores and any saved words are removed. This can't be undone.") }
        .onAppear(perform: load)
        .onChange(of: record.id) { load() }
    }

    private func load() {
        rating = record.rating ?? 0.5
        touched = record.rating != nil
        note = record.note ?? ""
    }

    private var header: some View {
        HStack(spacing: 12) {
            SourceIcon(bundleID: record.source, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(record.startedAt.formatted(date: .complete, time: .shortened)) · \(record.minutes) min, you spoke \(Int(record.metrics.speakingSeconds / 60)) min")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MoodBadge(tone: record.metrics.tone, laughs: record.metrics.laughs)
        }
    }

    private var feedback: some View {
        // One compact row: label · dots · word, then the note. Saves when you
        // let go of the slider (not on every tick) and when the note is submitted.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                DotLabel("How did it go?", size: 10)
                DotSlider(value: $rating.onSet { touched = true }, touched: touched, onCommit: { model.rate(record.id, rating, note: note) })
                    .frame(maxWidth: 260)
                Text(touched ? Rating.word(rating) : "–").font(Dot.font(13)).frame(width: 48, alignment: .leading)
            }
            TextField("Note to self", text: $note)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                .onSubmit { if touched { model.rate(record.id, rating, note: note) } }
        }
        .padding(12)
        .dotCard()
    }

    /// Where it got heated: each bar is 5 s; height is how much you spoke,
    /// red means pitch/loudness/pace were up together.
    private var timeline: some View {
        let a = Composure.analyse(record.metrics.windows, calm: model.baseline)
        let elevated = Set(a.active.filter(\.elevated).map(\.summary.start))
        return VStack(alignment: .leading, spacing: 8) {
            DotLabel("Through the conversation", size: 12)
            DotTimeline(windows: record.metrics.windows, heated: elevated)
            HStack(spacing: 6) {
                Circle().fill(Dot.red).frame(width: 6, height: 6)
                Text("Pitch, volume and pace rose together. Each column is 5 seconds; height is how much you spoke.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footnote: some View {
        let m = record.metrics
        var parts = ["Audio deleted after analysis"]
        parts.append(m.voiceChecked ? "voice check ignored \(Int(m.ignoredSeconds)) s of other voices" : "voice check was off")
        if record.words != nil { parts.append("your words saved for \(model.transcriptDays) days") }
        return Label(parts.joined(separator: " · "), systemImage: "lock.fill")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct DimensionCard: View {
    let record: SessionRecord
    let dimension: Insights.Dimension
    @EnvironmentObject var model: AppModel

    var body: some View {
        let score = dimension.score(record.effectiveScores)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DotRing(value: score.value, size: 42, color: Palette.color(dimension))
                DotLabel(dimension.rawValue, size: 12, tint: .primary)
            }
            if score.factors.isEmpty {
                Text(dimension == .composure ? "Needs a few minutes of you speaking." : "Not measured.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(score.factors) { f in FactorRow(factor: f, disputed: record.disputed.contains(f.id)) {
                model.toggleDispute(record.id, factor: f.id)
            } }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dotCard()
    }
}

/// One measured factor. "Not right?" lets you overrule it — it then stops
/// counting toward this call's score, the weekly focus and the takeaway. The control
/// lives in a fixed-width slot that only fades in, so hovering never
/// reflows the card.
struct FactorRow: View {
    let factor: Factor
    let disputed: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // 1–3 lit dots = how far off target (dot-matrix severity).
            HStack(spacing: 2) {
                ForEach(0 ..< 3) { i in
                    Circle().fill(disputed ? Dot.off : Double(i) < factor.penalty + 0.5 ? (factor.penalty >= 1.5 ? Dot.red : Dot.on) : Dot.off)
                        .frame(width: 4, height: 4)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(factor.label).strikethrough(disputed).lineLimit(1)
                Text(factor.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: toggle) {
                Image(systemName: disputed ? "arrow.uturn.backward" : "hand.thumbsdown")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .opacity(hover || disputed ? 1 : 0.3)
            .help(disputed ? "Count this again" : "Not right? Leave it out of this call's score")
        }
        .font(.callout)
        .contentShape(.rect)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .contextMenu { Button(disputed ? "Count This Again" : "This Isn't Right", action: toggle) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(disputed ? "Left out" : factor.penalty < 0.5 ? "On target" : factor.penalty < 1.5 ? "Slightly off target" : "Well off target")
        .accessibilityAction(named: disputed ? "Count this again" : "Mark as not right", toggle)
    }
}
