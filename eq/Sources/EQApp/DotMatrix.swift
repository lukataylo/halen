import AppKit
import CoreText
import EQCore
import SwiftUI

/// Dot-matrix design language (after Nothing OS): monochrome dots, a
/// dot-matrix face for numerals and labels, one red accent reserved for
/// "heated". Body copy stays in the system font for legibility.
enum Dot {
    static let red = Color(red: 0.84, green: 0.10, blue: 0.13)      // Nothing red
    static let on = Color.primary
    static let off = Color.primary.opacity(0.13)

    /// Registers Doto (SIL OFL) from the app bundle, or from the source tree
    /// for `swift run`. Falls back to SF Mono if neither is found.
    static func registerFont() {
        var candidates = [Bundle.main.url(forResource: "Doto", withExtension: "ttf")]
        #if DEBUG
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Doto.ttf").standardized)
        #endif
        if let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Checked once, after registerFont() ran at launch.
    static let hasFont = NSFont(name: "Doto", size: 12) != nil

    static func font(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        hasFont ? .custom("Doto", size: size, relativeTo: .body).weight(weight) : .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Small uppercase dot-matrix label, letter-spaced.
struct DotLabel: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let text: String
    var size: CGFloat = 11
    /// Overrides the default muted label colour (an outer .foregroundStyle
    /// wouldn't — the inner one wins).
    var tint: Color? = nil
    init(_ text: String, size: CGFloat = 11, tint: Color? = nil) { self.text = text; self.size = size; self.tint = tint }
    var body: some View {
        Text(text).textCase(.uppercase)
            .font(Dot.font(max(11, size), .heavy)).tracking(max(11, size) * 0.12)
            .foregroundStyle(tint ?? (contrast == .increased ? .primary : Color.primary.opacity(0.72)))
            .lineLimit(1).fixedSize()
    }
}

// MARK: Ring

/// A score as a ring of dots: lit dots = score. Dims by label, not colour.
struct DotRing: View {
    var value: Int?
    var label: String?
    var size: CGFloat = 56
    var dots = 30
    var color: Color = Dot.on
    var labelColor: Color? = nil

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Canvas { ctx, sz in
                    let r = sz.width / 2 - size * 0.06
                    let d = max(2, size * 0.075)
                    let lit = Int((Double(value ?? 0) / 100 * Double(dots)).rounded())
                    for i in 0 ..< dots {
                        let a = Double(i) / Double(dots) * 2 * .pi - .pi / 2
                        let p = CGPoint(x: sz.width / 2 + r * cos(a), y: sz.height / 2 + r * sin(a))
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                                 with: .color(i < lit ? color : Dot.off))
                    }
                }
                Text(value.map(String.init) ?? "–")
                    .font(Dot.font(size * 0.34))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .frame(width: size * 0.62)
                    .foregroundStyle(value == nil ? .tertiary : .primary)
            }
            .frame(width: size, height: size)
            .animation(.smooth, value: value)
            if let label {
                DotLabel(label, size: max(9, size * 0.15), tint: labelColor)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label ?? "Score"): \(value.map { "\($0) out of 100" } ?? "not enough data")")
    }
}

// MARK: Waveform

/// Live dot-matrix waveform: your level rises from the centre line, theirs
/// (level only — never audio) mirrors below in grey. Newest on the right.
struct DotWaveform: View {
    var you: [Float]
    var them: [Float]?
    var rows = 4            // per half
    var dot: CGFloat = 3.5

    var body: some View {
        Canvas { ctx, size in
            let pitch = dot * 1.9
            let cols = Int(size.width / pitch)
            let mid = size.height / 2
            func lit(_ db: Float) -> Int { Int((max(0, min(1, (db + 55) / 45)) * Float(rows)).rounded()) }
            for c in 0 ..< cols {
                let x = CGFloat(c) * pitch + pitch / 2
                let iy = you.count - cols + c, it = (them?.count ?? 0) - cols + c
                let up = iy >= 0 ? lit(you[iy]) : 0
                let down = it >= 0 ? lit(them![it]) : 0
                for r in 0 ..< rows {
                    let dy = CGFloat(r) * pitch + pitch / 2
                    let a = CGRect(x: x - dot / 2, y: mid - dy - dot / 2, width: dot, height: dot)
                    ctx.fill(Path(ellipseIn: a), with: .color(r < up ? Dot.on : Dot.off))
                    if them != nil {
                        let b = CGRect(x: x - dot / 2, y: mid + dy - dot / 2 + pitch / 2, width: dot, height: dot)
                        ctx.fill(Path(ellipseIn: b), with: .color(r < down ? Color.secondary : Dot.off))
                    }
                }
            }
        }
        .frame(height: CGFloat(them == nil ? rows : rows * 2) * dot * 1.9 + dot)
        .accessibilityElement()
        .accessibilityLabel(them == nil ? "Your voice level" : "Your voice level above, the other side below")
    }
}

// MARK: Timeline

/// A conversation as a dot matrix: one column per 5 s, height = how much
/// you spoke, red = a heated stretch.
struct DotTimeline: View {
    var windows: [WindowSummary]
    var heated: Set<Double>
    var rows = 6

