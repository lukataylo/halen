import AppKit
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.dadiani.halen", category: "font")

enum FontManager {
    private static var registered = false

    static func registerFonts() {
        guard !registered else { return }
        registered = true

        guard let url = Bundle.module.url(forResource: "MatrixSansScreen-Regular", withExtension: "ttf") else {
            log.warning("MatrixSansScreen-Regular.ttf not found in bundle")
            return
        }

        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            log.info("Registered MatrixSansScreen-Regular font")
        } else {
            log.error("Failed to register font: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
    }

    /// The custom font name as registered by CoreText (must match the font's family name)
    static let fontName = "Matrix Sans Screen"
}

// MARK: - SwiftUI Font Extension

extension Font {
    /// MatrixSans Screen at the given size and weight.
    static func matrix(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(FontManager.fontName, size: size).weight(weight)
    }

    /// MatrixSans Screen monospaced-style for stats/codes.
    static func matrixMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(FontManager.fontName, size: size).weight(weight)
    }
}
