import SwiftUI

// MARK: - Claude Code Icon (from official SVG path data)

struct ClaudeCodeIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24.0
        let ox = rect.minX + (rect.width - 24 * s) / 2
        let oy = rect.minY + (rect.height - 24 * s) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }
        var path = Path()
        // Body
        path.move(to: p(20.998, 10.949))
        path.addLine(to: p(24, 10.949)); path.addLine(to: p(24, 14.051))
        path.addLine(to: p(21, 14.051)); path.addLine(to: p(21, 17.079))
        path.addLine(to: p(19.513, 17.079)); path.addLine(to: p(19.513, 20))
        path.addLine(to: p(18, 20)); path.addLine(to: p(18, 17.079))
        path.addLine(to: p(16.513, 17.079)); path.addLine(to: p(16.513, 20))
        path.addLine(to: p(15, 20)); path.addLine(to: p(15, 17.079))
        path.addLine(to: p(9, 17.079)); path.addLine(to: p(9, 20))
        path.addLine(to: p(7.488, 20)); path.addLine(to: p(7.488, 17.079))
        path.addLine(to: p(6, 17.079)); path.addLine(to: p(6, 20))
        path.addLine(to: p(4.487, 20)); path.addLine(to: p(4.487, 17.079))
        path.addLine(to: p(3, 17.079)); path.addLine(to: p(3, 14.05))
        path.addLine(to: p(0, 14.05)); path.addLine(to: p(0, 10.95))
        path.addLine(to: p(3, 10.95)); path.addLine(to: p(3, 5))
        path.addLine(to: p(20.998, 5))
        path.closeSubpath()
        // Left eye (even-odd cutout)
        path.move(to: p(6, 10.949))
        path.addLine(to: p(7.488, 10.949)); path.addLine(to: p(7.488, 8.102))
        path.addLine(to: p(6, 8.102)); path.closeSubpath()
        // Right eye
        path.move(to: p(16.51, 10.949))
        path.addLine(to: p(18, 10.949)); path.addLine(to: p(18, 8.102))
        path.addLine(to: p(16.51, 8.102)); path.closeSubpath()
        return path
    }
}

// MARK: - NotchOwl Icon (from NotchOwl.svg)

