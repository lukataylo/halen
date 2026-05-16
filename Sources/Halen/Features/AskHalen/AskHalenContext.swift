import AppKit
import ApplicationServices

/// What the palette knows about the user's current state when it opens.
/// Captured **before** the palette steals focus — every field is best-effort
/// (a calendar with no events still works, a field with no selection still
/// works) so the user's question always gets some answer.
struct AskHalenContext {
    let appName: String?
    let appBundleId: String?
    /// Process id of the source app at capture time. Used by Insert to verify
    /// the user hasn't ⌘Tabbed away before writing back — otherwise the AX
    /// write lands in a no-longer-foreground app and the user can't see what
    /// happened.
    let appPID: pid_t?
    /// AX-selected text in the focused field, if any.
    let selectedText: String?
    /// Paragraph around the caret — useful when the user wants help with what
    /// they were just writing without having to select it first.
    let currentParagraph: String?
    /// First ~2 KB of whatever's on the system clipboard, as long as it's text.
    let clipboardText: String?
    /// The element that was focused when the palette opened. Used by
    /// "Insert at caret" to write back to the source field, not the palette.
    let focusedElement: AXUIElement?

    static let empty = AskHalenContext(appName: nil, appBundleId: nil, appPID: nil,
                                       selectedText: nil, currentParagraph: nil,
                                       clipboardText: nil, focusedElement: nil)

    /// Snapshot the user's current state. Reads AX + frontmost app + clipboard
    /// synchronously — runs in microseconds for healthy apps; a 200 ms cap on
    /// AX reads keeps a hung Electron app from freezing the palette.
    @MainActor
    static func capture(via caretObserver: CaretObserver?) -> AskHalenContext {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let element = caretObserver?.currentElement

        // Cap AX read timeout at 200 ms. The default is several seconds;
        // a hung Electron app or browser tab can otherwise block the
        // hotkey→palette path long enough that the user thinks Halen crashed.
        if let element {
            AXUIElementSetMessagingTimeout(element, 0.2)
        }

        var selection: String?
        var paragraph: String?
        if let element {
            // Selected text takes precedence — the user actively highlighted
            // something, which usually means "operate on this".
            if let raw = axReadString(element, kAXSelectedTextAttribute), !raw.isEmpty {
                selection = raw
            }
            if let full = axReadString(element, kAXValueAttribute) {
                let caret = axReadSelectedRange(element)?.location ?? 0
                let para = paragraphAroundCaret(text: full, caretOffset: caret)
                if !para.isEmpty {
                    paragraph = para
                }
            }
        }

        var clipboard: String?
        if let str = NSPasteboard.general.string(forType: .string), !str.isEmpty {
            // Cap at 2 KB — much more than that bloats the prompt and won't
            // help the model. Anyone pasting more should select-and-ask
            // instead, which goes through `selection` above.
            clipboard = String(str.prefix(2048))
        }

        return AskHalenContext(
            appName: frontApp?.localizedName,
            appBundleId: frontApp?.bundleIdentifier,
            appPID: frontApp?.processIdentifier,
            selectedText: selection,
            currentParagraph: paragraph,
            clipboardText: clipboard,
            focusedElement: element
        )
    }

    /// Build the prompt sent to the inference router. Conservative on system-
    /// prompt verbosity — the 1B fallback model is sensitive to long preambles
    /// and Apple FM has a 4 K context to spend on actual content.
    static func buildPrompt(question: String, context: AskHalenContext) -> String {
        var sections: [String] = []

        var contextBlock = "Context:\n"
        if let appName = context.appName {
            contextBlock += "- The user is in \(appName).\n"
        }
        if let selection = context.selectedText, !selection.isEmpty {
            contextBlock += "- They have selected the following text:\n\"\"\"\n\(selection)\n\"\"\"\n"
        } else if let paragraph = context.currentParagraph, !paragraph.isEmpty {
            contextBlock += "- The paragraph around their cursor:\n\"\"\"\n\(paragraph)\n\"\"\"\n"
        }
        if context.selectedText == nil,
           let clipboard = context.clipboardText, !clipboard.isEmpty {
            // Only include clipboard if there's no selection — the two are
            // usually the same thing and duplicating wastes context.
            contextBlock += "- Their recent clipboard:\n\"\"\"\n\(clipboard)\n\"\"\"\n"
        }
        if contextBlock != "Context:\n" {
            sections.append(contextBlock)
        }

        sections.append(
            """
            You are Halen, a concise local AI assistant. Answer the user's question \
            directly. If they're asking you to rewrite or transform text, output \
            ONLY the rewritten result with no preamble.

            Question: \(question)
            """
        )

        return sections.joined(separator: "\n\n")
    }
}
