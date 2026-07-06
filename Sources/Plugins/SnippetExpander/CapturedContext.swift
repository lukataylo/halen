import ApplicationServices
import Foundation
import HalenPluginAPI

/// A best-effort snapshot of the user's focused text field, captured
/// **before** any UI steals focus or an async model call starts. Every field
/// is optional by design (a field with no selection still works, an empty
/// clipboard still works) so the caller always gets *some* context to hand
/// the model. Originally the Ask Halen palette's capture; retained here for
/// the email-reply drafter.
struct CapturedFieldContext {
    /// AX-selected text in the focused field, if any.
    let selectedText: String?
    /// Paragraph around the caret — useful when the user wants help with what
    /// they were just writing without having to select it first.
    let currentParagraph: String?
    /// First ~2 KB of whatever's on the system clipboard, as long as it's text.
    let clipboardText: String?
    /// The element that was focused at capture time. Used to write the result
    /// back to the source field, not wherever focus has since moved.
    let focusedElement: AXUIElement?

    /// Snapshot the user's current state. Reads AX + clipboard synchronously —
    /// runs in microseconds for healthy apps; a 200 ms cap on AX reads keeps a
    /// hung Electron app from freezing the caller.
    @MainActor
    static func capture(text: TextService?, clipboard: ClipboardService?) -> CapturedFieldContext {
        let element = text?.focusedElement

        // Cap AX read timeout at 200 ms. The default is several seconds;
        // a hung Electron app or browser tab can otherwise block the
        // hotkey path long enough that the user thinks Halen crashed.
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

        var clipboardText: String?
        if let str = clipboard?.readString(), !str.isEmpty {
            // Cap at 2 KB — much more than that bloats the prompt and won't
            // help the model. Anyone pasting more should select first, which
            // goes through `selection` above.
            clipboardText = String(str.prefix(2048))
        }

        return CapturedFieldContext(
            selectedText: selection,
            currentParagraph: paragraph,
            clipboardText: clipboardText,
            focusedElement: element
        )
    }
}