struct NotchOwlIcon: Shape {
    private static let svgData = "M137.503,858.278C134.242,858.215 132.896,858.768 132.988,855.502C133.034,853.872 133.069,853.881 133.068,849.502C133.057,788.836 133.044,788.838 133.075,786.487C133.098,784.747 132.905,784.369 134.567,783.81C134.842,783.718 142.252,783.789 145.504,783.771C148.788,783.752 148.752,782.777 148.75,779.498C148.745,771.658 148.703,700.64 148.779,681.501C148.861,660.587 148.474,659.257 149.502,658.502C150.401,657.842 159.285,658.323 161.477,658.174C163.643,658.027 163.88,657.675 163.923,655.514C164.155,643.595 163.756,643.37 164.594,642.606C165.269,641.991 168.019,642.118 170.492,642.112C172.506,642.107 172.483,642.121 174.492,642.113C177.949,642.099 179.734,642.528 179.773,639.51C179.905,629.392 179.771,629.407 179.815,628.53C179.94,626.04 181.646,626.785 192.503,626.697C196.315,626.667 196.299,626.726 199.501,626.706C204.151,626.677 205.087,626.918 205.919,625.787C206.676,624.757 206.096,613.93 206.303,612.473C206.327,612.304 206.504,611.061 207.583,610.767C207.744,610.723 207.748,610.645 295.498,610.658C306.111,610.659 306.632,610.512 307.012,611.676C307.346,612.702 306.869,624.347 307.334,625.578C307.868,626.996 311.187,626.693 313.497,626.699C331.979,626.747 332.085,626.482 332.815,627.024C333.955,627.871 333.717,628.072 333.741,629.493C333.921,640.42 333.44,640.663 334.419,641.592C335.193,642.326 338.753,642.102 346.503,642.097C350.32,642.094 349.528,643.692 349.561,647.499C349.631,655.631 349.338,657.567 350.67,658.037C351.501,658.331 361.122,658.133 362.528,658.185C362.729,658.193 364.357,658.253 364.718,659.422C365.006,660.354 364.776,733.127 364.839,747.497C364.99,782.023 364.364,782.419 365.592,783.382C366.568,784.148 374.734,783.666 378.48,783.768C381.166,783.841 380.803,785.965 380.798,787.5C380.692,821.521 380.986,821.497 380.783,855.503C380.773,857.198 380.991,857.553 379.418,858.163C378.692,858.444 366.518,857.847 365.59,858.63C364.368,859.662 364.995,859.999 364.897,871.511C364.874,874.213 364.202,874.343 361.499,874.349C350.986,874.374 350.81,874.289 350.055,875.128C349.179,876.1 349.682,880.144 349.548,887.501C349.504,889.945 348.941,890.106 346.495,890.106C335.194,890.109 334.454,889.949 333.808,890.756C332.817,891.994 333.867,903.808 333.155,905.33C332.591,906.536 330.643,906.264 324.501,906.272C309.251,906.291 308.626,906.093 307.894,906.862C307.36,907.423 307.328,909.281 307.324,909.496C307.111,921.996 307.526,921.974 307.3,934.491C307.279,935.666 307.431,935.802 306.525,936.541C306.055,936.923 302.384,936.852 300.496,936.85C288.663,936.833 288.467,936.9 287.927,936.161C287.203,935.171 287.626,926.942 287.516,924.499C287.508,924.322 287.444,922.899 286.484,922.537C285.9,922.317 285.894,922.319 252.5,922.304C227.876,922.293 227.881,922.378 227.505,922.512C225.724,923.146 226.579,923.87 226.333,934.489C226.305,935.667 226.439,935.798 225.523,936.538C225.017,936.947 220.97,936.846 220.495,936.846C207.449,936.83 207.315,936.977 206.672,936.328C206.064,935.713 206.168,935.57 206.148,920.499C206.133,908.375 206.508,906.757 204.538,906.326C204.006,906.209 183.647,906.31 182.51,906.284C181.338,906.258 181.212,906.437 180.439,905.543C179.484,904.44 180.896,891.842 179.434,890.58C178.292,889.595 167.084,890.486 165.333,889.972C164.184,889.635 164.011,888.604 163.984,888.443C163.704,886.775 164.598,875.781 163.308,874.761C162.264,873.935 152.309,874.538 150.52,874.337C150.368,874.32 149.214,874.19 148.896,873.34C148.474,872.214 148.949,860.784 148.521,859.493C148.057,858.091 147.418,858.265 137.503,858.278ZM337.496,744.935C338.225,744.96 345.378,745.206 346.613,744.726C347.931,744.214 347.565,743.556 347.617,728.5C347.632,724.055 347.566,676.549 347.562,676.496C347.329,673.705 345.812,674.352 335.502,674.33C332.901,674.325 332.289,674.035 332.233,671.51C331.968,659.721 332.435,659.441 331.425,658.62C330.711,658.039 324.231,658.379 306.502,658.298C304.1,658.287 277.702,658.166 276.476,658.331C274.888,658.543 274.622,659.701 274.591,660.505C274.556,661.384 274.654,661.371 274.613,671.503C274.601,674.55 273.531,674.256 270.496,674.284C266.152,674.326 263.461,673.778 263.281,676.476C263.097,679.22 263.762,683.643 262.678,684.693C262.093,685.26 261.969,685.381 252.514,685.204C249.78,685.153 250.012,684.226 249.96,681.502C249.904,678.579 250.706,674.934 248.514,674.431C247.882,674.286 240.858,674.332 240.56,674.224C238.841,673.602 239.058,673.02 239.063,662.501C239.063,662.248 239.065,659.981 238.823,659.342C238.334,658.043 237.736,658.281 226.5,658.288C200.735,658.302 200.74,658.281 198.5,658.286C182.255,658.319 182.195,658.329 181.675,658.728C180.772,659.421 181.035,661.631 181.005,670.489C180.995,673.418 180.919,674.252 178.493,674.321C174.928,674.421 167.698,673.916 166.688,674.73C165.901,675.363 166.09,675.57 166.046,692.496C165.966,723.536 165.953,727.136 166.058,733.497C166.068,734.063 166.057,740.86 166.056,741.5C166.056,741.738 166.052,743.912 166.576,744.419C167.447,745.261 174.743,744.892 178.485,744.937C181.668,744.975 180.93,746.327 180.931,749.497C180.932,750.929 180.938,767.269 180.983,767.399C181.369,768.497 182.294,768.698 182.449,768.732C183.473,768.955 224.317,768.572 225.327,768.944C226.814,769.491 226.225,772.967 226.309,780.504C226.353,784.465 228.024,783.733 233.501,783.732C285.654,783.723 285.698,783.816 286.498,783.495C287.906,782.93 287.432,780.118 287.484,771.5C287.503,768.202 289.033,768.828 294.501,768.805C295.87,768.799 330.305,768.808 330.539,768.773C332.367,768.492 332.244,766.702 332.248,766.49C332.261,765.764 332.154,746.915 332.26,746.444C332.618,744.854 334.358,745.016 337.496,744.935ZM212.498,728.042C204.752,727.839 195.695,728.6 194.653,727.366C194.161,726.784 194.179,726.677 194.205,699.496C194.208,696.603 194.681,696.176 197.502,696.178C199.262,696.179 217.429,696.192 219.496,696.183C222.585,696.169 225.376,695.81 225.899,697.313C226.276,698.394 226.076,698.433 226.097,724.496C226.097,724.652 226.098,726.338 226.07,726.442C225.434,728.792 224.403,727.671 212.498,728.042ZM245.494,744.922C241.757,744.922 241.78,744.941 241.458,744.922C238.964,744.777 239.402,742.797 239.434,737.5C239.481,729.793 238.93,728.012 241.523,727.874C241.723,727.863 268.328,727.87 270.493,727.881C272.83,727.892 273.583,727.282 274.159,729.545C274.358,730.327 274.212,741.452 274.198,742.487C274.183,743.652 274.397,743.78 273.55,744.566C272.418,745.617 264.76,744.224 263.737,745.665C262.967,746.751 263.588,757.129 263.353,758.472C262.97,760.652 259.692,759.986 257.494,759.974C253.272,759.951 253.11,759.984 252.483,759.978C250.763,759.963 250.369,760.098 249.937,758.441C249.894,758.278 249.957,748.574 249.915,747.481C249.797,744.395 248.591,744.988 245.494,744.922ZM294.502,728.045C291.003,728.056 288.383,728.152 287.781,727.288C287.232,726.5 287.49,726.394 287.364,701.502C287.353,699.179 286.8,696.398 289.468,696.217C289.93,696.186 314.373,696.145 316.513,696.188C318.062,696.219 319.081,696.479 319.168,698.523C319.22,699.755 319.203,723.39 319.178,725.489C319.145,728.229 318.237,728.038 315.498,728.052C313.492,728.061 313.506,727.997 311.498,727.994C310.139,727.992 296.845,727.972 294.502,728.045Z"

