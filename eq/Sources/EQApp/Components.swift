import AppKit
import EQCore
import SwiftUI

/// One accent per dimension, lit dots only; everything else stays
/// monochrome. Red is reserved for "heated".
enum Palette {
    static let presence = Color(red: 0.24, green: 0.48, blue: 1.00)    // electric blue
    static let clarity = Color(red: 0.13, green: 0.80, blue: 0.47)     // signal green
    static let composure = Color(red: 1.00, green: 0.69, blue: 0.13)   // amber
    static func color(_ d: Insights.Dimension) -> Color {
        switch d { case .presence: presence; case .clarity: clarity; case .composure: composure }
    }
}

/// The Halen glyph, as a template image so macOS tints it for the menu bar.
/// While listening, a small dot is drawn beside it (template too, so it
/// follows light/dark/accent like every other status item).
enum MenubarIcon {
    static func image(listening: Bool) -> NSImage {
        let base = NSImage(named: "HalenMenubar") ?? NSImage(systemSymbolName: "bubble", accessibilityDescription: nil)!
        let size = NSSize(width: listening ? 22 : 16, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
            if listening { NSBezierPath(ovalIn: NSRect(x: 17.5, y: 10.5, width: 4.5, height: 4.5)).fill() }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = listening ? "Halen EQ — listening" : "Halen EQ"
        return img
    }
}

struct Ring: View {
    var value: Int?
    var dimension: Insights.Dimension
    var size: CGFloat = 56
    var showLabel = true
    var body: some View { DotRing(value: value, label: showLabel ? dimension.rawValue : nil, size: size, color: Palette.color(dimension)) }
}

struct Rings: View {
    var card: (Insights.Dimension) -> Int?
    var size: CGFloat = 56
    var body: some View {
        HStack(spacing: size * 0.4) {
            ForEach(Insights.Dimension.allCases, id: \.self) { Ring(value: card($0), dimension: $0, size: size) }
        }
    }
}

struct MoodBadge: View {
    let tone: Double?
    let laughs: Int
    var body: some View {
        if let mood = Tone.mood(tone) {
            HStack(spacing: 8) {
                DotFace(mood: mood, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    DotLabel(mood.label, size: 11).foregroundStyle(.primary)
                    if laughs > 0 { Text("laughed \(laughs)×").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .help("Tone of your own words (on-device sentiment) and your laughs. Shown for reflection — never scored.")
        }
    }
}

/// App icon for the call app (Zoom, Teams…) — a small, very Mac touch.
struct SourceIcon: View {
    let bundleID: String?
    var size: CGFloat = 18
    var body: some View {
        Group {
            if let id = bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                Image(systemName: "person.wave.2.fill").resizable().scaledToFit().foregroundStyle(.secondary).padding(2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Words for the "how did it go?" scale.
enum Rating {
    static func word(_ r: Double) -> String {
        switch r { case ..<0.2: "Rough"; case ..<0.4: "Mixed"; case ..<0.6: "Okay"; case ..<0.8: "Good"; default: "Great" }
    }
}

extension Date {
    var dayTitle: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        return formatted(.dateTime.weekday(.wide).day().month())
    }
}
