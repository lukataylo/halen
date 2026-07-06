import Carbon.HIToolbox
import AppKit
import Foundation

/// Process-wide catalogue of in-process hotkey ids. Held by
/// `HotkeyRegistrar.register(..., id:)` so distinct chords can be
/// distinguished should two plugins ever race on the same callback. The
/// `id` parameter is also a legacy of the Carbon-backed implementation
/// (Carbon's EventHotKeyID disambiguated handlers); kept on the
/// NSEvent-backed path for API compatibility with external plugins
/// allocated ids in the 100+ range via `PluginHost`.
enum HotkeyID: UInt32 {
    case voiceDictation = 1
}

/// A `(keyCode, modifiers)` chord paired with a human label, both as they
/// were when the conflict was detected. The label is the *attempted* owner
/// — the one we rejected; `existingOwner` is the registration that keeps
/// the chord. Surfaced in Settings so the user can disable or rebind.
struct HotkeyConflict: Equatable, Identifiable, Sendable {
    let id = UUID()
    let keyCode: UInt32
    let modifiers: UInt32
    let existingOwner: String
    let attemptedOwner: String

    static func == (lhs: HotkeyConflict, rhs: HotkeyConflict) -> Bool {
        lhs.keyCode == rhs.keyCode
            && lhs.modifiers == rhs.modifiers
            && lhs.existingOwner == rhs.existingOwner
            && lhs.attemptedOwner == rhs.attemptedOwner
    }

    /// Render the chord as a glyph string (e.g. "⌥⌘H"). Carbon's modifier
    /// bitmask values are stable across macOS versions, so this is a pure
    /// lookup. Unknown key codes fall back to their numeric form so the
    /// row stays informative even for obscure keys.
    var displayChord: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s
    }

    private static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_Tab:    return "⇥"
        case kVK_Space:  return "Space"
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        default:         return "key#\(keyCode)"
        }
    }
}

/// Process-wide tracker for hotkey chord ownership. Each `HotkeyRegistrar`
/// instance consults this before claiming a chord; the first one to call
/// `claim` wins and any subsequent attempt with the same `(keyCode,
/// modifiers)` is rejected with a `HotkeyConflict` rather than silently
/// clobbering the existing registration. The conflict list is observable
/// so `SettingsView` can render a warning card.
@MainActor
@Observable
final class HotkeyConflictRegistry {
    /// Singleton — the registry is process-wide because Carbon's hotkey
    /// namespace is process-wide. Per-instance state wouldn't catch the
    /// case where two separate `HotkeyRegistrar` objects (one per plugin)
    /// race on the same chord, which is the entire point of this class.
    static let shared = HotkeyConflictRegistry()

    /// `(keyCode << 32) | modifiers` → owner label. Keyed on the chord
    /// pair so a lookup is O(1); the owner label is what we render in
    /// Settings if a second plugin attempts the same chord.
    @ObservationIgnored private var owners: [UInt64: String] = [:]

    /// Conflicts collected since launch. Two plugins attempting the same
    /// chord at startup append once; the UI uses identity (`UUID`) to
    /// stably render rows even if the array is mutated.
    private(set) var conflicts: [HotkeyConflict] = []

    private init() {}

    /// Claim `chord` for `owner`. Returns `nil` on success and a
    /// `HotkeyConflict` on collision. The existing owner is *not*
    /// displaced — first registration wins, so plugin load order
    /// determines the outcome but the user always sees both labels.
    func claim(keyCode: UInt32, modifiers: UInt32,
               owner: String) -> HotkeyConflict? {
        let key = Self.chordKey(keyCode: keyCode, modifiers: modifiers)
        if let existing = owners[key] {
            // Same owner re-claiming after `release` is fine and ends
            // up here only if `release` wasn't called; recording it as
            // a conflict against itself would be noise.
            if existing == owner { return nil }
            let conflict = HotkeyConflict(
                keyCode: keyCode, modifiers: modifiers,
                existingOwner: existing, attemptedOwner: owner)
            // De-dupe: a plugin that retries on every start() shouldn't
            // grow the conflicts array unboundedly.
            if !conflicts.contains(where: {
                $0.keyCode == conflict.keyCode
                    && $0.modifiers == conflict.modifiers
                    && $0.existingOwner == conflict.existingOwner
                    && $0.attemptedOwner == conflict.attemptedOwner
            }) {
                conflicts.append(conflict)
            }
            return conflict
        }
        owners[key] = owner
        return nil
    }