    // Parsed once at startup, cached for all subsequent renders
    private static let parsed: [(cmd: UInt8, nums: [CGFloat])] = {
        var result: [(cmd: UInt8, nums: [CGFloat])] = []
        let scalars = svgData.unicodeScalars
        var i = scalars.startIndex
        while i < scalars.endIndex {
            let c = scalars[i]
            if c == "M" || c == "C" || c == "L" || c == "Z" {
                let cmd = UInt8(ascii: c)
                i = scalars.index(after: i)
                var nums: [CGFloat] = []
                while i < scalars.endIndex {
                    let ch = scalars[i]
                    if ch == "M" || ch == "C" || ch == "L" || ch == "Z" { break }
                    if ch == "-" || (ch >= "0" && ch <= "9") {
                        var numEnd = scalars.index(after: i)
                        while numEnd < scalars.endIndex {
                            let d = scalars[numEnd]
                            if d >= "0" && d <= "9" || d == "." { numEnd = scalars.index(after: numEnd) }
                            else { break }
                        }
                        if let v = Double(String(scalars[i..<numEnd])) { nums.append(CGFloat(v)) }
                        i = numEnd
                    } else { i = scalars.index(after: i) }
                }
                result.append((cmd, nums))
            } else { i = scalars.index(after: i) }
        }
        return result
    }()

