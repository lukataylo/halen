import Carbon.HIToolbox
import AppKit
import Foundation

/// Process-wide catalogue of Carbon hotkey ids. Adding a new hotkey here AND
/// passing `.rawValue` to `HotkeyRegistrar.register(..., id:)` keeps id
/// collisions a compile-time concern instead of a runtime surprise.
enum HotkeyID: UInt32 {
    case voiceDictation = 1
    case askHalen       = 2
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

    @discardableResult
    func register(keyCode: UInt32,
                  modifiers: UInt32,
                  id: UInt32 = 1,
                  onFire: @escaping () -> Void) -> Bool {
        unregister()
        self.onFire = onFire
        self.registeredID = id

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
            return false
        }
        hotKeyRef = newHotKey
        Log.info("HotkeyRegistrar: registered keyCode=\(keyCode) modifiers=\(modifiers)")
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
