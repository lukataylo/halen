import AudioToolbox
import CoreAudio
import Foundation

/// Knows *when* the other people on a call are talking — never *what*.
/// A Core Audio process tap on the call app's output feeds an IO block that
/// computes one loudness number per callback and drops the samples on the
/// spot. Only (time, level) pairs survive, and only until the call ends.
///
/// Needs the "audio capture" permission (NSAudioCaptureUsageDescription);
/// if it's denied, Presence simply has fewer factors.
public final class FarEndTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let lock = NSLock()
    private var levels: [(t: Double, db: Float)] = []
    private var _current: Float = -120

    public init() { levels.reserveCapacity(400_000) }   // ~70 min at ~94 Hz: no reallocs on the IO thread
    deinit { teardown() }

    /// Latest far-end level in dBFS, for the live meter.
    public var currentLevel: Float { lock.withLock { _current } }

    public enum TapError: Error { case noProcess, failed(OSStatus) }

    /// Start tapping every process whose bundle id is (or is a helper of) `bundleID`.
    public func start(bundleID: String) throws {
        let pids = Self.processObjects(matching: bundleID)
        guard !pids.isEmpty else { throw TapError.noProcess }

        let desc = CATapDescription(stereoMixdownOfProcesses: pids)
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        do { try startTap(desc) } catch { teardown(); throw error }
    }

    private func startTap(_ desc: CATapDescription) throws {
        try check(AudioHardwareCreateProcessTap(desc, &tapID))

        let (outputUID, outputInputBuffers) = try Self.defaultOutput()
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Halen EQ level meter",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregateID))

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [weak self] _, input, inputTime, _, _ in
            guard let self else { return }
            var sum: Float = 0, n = 0
            // The aggregate's input list starts with the output device's own
            // inputs (a headset mic!) — skip them and read only the tap.
            for buf in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).dropFirst(outputInputBuffers) {
                guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                for i in 0 ..< count { sum += p[i] * p[i] }
                n += count
            }
            guard n > 0 else { return }
            let db = 10 * log10(max(sum / Float(n), 1e-12))
            let t = HostTime.seconds(inputTime.pointee.mHostTime)
            self.lock.withLock { self.levels.append((t, db)); self._current = db }
        })
        try check(AudioDeviceStart(aggregateID, procID))
    }

    /// Stop and return far-end speech spans on the session clock, where
    /// `origin` is the host time (seconds) of the first mic sample.
    public func stop(origin: Double) -> [Span] {
        teardown()
        let ls = lock.withLock { defer { levels = [] }; return levels }
        return Self.spans(ls.map { ($0.t - origin, $0.db) })
    }

    private func teardown() {
        if let procID { AudioDeviceStop(aggregateID, procID); AudioDeviceDestroyIOProcID(aggregateID, procID) }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil; aggregateID = kAudioObjectUnknown; tapID = kAudioObjectUnknown
    }

    /// Far-end audio is clean digital (no room noise), so a fixed threshold
    /// works; merge sub-300 ms gaps between words.
    static func spans(_ levels: [(t: Double, db: Float)], threshold: Float = -45) -> [Span] {
        var raw: [Span] = []
        var open: Double?
        var last = 0.0
        for (t, db) in levels {
            if db > threshold, open == nil { open = t }
            if db <= threshold, let s = open { raw.append(Span(s, t)); open = nil }
            last = t
        }
        if let s = open { raw.append(Span(s, last)) }
        return Activity.merge(raw, gap: 0.3).filter { $0.duration >= 0.2 && $0.end > 0 }
    }

    private func check(_ s: OSStatus) throws { if s != noErr { throw TapError.failed(s) } }

    static func processObjects(matching bundleID: String) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            guard let b = CallDetector.bundleID(of: id) else { return false }
            return b == bundleID || b.hasPrefix(bundleID + ".")
        }
    }

    /// UID of the default output device, and how many input buffers it
    /// contributes to an aggregate (headsets have a mic on the same device).
    static func defaultOutput() throws -> (uid: String, inputBuffers: Int) {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { throw TapError.noProcess }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr, let s = uid?.takeRetainedValue() else { throw TapError.noProcess }

        var cfg = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                             mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var cfgSize: UInt32 = 0
        var inputs = 0
        if AudioObjectGetPropertyDataSize(dev, &cfg, 0, nil, &cfgSize) == noErr, cfgSize > 0 {
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(cfgSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            if AudioObjectGetPropertyData(dev, &cfg, 0, nil, &cfgSize, raw) == noErr {
                inputs = Int(raw.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
            }
        }
        return (s as String, inputs)
    }
}

public enum HostTime {
    public static var now: Double { seconds(mach_absolute_time()) }
    private static let info: mach_timebase_info_data_t = { var i = mach_timebase_info_data_t(); mach_timebase_info(&i); return i }()
    public static func seconds(_ hostTime: UInt64) -> Double {
        Double(hostTime) * Double(info.numer) / Double(info.denom) / 1e9
    }
}