    /// Release a previously-claimed chord. Idempotent — calling release
    /// on an unowned chord is a no-op (matches `unregister`'s
    /// idempotence). Also clears any conflicts that referred to the
    /// freed chord so the UI doesn't keep showing a stale warning after
    /// the owning plugin is disabled.
    func release(keyCode: UInt32, modifiers: UInt32, owner: String) {
        let key = Self.chordKey(keyCode: keyCode, modifiers: modifiers)
        guard owners[key] == owner else { return }
        owners.removeValue(forKey: key)
        conflicts.removeAll { $0.keyCode == keyCode && $0.modifiers == modifiers }
    }

    /// Test-only reset. Production code never calls this; the registry
    /// lives for the app's lifetime.
    func _resetForTesting() {
        owners.removeAll()
        conflicts.removeAll()
    }

    private static func chordKey(keyCode: UInt32, modifiers: UInt32) -> UInt64 {
        (UInt64(keyCode) << 32) | UInt64(modifiers)
    }
}

/// Global-hotkey wrapper backed by `NSEvent.addGlobalMonitorForEvents`.
///
/// Originally implemented via Carbon's `RegisterEventHotKey`. The Carbon
/// path stopped delivering events to the handler on this build's machine
/// for any chord with a Cocoa-menu collision or any modifier combination
/// the system has progressively reserved on macOS 14+ — registration
/// succeeded (no errors logged) but the callback never fired. Meanwhile
/// AskHalen's `NSEvent`-monitor path worked reliably for ⌃H on the same
/// machine.
///
/// This rewrite matches the AskHalen path: an Input-Monitoring-gated
/// global monitor for events in other apps, plus a local monitor so the
/// chord still fires when Halen itself is frontmost (and the local one
/// can swallow it via `nil` return so SwiftUI text fields don't see a
/// stray keystroke).
///
/// `keyCode` is still the Carbon `kVK_*` virtual key (callers don't
/// change). `modifiers` is still the Carbon mask (`controlKey`,
/// `optionKey`, `cmdKey`, `shiftKey`) — we translate to
/// `NSEvent.ModifierFlags` inside the match check so the per-plugin
/// `register` call sites don't need to change.
@MainActor
final class HotkeyRegistrar {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onFire: (() -> Void)?

    /// What the registrar holds right now, so `unregister()` can tell the
    /// conflict registry which chord/owner to release. Without this the
    /// registry would keep the chord forever even after the registrar
    /// tears it down.
    private var currentOwner: String?
    private var currentKeyCode: UInt32 = 0
    private var currentModifiers: UInt32 = 0