    var body: some View {
        GeometryReader { g in
            let cols = max(windows.count, 1)
            let pitch = min(g.size.width / CGFloat(cols), 9)
            let dot = pitch * 0.62
            Canvas { ctx, _ in
                for (c, w) in windows.enumerated() {
                    let lit = Int((w.speaking * Double(rows)).rounded())
                    let hot = heated.contains(w.start)
                    for r in 0 ..< rows {
                        let rect = CGRect(x: CGFloat(c) * pitch, y: CGFloat(rows - 1 - r) * pitch, width: dot, height: dot)
                        ctx.fill(Path(ellipseIn: rect), with: .color(r < lit ? (hot ? Dot.red : Dot.on) : Dot.off))
                    }
                }
            }
        }
        .frame(height: CGFloat(rows) * 9)
        .accessibilityElement()
        .accessibilityLabel("Timeline: \(heated.count) heated stretches")
    }
}

// MARK: Slider

/// "How did it go?" as a row of dots you drag across. Arrow keys work when
/// focused; VoiceOver gets an adjustable control.
struct DotSlider: View {
    @Binding var value: Double
    /// Until the user drags, nothing is lit — an untouched slider must not
    /// look like an answer.
    var touched = true
    var dots = 21
    /// Called when a drag ends or a key step lands — the moment to save.
    var onCommit: (() -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { g in
            let pitch = g.size.width / CGFloat(dots)
            let d = min(pitch * 0.55, 9)
            let lit = Int((value * Double(dots - 1)).rounded())
            Canvas { ctx, size in
                for i in 0 ..< dots {
                    let isThumb = i == lit
                    let s = isThumb ? d * 1.6 : d
                    let rect = CGRect(x: CGFloat(i) * pitch + (pitch - s) / 2, y: (size.height - s) / 2, width: s, height: s)
                    if !touched {
                        if isThumb { ctx.stroke(Path(ellipseIn: rect.insetBy(dx: 0.75, dy: 0.75)), with: .color(.secondary), lineWidth: 1.5) }
                        else { ctx.fill(Path(ellipseIn: rect), with: .color(Dot.off)) }
                    } else {
                        ctx.fill(Path(ellipseIn: rect), with: .color(i <= lit ? Dot.on : Dot.off))
                    }
                }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in value = max(0, min(1, Double(v.location.x / g.size.width))) }
                .onEnded { _ in onCommit?() })
        }
        .frame(height: 18)
        // Focusable for arrow keys, but never grabs initial focus (no ring
        // flashing up every time the popover or card opens).
        .focusable(interactions: .edit)
        .focused($focused)
        .focusEffectDisabled()
        .overlay { if focused && NSApp.currentEvent?.type == .keyDown { Capsule().stroke(Color.accentColor.opacity(0.5), lineWidth: 1).padding(-4) } }
        .onMoveCommand { dir in
            let step = 1 / Double(dots - 1)
            if dir == .left { value = max(0, value - step) }
            if dir == .right { value = min(1, value + step) }
            onCommit?()
        }
        .accessibilityElement()
        .accessibilityLabel("How did it go?")
        .accessibilityValue(touched ? Rating.word(value) : "Not rated")
        .accessibilityAdjustableAction { dir in
            value = dir == .increment ? min(1, value + 0.1) : max(0, value - 0.1)
            onCommit?()
        }
    }
}

// MARK: Faces

/// 7×7 dot-matrix face for tone: smile, level, frown.
struct DotFace: View {
    let mood: Tone.Mood
    var size: CGFloat = 22

    static let faces: [Tone.Mood: [String]] = [
        .positive: [".#####.", "#.....#", "#.#.#.#", "#.....#", "#.#.#.#", "#..#..#", ".#####."],
        .neutral:  [".#####.", "#.....#", "#.#.#.#", "#.....#", "#.###.#", "#.....#", ".#####."],
        .negative: [".#####.", "#.....#", "#.#.#.#", "#.....#", "#..#..#", "#.#.#.#", ".#####."],
    ]

    var body: some View {
        Canvas { ctx, sz in
            let rows = Self.faces[mood]!
            let p = sz.width / 7, d = p * 0.7
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    ctx.fill(Path(ellipseIn: CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: d, height: d)),
                             with: .color(mood == .negative ? Dot.red : Dot.on))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(mood.label)
    }
}

extension View {
    /// Flat card with a hairline edge — the one container style.
    func dotCard() -> some View {
        background(.background.secondary, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// Seven days as dot columns: height = score, colour = dimension, empty
/// days are a single dim dot. Reads at a glance, unlike tangled lines.
struct DotBars: View {
    var values: [Int?]
    var color: Color
    var rows = 8
    var dot: CGFloat = 6

    var body: some View {
        Canvas { ctx, size in
            let colW = size.width / CGFloat(max(values.count, 1))
            let pitch = dot * 1.55
            for (c, v) in values.enumerated() {
                // Map 40–100 onto the rows: below 40 is rare and differences
                // in the 80s–90s are what you actually want to see.
                let lit = v.map { max(1, Int((Double(max($0, 40) - 40) / 60 * Double(rows)).rounded())) } ?? 0
                if c == values.count - 1 {
                    ctx.fill(Path(roundedRect: CGRect(x: CGFloat(c) * colW + colW * 0.2, y: 0, width: colW * 0.6, height: size.height), cornerRadius: colW * 0.3),
                             with: .color(.primary.opacity(0.06)))
                }
                let x = CGFloat(c) * colW + (colW - dot) / 2
                for r in 0 ..< rows {
                    let y = size.height - CGFloat(r + 1) * pitch
                    let fill: Color = r < lit ? color : Color.primary.opacity(v == nil && r > 0 ? 0.04 : 0.10)
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: dot, height: dot)), with: .color(fill))
                }
            }
        }
        .frame(height: CGFloat(rows) * dot * 1.55)
    }
}
