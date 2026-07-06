import Foundation
import SwiftUI
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import HalenPluginAPI

/// Prompt Polish — select the prompt you're about to send to an LLM, press
/// ⌃⌥⌘P, and Halen makes targeted **word-level edits** to it in place so a modern
/// model (Gemini-, GPT-, Claude-class) answers it well.
///
/// This is the applied side of the `research/register-lab` study: word choice
/// steers a model's output, so the cleanest way to improve a prompt is to fix
/// the *words* — replace vague terms with precise ones, swap register-marking
/// words to set tone, name the format/length/audience — rather than rewrite the
/// whole thing. The four modes cover the most common prompting tasks: improving
/// a vague prompt, setting tone/register, summarise/rewrite asks, and coding.
///
/// All work runs on Halen's existing on-device models via the inference router —
/// no cloud, consistent with Halen's privacy promise. The mode-specific
/// instructions encode current prompt-engineering practice (role, specificity,
/// explicit format/audience, tone-marking word choice), which is what the
/// modern models reward.
@MainActor
public final class PromptPolish: HalenPlugin {
    public static let pluginManifest = PluginManifest(
        id: "com.halen.prompt-polish", name: "Prompt Polish",
        summary: "Rewrite the selected prompt in place, tuned for LLMs.",
        version: "0.4.0",
        events: [],
        capabilities: [.observeText, .insertText, .hotkeys, .notifications, .clipboard],
        icon: "wand.and.stars", category: .writing)

    public var manifest: PluginManifest { Self.pluginManifest }

    private let context: PluginContext

    /// In-flight polish Task. A second ⌃⌥⌘P supersedes a slow first one.
    private var inflight: Task<Void, Never>?

    // MARK: - Persisted settings

    /// Which transform ⌃⌥⌘P applies. Persisted in UserDefaults; the detail view
    /// edits it via `@AppStorage(defaultModeKey)`.
    enum PolishMode: String, CaseIterable, Sendable {
        case improve
        case tone
        case summarize
        case coding

        var label: String {
            switch self {
            case .improve:   return "Improve"
            case .tone:      return "Set tone"
            case .summarize: return "Summarise"
            case .coding:    return "Coding"
            }
        }

        var systemImage: String {
            switch self {
            case .improve:   return "sparkles"
            case .tone:      return "slider.horizontal.3"
            case .summarize: return "text.append"
            case .coding:    return "chevron.left.forwardslash.chevron.right"
            }
        }

        var blurb: String {
            switch self {
            case .improve:
                return "Replaces vague words with precise ones, strengthens weak verbs, and adds the missing specifics (format, length, audience)."
            case .tone:
                return "Swaps register-marking words and adds a tone instruction so the answer comes out in the voice you pick."
            case .summarize:
                return "Pins down a concrete length and format (e.g. 3 bullets, one sentence) and a precise action verb."
            case .coding:
                return "Names the language/version, states the desired output and constraints, and turns 'fix this' into a precise ask."
            }
        }
    }

    /// Target register for `.tone` mode. Drawn from the register-lab findings:
    /// these are the registers a single word-swap can reliably steer toward.
    enum ToneTarget: String, CaseIterable, Sendable {
        case professional
        case casual
        case academic
        case concise

        var label: String {
            switch self {
            case .professional: return "Professional"
            case .casual:       return "Casual"
            case .academic:     return "Academic"
            case .concise:      return "Concise"
            }
        }

        /// Concrete word-choice guidance handed to the model for this register.
        var clause: String {
            switch self {
            case .professional:
                return "a professional, business register — prefer words like \"hello\", \"team\", \"discuss\", \"excellent\", \"regarding\"; avoid slang and filler"
            case .casual:
                return "a casual, friendly register — natural contractions and plain words like \"hey\", \"folks\", \"chat about\", \"great\"; warm but not sloppy"
            case .academic:
                return "an academic, analytical register — precise words like \"individuals\", \"demonstrate\", \"significant\", \"assess\", \"furthermore\""
            case .concise:
                return "a concise, direct register — short words, no hedging or filler, imperative verbs"
            }
        }
    }

    static let defaultModeKey = "halen.prompt-polish.defaultMode"
    static let toneTargetKey  = "halen.prompt-polish.toneTarget"

    static var defaultMode: PolishMode {
        PolishMode(rawValue: UserDefaults.standard.string(forKey: defaultModeKey) ?? "")
            ?? .improve
    }
    static var toneTarget: ToneTarget {
        ToneTarget(rawValue: UserDefaults.standard.string(forKey: toneTargetKey) ?? "")
            ?? .professional
    }

    public init(context: PluginContext) {
        self.context = context
    }

    public func start() {
        registerHotkey()
    }

    public func stop() {
        context.hotkeys?.unregisterAll()
        inflight?.cancel()
        inflight = nil
    }

    public func makeDetailView() -> AnyView {
        AnyView(PromptPolishDetailView())
    }

    // MARK: - Hotkey (⌃⌥⌘P)