    /// Register a global hotkey for `owner`. `owner` is the human-readable
    /// plugin label (e.g. "Voice Dictation") shown in the conflict warning
    /// if another plugin already holds the same chord. The `id` parameter
    /// is accepted for API compatibility with the previous Carbon-backed
    /// implementation but no longer needed — NSEvent monitors don't share
    /// a process-wide handler the way Carbon's event target did, so
    /// per-registrar closures are isolated by construction.
    @discardableResult
    func register(keyCode: UInt32,
                  modifiers: UInt32,
                  id: UInt32 = 1,
                  owner: String,
                  onFire: @escaping () -> Void) -> Bool {
        _ = id   // kept for caller compatibility, see doc comment above

        // First: ask the process-wide registry whether this chord is
        // free. Doing this before any monitor install means a conflict
        // doesn't leak a monitor we'd then need to roll back.
        if let conflict = HotkeyConflictRegistry.shared.claim(
            keyCode: keyCode, modifiers: modifiers, owner: owner) {
            Log.warn("HotkeyRegistrar: \(owner) wanted \(conflict.displayChord) but \(conflict.existingOwner) already holds it")
            return false
        }

        unregister()
        self.onFire = onFire
        self.currentOwner = owner
        self.currentKeyCode = keyCode
        self.currentModifiers = modifiers

        // Global-monitor key-down needs Input Monitoring. The install
        // succeeds either way; without permission the callback never
        // fires for events from other apps. Request explicitly so the
        // first-launch prompt happens before the user wonders why
        // nothing's working.
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if !granted {
            Log.warn("HotkeyRegistrar: \(owner) — Input Monitoring not granted; chord will only fire while Halen is frontmost. Grant in System Settings → Privacy & Security → Input Monitoring.")
        }

        let targetMask = Self.cocoaModifierMask(carbon: modifiers)
        let targetKeyCode = CGKeyCode(keyCode)

        let match: (NSEvent) -> Bool = { event in
            event.keyCode == targetKeyCode
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == targetMask
        }

        // Global monitor: keystrokes in other apps. Cannot consume the
        // event (NSEvent returns Void), so an app whose own menu binds
        // the same chord may still see it — same trade-off AskHalen has
        // lived with for ⌃H.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard match(event) else { return }
            // Log + fire on the main actor (NSEvent global monitor
            // delivers on the main thread, but be explicit so behaviour
            // matches the local-monitor path below where SwiftUI focus
            // ops require @MainActor isolation).
            MainActor.assumeIsolated {
                Log.info("HotkeyRegistrar: \(owner) fired (global)")
                self?.onFire?()
            }
        }

        // Local monitor: keystrokes while Halen itself is frontmost.
        // Returning `nil` swallows the event so e.g. a ⌃⌥Space pressed
        // while typing in Halen's own Snippets editor still toggles
        // dictation rather than getting interpreted as text input.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard match(event) else { return event }
            MainActor.assumeIsolated {
                Log.info("HotkeyRegistrar: \(owner) fired (local)")
                self?.onFire?()
            }
            return nil
        }

        if globalMonitor == nil {
            Log.warn("HotkeyRegistrar: \(owner) — addGlobalMonitorForEvents returned nil")
        }

        Log.info("HotkeyRegistrar: \(owner) registered keyCode=\(keyCode) modifiers=\(modifiers) (global=\(globalMonitor != nil), local=\(localMonitor != nil), inputMonitoring=\(granted))")
        return true
    }

    func unregister() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
        if let owner = currentOwner {
            HotkeyConflictRegistry.shared.release(
                keyCode: currentKeyCode, modifiers: currentModifiers, owner: owner)
        }
        currentOwner = nil
        currentKeyCode = 0
        currentModifiers = 0
        onFire = nil
    }

    /// Translate a Carbon modifier bitmask (`controlKey | optionKey | …`)
    /// to its `NSEvent.ModifierFlags` equivalent. Keeps `register`
    /// callers using familiar Carbon constants while the matching
    /// internally uses Cocoa flags.
    private static func cocoaModifierMask(carbon: UInt32) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if carbon & UInt32(controlKey) != 0 { mask.insert(.control) }
        if carbon & UInt32(optionKey)  != 0 { mask.insert(.option)  }
        if carbon & UInt32(shiftKey)   != 0 { mask.insert(.shift)   }
        if carbon & UInt32(cmdKey)     != 0 { mask.insert(.command) }
        return mask
    }

    /// Safety net only — `VoiceDictation.stop()` calls `unregister()` on
    /// the main actor as the real teardown path. This catches a registrar
    /// that's released without `stop()` having run.
    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor  { NSEvent.removeMonitor(m) }
    }
}
