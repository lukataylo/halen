import Carbon.HIToolbox
import AppKit
import Foundation

/// Process-wide catalogue of Carbon hotkey ids. Adding a new hotkey here AND
/// passing `.rawValue` to `HotkeyRegistrar.register(..., id:)` keeps id
/// collisions a compile-time concern instead of a runtime surprise.
enum HotkeyID: UInt32 {
    case voiceDictation = 1
    case askHalen       = 2
    case emailReply     = 3
    case autocomplete   = 4
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

/// Carbon `RegisterEventHotKey` wrapper. The NSEvent global monitor we tried first
/// didn't fire reliably for ⌥⌘Space — Carbon's path is the canonical mechanism for
/// menubar apps that need a real, system-wide shortcut, and it works without
/// Input Monitoring permission.
@MainActor
final class HotkeyRegistrar {
    /// `nonisolated(unsafe)` because `deinit` (which runs on whatever thread
    /// releases the last reference, not necessarily the main actor) must read
    /// these to tear down the Carbon registration. The access is genuinely
    /// safe: every other touch is from `register`/`unregister` (both
    /// `@MainActor`), and `deinit` only runs once no reference remains — so no
    /// `@MainActor` method can be executing concurrently with it. Same
    /// reasoning as `registeredID` below.
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private var onFire: (() -> Void)?
    /// `registeredID` and `signature` are read from the Carbon C callback,
    /// which can fire on any thread. They're written only from `register`/
    /// `unregister` (both `@MainActor`) and are simple scalars, so
    /// `nonisolated(unsafe)` reflects the actual guarantee.
    nonisolated(unsafe) private var registeredID: UInt32 = 0
    nonisolated static let signature: OSType = 0x48414c4e   // 'HALN'

    /// What the registrar holds right now, so `unregister()` can tell the
    /// conflict registry which chord/owner to release. Without this the
    /// registry would keep the chord forever even after the registrar
    /// tears it down.
    private var currentOwner: String?
    private var currentKeyCode: UInt32 = 0
    private var currentModifiers: UInt32 = 0

    /// Result of a `register` attempt. Carbon-level failures (handler
    /// install, OS refusal) report `.carbonFailure`; intra-Halen
    /// conflicts report `.conflict` so the caller can degrade gracefully
    /// and the Settings UI can surface the collision.
    enum RegistrationFailure: Error {
        case conflict(HotkeyConflict)
        case carbonFailure(OSStatus)
    }

    /// Register a global hotkey for `owner`. `owner` is the human-readable
    /// plugin label (e.g. "Voice Dictation") shown in the conflict warning
    /// if another plugin already holds the same chord. Returns `true` on
    /// success; on failure the registrar stays unregistered and the caller
    /// is expected to log a degraded-state warning.
    @discardableResult
    func register(keyCode: UInt32,
                  modifiers: UInt32,
                  id: UInt32 = 1,
                  owner: String,
                  onFire: @escaping () -> Void) -> Bool {
        // First: ask the process-wide registry whether this chord is
        // free. Doing this before any Carbon call means a conflict
        // doesn't leak a handler install we'd then need to roll back.
        if let conflict = HotkeyConflictRegistry.shared.claim(
            keyCode: keyCode, modifiers: modifiers, owner: owner) {
            Log.warn("HotkeyRegistrar: \(owner) wanted \(conflict.displayChord) but \(conflict.existingOwner) already holds it")
            return false
        }

        unregister()
        self.onFire = onFire
        self.registeredID = id
        self.currentOwner = owner
        self.currentKeyCode = keyCode
        self.currentModifiers = modifiers

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let userData, let eventRef else { return noErr }
            let registrar = Unmanaged<HotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()

            // Carbon's `GetApplicationEventTarget` delivers every
            // `kEventHotKeyPressed` to every installed handler whose
            // `EventTypeSpec` matches — including handlers belonging to OTHER
            // `HotkeyRegistrar` instances in this process. Without filtering
            // by `EventHotKeyID`, registering ⌥Space here would *also* fire
            // the VoiceDictation ⌥⌘H handler (and vice-versa).
            var firedID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                OSType(kEventParamDirectObject),
                OSType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &firedID
            )
            guard status == noErr,
                  firedID.signature == HotkeyRegistrar.signature,
                  firedID.id == registrar.registeredID
            else { return noErr }

            DispatchQueue.main.async {
                registrar.onFire?()
            }
            return noErr
        }

        var newHandler: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            userData,
            &newHandler
        )
        guard installStatus == noErr else {
            Log.warn("HotkeyRegistrar: InstallEventHandler failed (\(installStatus))")
            // Roll back the conflict-registry claim so the chord doesn't
            // stay marked as held by an owner that never actually got it.
            HotkeyConflictRegistry.shared.release(
                keyCode: keyCode, modifiers: modifiers, owner: owner)
            self.currentOwner = nil
            return false
        }
        handlerRef = newHandler

        // Signature+id is the app-local identity Carbon uses to disambiguate
        // multiple hotkeys. Two registrars MUST use distinct ids or the
        // callback's filter (above) won't distinguish them.
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var newHotKey: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newHotKey
        )
        guard registerStatus == noErr else {
            Log.warn("HotkeyRegistrar: RegisterEventHotKey failed (\(registerStatus))")
            if let handler = handlerRef {
                RemoveEventHandler(handler)
                handlerRef = nil
            }
            HotkeyConflictRegistry.shared.release(
                keyCode: keyCode, modifiers: modifiers, owner: owner)
            self.currentOwner = nil
            return false
        }
        hotKeyRef = newHotKey
        Log.info("HotkeyRegistrar: \(owner) registered keyCode=\(keyCode) modifiers=\(modifiers)")
        return true
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = handlerRef {
            RemoveEventHandler(ref)
            handlerRef = nil
        }
        if let owner = currentOwner {
            HotkeyConflictRegistry.shared.release(
                keyCode: currentKeyCode, modifiers: currentModifiers, owner: owner)
        }
        currentOwner = nil
        currentKeyCode = 0
        currentModifiers = 0
        onFire = nil
    }

    /// Safety net only — `VoiceDictation.stop()` calls `unregister()` on the
    /// main actor as the real teardown path. This catches a registrar that's
    /// released without `stop()` having run. Reads `hotKeyRef`/`handlerRef`
    /// off-actor, which is sound: see the `nonisolated(unsafe)` note above.
    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = handlerRef { RemoveEventHandler(ref) }
    }
}