    /// Register ⌃⌥⌘P through the host's hotkey service. Three modifiers so it
    /// can't collide with a browser/app shortcut; the host handles conflict
    /// registration and the Input Monitoring prompt.
    private func registerHotkey() {
        let ok = context.hotkeys?.register(
            id: "polish", keyCode: UInt32(kVK_ANSI_P),
            modifiers: [.control, .option, .command]
        ) { [weak self] in
            self?.fire()
        } ?? false
        Log.info("PromptPolish: ⌃⌥⌘P registered=\(ok)")
    }

    /// Cancel any prior polish, kick off a new one against the current selection.
    private func fire() {
        inflight?.cancel()
        inflight = polishSelection(mode: Self.defaultMode, tone: Self.toneTarget)
    }

    // MARK: - Polish

    /// Rewrite the selected prompt in place with `mode`. No-op (with a nudge)
    /// when nothing is selected — the hotkey only acts on an active highlight,
    /// matching ⌃⌥R's contract. Mirrors SnippetExpander's placeholder + stream
    /// write-back so it survives the user editing the field mid-call.
    @discardableResult
    private func polishSelection(mode: PolishMode, tone: ToneTarget) -> Task<Void, Never>? {
        guard let element = context.text?.focusedElement else {
            Log.info("PromptPolish: ⌃⌥⌘P — no focused element")
            return nil
        }
        guard let cfRange = axReadSelectedRange(element), cfRange.length > 0 else {
            notify(body: "Select the prompt you want to polish, then press ⌃⌥⌘P.")
            return nil
        }
        let selected = axReadSelectedText(element)
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notify(body: "Select the prompt you want to polish, then press ⌃⌥⌘P.")
            return nil
        }
        // The rewrite is capped at `maxTokens` below (~600 tokens ≈ a couple
        // thousand characters). A selection longer than the model can return
        // would come back truncated and then silently overwrite the user's
        // original prompt — so refuse it rather than destroy text.
        guard selected.count <= 2000 else {
            notify(body: "That selection is long. Select a shorter prompt (under ~2000 characters) to polish.")
            return nil
        }
        let selRange = NSRange(location: cfRange.location, length: cfRange.length)
        let prompt = instruction(for: mode, tone: tone, userPrompt: selected)
        let request = InferenceRequest(prompt: prompt, tier: .medium, maxTokens: 600,
                                       temperature: 0.3, taskKind: .generation)
        Log.info("PromptPolish: polishing \(selected.count)-char selection (mode=\(mode.rawValue))")
        return runStreamingReplace(
            range: selRange,
            in: element,
            request: request,
            restoreText: selected,
            announcement: "Polished prompt"
        )
    }

    /// Build the instruction sent to the on-device model. The user's prompt is
    /// the *content to edit*, never something to answer — every mode ends with
    /// "output only the rewritten prompt" so the model returns an edited prompt,
    /// not a response to it.
    private func instruction(for mode: PolishMode, tone: ToneTarget, userPrompt: String) -> String {
        let task: String
        switch mode {
        case .improve:
            task = """
            Rewrite the PROMPT so a capable LLM will answer it well. Make targeted, \
            word-level edits: replace vague words (some, stuff, things, good, a few, \
            better) with specific ones; strengthen weak verbs (make → write/generate/\
            analyse); add a clear format, length, and audience only when they are \
            implied; and cut filler. Preserve the user's intent and topic. Do NOT \
            answer the prompt.
            """
        case .tone:
            task = """
            Rewrite the PROMPT so the model's answer comes out in \(tone.clause). \
            Do this mainly through word choice — swap register-marking words and add \
            one short, explicit tone instruction. Keep the actual request unchanged. \
            Do NOT answer the prompt.
            """
        case .summarize:
            task = """
            The PROMPT is a request to summarise or rewrite some text. Make it \
            well-specified: set a concrete length or format (e.g. "in 3 bullet \
            points", "in one sentence", "under 100 words"), name the audience if \
            implied, and use a precise verb (summarise / condense / rewrite / \
            paraphrase). Keep any reference to the user's source text intact. Do NOT \
            perform the summary.
            """
        case .coding:
            task = """
            The PROMPT is a coding or technical request. Improve it for a code model: \
            name the language and version if implied, state the desired output (working \
            code, only the diff, with or without explanation), add constraints (no extra \
            libraries, performance, style), and turn vague asks ("fix this", "make it \
            better") into precise ones ("identify and fix the bug causing X"). Keep the \
            user's code or context intact. Do NOT write the solution.
            """
        }
        return """
        You are a prompt engineer. \(task)
        Output ONLY the rewritten prompt — no preamble, no quotes, no explanation.

        PROMPT:
        \"\"\"
        \(userPrompt)
        \"\"\"
        """
    }

    // MARK: - Streaming write-back
    //
    // Adapted from SnippetExpander's proven `runPlaceholderInference`: drop a
    // `[…]` placeholder over the selection for instant feedback, stream the
    // model's output into it (re-locating each time in case the user edits the
    // field mid-call), then write the cleaned final text — or restore the
    // original on an empty/failed response. PromptPolish is hotkey-only and
    // doesn't subscribe to text events, so it needs no self-edit suppression.

    @discardableResult
    private func runStreamingReplace(
        range: NSRange,
        in element: AXUIElement,
        request: InferenceRequest,
        restoreText: String,
        announcement: String
    ) -> Task<Void, Never> {
        let placeholder = "[…]"
        _ = context.text?.replaceRange(range, with: placeholder, in: element,
                                       describedAs: nil) ?? false
        let placeholderRange = NSRange(location: range.location,
                                       length: (placeholder as NSString).length)

        // Anchor the overlay's busy indicator to the placeholder's bounds.
        let overlayAnchor: Event.CaretRect? = {
            guard let axRect = axReadBounds(element, range: CFRange(
                location: placeholderRange.location, length: placeholderRange.length)) else {
                return nil
            }
            let cocoa = axRectToCocoa(axRect)
            return .init(x: cocoa.minX, y: cocoa.minY, width: cocoa.width, height: cocoa.height)
        }()

        return Task { @MainActor [context, overlayAnchor, weak self] in
            let source = "prompt-polish"
            context.events.publish(.inferenceActivity(.init(
                phase: .started, source: source, anchor: overlayAnchor, timestamp: Date())))
            defer {
                context.events.publish(.inferenceActivity(.init(
                    phase: .finished, source: source, timestamp: Date())))
            }

            let start = Date()
            var lastWritten = placeholder
            var writtenRange = placeholderRange

            @MainActor func flush(_ snapshot: String) -> Bool {
                guard let self,
                      let target = self.locatePlaceholder(lastWritten, expectedAt: writtenRange, in: element)
                else { return false }
                guard context.text?.replaceRange(target, with: snapshot, in: element,
                                                 describedAs: nil) == true else {
                    return false
                }
                lastWritten = snapshot
                writtenRange = NSRange(location: target.location, length: (snapshot as NSString).length)
                return true
            }

            var latest = ""
            var lastFlush = Date.distantPast
            do {
                for try await snapshot in context.inference.stream(request) {
                    latest = snapshot
                    guard !snapshot.isEmpty else { continue }
                    // Throttle AX writes to ~11 fps — a per-token write storm
                    // into a foreign field is janky. First snapshot always
                    // passes (seed is .distantPast) so it feels instant.
                    if Date().timeIntervalSince(lastFlush) < 0.09 { continue }
                    lastFlush = Date()
                    if !flush(snapshot) {
                        Log.warn("PromptPolish: streamed text gone from field — stopping")
                        return
                    }
                }
                let cleaned = latest.unwrappedModelText
                guard let self,
                      let writeRange = self.locatePlaceholder(lastWritten, expectedAt: writtenRange, in: element)
                else {
                    Log.warn("PromptPolish: streamed text gone from field — skipping final write")
                    return
                }
                guard !cleaned.isEmpty else {
                    Log.warn("PromptPolish: empty response — restoring original")
                    _ = context.text?.replaceRange(writeRange, with: restoreText, in: element,
                                                   describedAs: nil) ?? false
                    return
                }
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                Log.info("PromptPolish: completed (\(elapsed)ms) len=\(cleaned.count)")
                if context.text?.replaceRange(writeRange, with: cleaned, in: element,
                                              describedAs: announcement) != true {
                    Log.warn("PromptPolish: final AX write failed — target stale or unsupported")
                }
            } catch is CancellationError {
                // Superseded by a newer ⌃⌥⌘P — leave the field as-is.
            } catch {
                Log.warn("PromptPolish: failed: \(error)")
                guard let self,
                      let writeRange = self.locatePlaceholder(lastWritten, expectedAt: writtenRange, in: element)
                else { return }
                _ = context.text?.replaceRange(writeRange, with: restoreText, in: element,
                                               describedAs: nil) ?? false
            }
        }
    }

    /// Re-find `placeholder` in the (possibly-edited) field, picking the
    /// occurrence nearest the expected location. Returns the expected range if
    /// the field can't be read, or nil if the text is gone (user deleted it).
    private func locatePlaceholder(_ placeholder: String, expectedAt expected: NSRange,
                                   in element: AXUIElement?) -> NSRange? {
        guard let target = element ?? context.text?.focusedElement,
              let current = axReadString(target, kAXValueAttribute) else {
            return expected
        }
        let ns = current as NSString
        var searchFrom = 0
        var best: NSRange?
        while searchFrom < ns.length {
            let found = ns.range(of: placeholder, options: [],
                                 range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            guard found.location != NSNotFound else { break }
            if best == nil ||
                abs(found.location - expected.location) < abs(best!.location - expected.location) {
                best = found
            }
            searchFrom = found.location + max(1, found.length)
        }
        return best
    }

    /// Transient toast — used for the "select a prompt first" nudge. No-ops
    /// when the notifications grant is missing.
    private func notify(body: String) {
        context.ui?.toast(title: "Prompt Polish", body: body)
    }
}