    func path(in rect: CGRect) -> Path {
        let ox: CGFloat = 132.9, oy: CGFloat = 610.5
        let sw: CGFloat = 248.3, sh: CGFloat = 326.5
        let scale = min(rect.width / sw, rect.height / sh)
        let dx = rect.minX + (rect.width - sw * scale) / 2
        let dy = rect.minY + (rect.height - sh * scale) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: dx + (x - ox) * scale, y: dy + (y - oy) * scale)
        }
        var path = Path()
        for entry in Self.parsed {
            let n = entry.nums
            switch entry.cmd {
            case 0x4D: path.move(to: p(n[0], n[1]))
            case 0x43:
                var i = 0
                while i + 5 < n.count {
                    path.addCurve(to: p(n[i+4], n[i+5]), control1: p(n[i], n[i+1]), control2: p(n[i+2], n[i+3]))
                    i += 6
                }
            case 0x4C:
                var i = 0
                while i + 1 < n.count { path.addLine(to: p(n[i], n[i+1])); i += 2 }
            case 0x5A: path.closeSubpath()
            default: break
            }
        }
        return path
    }
}

// MARK: - Active Provider Icon

let owlBlue = Color(red: 131.0/255, green: 183.0/255, blue: 233.0/255)

struct ActiveProviderIcon: View {
    let session: AgentSession?

    var body: some View {
        if let session = session, session.isActive {
            providerIcon(for: session.providerID, color: session.providerAccentColor)
        } else {
            NotchOwlIcon()
                .fill(owlBlue, style: FillStyle(eoFill: true))
        }
    }

    @ViewBuilder
    func providerIcon(for id: ProviderID, color: Color) -> some View {
        if id == .claude || id == .embeddedTerminal {
            ClaudeCodeIcon()
                .fill(color, style: FillStyle(eoFill: true))
        } else {
            // All other providers use their symbolName from the registry
            let symbolName = ProviderRegistry.shared.descriptor(for: id)?.symbolName ?? "puzzlepiece"
            Image(systemName: symbolName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(color)
        }
    }
}

// MARK: - Provider Mini Icon (for card headers)

struct ProviderMiniIcon: View {
    let session: ClaudeSession

    var body: some View {
        if session.providerID == .claude || session.providerID == .embeddedTerminal {
            ClaudeCodeIcon()
                .fill(session.providerAccentColor, style: FillStyle(eoFill: true))
        } else {
            let symbolName = ProviderRegistry.shared.descriptor(for: session.providerID)?.symbolName ?? "puzzlepiece"
            Image(systemName: symbolName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(session.providerAccentColor)
        }
    }
}

// MARK: - NotchBar Icon (for header / onboarding)

struct NotchBarIcon: View {
    var body: some View {
        NotchOwlIcon()
            .fill(owlBlue, style: FillStyle(eoFill: true))
    }
}

// MARK: - Geometric Icons (matched to Matrix Sans)
//
// Clean, geometric strokes that pair with the Matrix Sans typeface.
// All drawn on a 12×12 unit grid so they scale uniformly via .frame().

struct MatrixChevronUp: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX, cy = rect.midY
        let hw = w * 0.35, hh = h * 0.2
        var p = Path()
        p.move(to: CGPoint(x: cx - hw, y: cy + hh))
        p.addLine(to: CGPoint(x: cx, y: cy - hh))
        p.addLine(to: CGPoint(x: cx + hw, y: cy + hh))
        return p
    }
}

struct MatrixChevronDown: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX, cy = rect.midY
        let hw = w * 0.35, hh = h * 0.2
        var p = Path()
        p.move(to: CGPoint(x: cx - hw, y: cy - hh))
        p.addLine(to: CGPoint(x: cx, y: cy + hh))
        p.addLine(to: CGPoint(x: cx + hw, y: cy - hh))
        return p
    }
}

struct MatrixChevronRight: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let hw = rect.width * 0.2, hh = rect.height * 0.35
        var p = Path()
        p.move(to: CGPoint(x: cx - hw, y: cy - hh))
        p.addLine(to: CGPoint(x: cx + hw, y: cy))
        p.addLine(to: CGPoint(x: cx - hw, y: cy + hh))
        return p
    }
}

struct MatrixClose: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = min(rect.width, rect.height) * 0.25
        let r = rect.insetBy(dx: inset, dy: inset)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.move(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        return p
    }
}

struct MatrixPlus: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = min(rect.width, rect.height) * 0.2
        let r = rect.insetBy(dx: inset, dy: inset)
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        return p
    }
}

