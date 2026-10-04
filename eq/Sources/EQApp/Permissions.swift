import AppKit
import AVFoundation
import Speech
import SwiftUI

/// What Halen is allowed to use, and the one action that fixes each: ask
/// (if macOS hasn't yet) or open the right System Settings pane (if it was
/// turned off — apps can't re-ask after a "Don't Allow").
@MainActor
final class Permissions: ObservableObject {
    enum Status: Equatable { case allowed, notAsked, denied, unknown }

    @Published private(set) var microphone: Status = .unknown
    @Published private(set) var speech: Status = .unknown
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        // Coming back from System Settings: pick up the change.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        case .denied, .restricted: .denied
        @unknown default: .unknown
        }
        speech = switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        case .denied, .restricted: .denied
        @unknown default: .unknown
        }
    }

    func requestMicrophone() async {
        if microphone == .denied { Self.open("Privacy_Microphone"); return }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }

    func requestSpeech() async {
        if speech == .denied { Self.open("Privacy_SpeechRecognition"); return }
        _ = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        refresh()
    }

    /// macOS has no "check" API for system audio capture; it asks at the
    /// first call. This opens the pane where it can be switched back on.
    func openSystemAudio() { Self.open("Privacy_ScreenCapture") }

    static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// One row: name, why, status, action.
struct PermissionRow: View {
    let title: String
    let why: String
    let status: Permissions.Status
    let action: () -> Void

    var body: some View {
        LabeledContent {
            switch status {
            case .allowed:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            case .notAsked:
                Button("Allow…", action: action)
            case .denied:
                Button("Open System Settings…", action: action)
            case .unknown:
                Button("Check in System Settings…", action: action)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
