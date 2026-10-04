import CoreAudio
import Foundation

/// Knows when a call app has the microphone, without any permission prompt:
/// CoreAudio exposes per-process "is running input" flags (macOS 14.2+).
/// We poll every 2 s — far cheaper than it sounds, and simpler than juggling
/// property listeners on a process list that churns constantly.
@MainActor
public final class CallDetector {
    public nonisolated static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.cisco.webexmeetingsapp": "Webex",
        // Browsers — usually Meet. Ambiguous (could be any web mic use), so
        // the app asks before starting rather than auto-starting.
        "com.google.Chrome": "Browser",
        "com.apple.Safari": "Browser",
        "company.thebrowser.Browser": "Browser",
        "org.mozilla.firefox": "Browser",
        "com.microsoft.edgemac": "Browser",
        "com.brave.Browser": "Browser",
    ]

    public struct Call: Equatable, Sendable {
        public var bundleID: String
        public var appName: String
        public var isBrowser: Bool { appName == "Browser" }
    }

    public private(set) var current: Call?
    public var onChange: ((Call?) -> Void)?
    private var timer: Timer?

    public init() {}

    public func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    private func poll() {
        let own = Bundle.main.bundleIdentifier
        let call = Self.processesUsingMic()
            .filter { $0 != own }
            .compactMap { id in Self.match(id).map { Call(bundleID: $0.key, appName: $0.value) } }
            // Prefer a dedicated call app over a browser if both have the mic.
            .sorted { !$0.isBrowser && $1.isBrowser }
            .first
        if call != current {
            current = call
            onChange?(call)
        }
    }

    /// Browsers capture from helper processes ("com.google.Chrome.helper"),
    /// so match on prefix as well as exact id.
    public nonisolated static func match(_ id: String) -> (key: String, value: String)? {
        if let name = callApps[id] { return (id, name) }
        return callApps.first { id.hasPrefix($0.key + ".") }
    }

    /// Bundle IDs of processes currently capturing audio input.
    public nonisolated static func processesUsingMic() -> [String] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { pid in
            var running: UInt32 = 0
            var rsize = UInt32(MemoryLayout<UInt32>.size)
            var raddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(pid, &raddr, 0, nil, &rsize, &running) == noErr, running != 0 else { return nil }

            return bundleID(of: pid)
        }
    }

    public nonisolated static func bundleID(of process: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }
}