struct MatrixPin: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let cx = rect.midX, cy = rect.midY
        var p = Path()
        // Diamond head
        let hs = s * 0.28
        p.move(to: CGPoint(x: cx, y: cy - hs * 1.3))
        p.addLine(to: CGPoint(x: cx + hs, y: cy - hs * 0.15))
        p.addLine(to: CGPoint(x: cx, y: cy + hs * 0.3))
        p.addLine(to: CGPoint(x: cx - hs, y: cy - hs * 0.15))
        p.closeSubpath()
        // Stem
        p.move(to: CGPoint(x: cx, y: cy + hs * 0.3))
        p.addLine(to: CGPoint(x: cx, y: cy + s * 0.4))
        return p
    }
}

struct MatrixBrain: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let cx = rect.midX, cy = rect.midY
        let r = s * 0.4
        var p = Path()
        // Simplified brain: two bumpy lobes
        p.addEllipse(in: CGRect(x: cx - r, y: cy - r * 0.9, width: r * 1.1, height: r * 1.8))
        p.addEllipse(in: CGRect(x: cx - r * 0.1, y: cy - r * 0.9, width: r * 1.1, height: r * 1.8))
        return p
    }
}

struct MatrixTerminal: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = min(rect.width, rect.height) * 0.15
        let r = rect.insetBy(dx: inset, dy: inset)
        var p = Path()
        // Prompt chevron >_
        let promptX = r.minX + r.width * 0.15
        let promptMidY = r.midY - r.height * 0.05
        p.move(to: CGPoint(x: promptX, y: promptMidY - r.height * 0.2))
        p.addLine(to: CGPoint(x: promptX + r.width * 0.2, y: promptMidY))
        p.addLine(to: CGPoint(x: promptX, y: promptMidY + r.height * 0.2))
        // Cursor underscore
        p.move(to: CGPoint(x: promptX + r.width * 0.3, y: promptMidY + r.height * 0.2))
        p.addLine(to: CGPoint(x: promptX + r.width * 0.6, y: promptMidY + r.height * 0.2))
        return p
    }
}

struct MatrixDotsChevronUp: Shape {
    /// An upward chevron composed of individual dots — Nothing UI / LED matrix style.
    /// 5 dots arranged in a V-pointing-up pattern:
    ///       ·          (tip)
    ///     ·   ·        (mid)
    ///   ·       ·      (base)
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let dotR = s * 0.08
        let cx = rect.midX, cy = rect.midY
        let hw = s * 0.34   // half-width of base
        let hh = s * 0.22   // half-height of chevron

        var p = Path()
        // Tip (top center)
        p.addEllipse(in: CGRect(x: cx - dotR, y: cy - hh - dotR, width: dotR * 2, height: dotR * 2))
        // Mid left & right
        p.addEllipse(in: CGRect(x: cx - hw * 0.55 - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))
        p.addEllipse(in: CGRect(x: cx + hw * 0.55 - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))
        // Base left & right
        p.addEllipse(in: CGRect(x: cx - hw - dotR, y: cy + hh - dotR, width: dotR * 2, height: dotR * 2))
        p.addEllipse(in: CGRect(x: cx + hw - dotR, y: cy + hh - dotR, width: dotR * 2, height: dotR * 2))
        return p
    }
}

struct MatrixDotsChevronDown: Shape {
    /// A downward chevron composed of individual dots — Nothing UI style.
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let dotR = s * 0.08
        let cx = rect.midX, cy = rect.midY
        let hw = s * 0.34
        let hh = s * 0.22

        var p = Path()
        // Base left & right (top)
        p.addEllipse(in: CGRect(x: cx - hw - dotR, y: cy - hh - dotR, width: dotR * 2, height: dotR * 2))
        p.addEllipse(in: CGRect(x: cx + hw - dotR, y: cy - hh - dotR, width: dotR * 2, height: dotR * 2))
        // Mid left & right
        p.addEllipse(in: CGRect(x: cx - hw * 0.55 - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))
        p.addEllipse(in: CGRect(x: cx + hw * 0.55 - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))
        // Tip (bottom center)
        p.addEllipse(in: CGRect(x: cx - dotR, y: cy + hh - dotR, width: dotR * 2, height: dotR * 2))
        return p
    }
}

// MARK: - Notch Shape: flat top, rounded bottom corners

struct NotchCollapsedShape: Shape {
    var bottomRadius: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let br = min(bottomRadius, rect.height / 2, rect.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                  radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + br, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + br, y: rect.maxY - br),
                  radius: br, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }
}
