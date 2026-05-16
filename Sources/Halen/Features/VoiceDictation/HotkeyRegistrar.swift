import Carbon.HIToolbox
import AppKit
import Foundation

/// Carbon `RegisterEventHotKey` wrapper. The NSEvent global monitor we tried first
/// didn't fire reliably for ⌥⌘Space — Carbon's path is the canonical mechanism for
/// menubar apps that need a real, system-wide shortcut, and it works without
/// Input Monitoring permission.
@MainActor
final class HotkeyRegistrar {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onFire: (() -> Void)?

    @discardableResult
    func register(keyCode: UInt32,
                  modifiers: UInt32,
                  id: UInt32 = 1,
                  onFire: @escaping () -> Void) -> Bool {
        unregister()
        self.onFire = onFire

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let registrar = Unmanaged<HotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
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
        // multiple hotkeys sharing one handler. Each HotkeyRegistrar instance
        // owns its own handler, but we still parameterise `id` so consumers
        // can keep them unique within the process for safety.
        let hotKeyID = EventHotKeyID(signature: 0x48414c4e, id: id) // 'HALN'
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

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = handlerRef { RemoveEventHandler(ref) }
    }
}
