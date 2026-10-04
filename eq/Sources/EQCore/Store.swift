import CryptoKit
import Foundation
import Security

/// A finished conversation, as it lives on disk.
public struct SessionRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var startedAt: Date
    /// Bundle id of the app that held the mic (Zoom, Teams…), or nil for manual.
    public var source: String?
    public var metrics: SessionMetrics
    public var scores: ScoreCard
    /// Your words only — saved only when the voice check is on *and* you
    /// opted in. Dropped after the retention window.
    public var words: [Word]?
    public var takeaway: String?
    /// Your own sense of how it went, 0 (rough) … 1 (great).
    public var rating: Double?
    public var note: String?
    /// Factor ids you said "that's not right" about.
    public var disputed: Set<String> = []

    public init(id: UUID = UUID(), startedAt: Date, source: String?, metrics: SessionMetrics, scores: ScoreCard, words: [Word]?) {
        self.id = id; self.startedAt = startedAt; self.source = source
        self.metrics = metrics; self.scores = scores; self.words = words
    }

    enum CodingKeys: String, CodingKey { case id, startedAt, source, metrics, scores, words, takeaway, rating, note, disputed }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        metrics = try c.decode(SessionMetrics.self, forKey: .metrics)
        scores = try c.decode(ScoreCard.self, forKey: .scores)
        words = try c.decodeIfPresent([Word].self, forKey: .words)
        takeaway = try c.decodeIfPresent(String.self, forKey: .takeaway)
        rating = try c.decodeIfPresent(Double.self, forKey: .rating)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        disputed = try c.decodeIfPresent(Set<String>.self, forKey: .disputed) ?? []
    }

    public var title: String { source.flatMap { CallDetector.match($0)?.value } ?? "Conversation" }
    public var effectiveScores: ScoreCard { scores.without(disputed) }

    public var minutes: Int { max(1, Int(metrics.duration / 60)) }
}

/// The enrolled voice: a mean speaker embedding plus the similarity threshold
/// learned from your own enrollment audio. Biometric data — sealed like
/// sessions, deletable on its own.
public struct VoicePrint: Codable, Sendable, Equatable {
    public var centroid: [Float]
    public var threshold: Float
    public var created: Date
}

/// Encrypted, file-per-session store under Application Support. Each file is
/// AES-GCM sealed with a key that lives only in the login Keychain.
public final class SessionStore: @unchecked Sendable {
    public let directory: URL
    private var key: SymmetricKey
    private let lock = NSLock()

    public init(directory: URL? = nil, key: SymmetricKey? = nil) throws {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HalenEQ/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
        self.key = try key ?? Keychain.storeKey()
    }

    public func save(_ r: SessionRecord) throws { try write(r, to: url(r.id)) }

    public func all() -> [SessionRecord] {
        lock.lock(); defer { lock.unlock() }
        return sessionFiles().compactMap { read(SessionRecord.self, from: $0) }.sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(id))
    }

    /// Drop transcripts older than `transcriptDays`, and any file we can no
    /// longer decrypt (sealed with a lost key). Returns how many changed.
    @discardableResult
    public func enforce(transcriptDays: Int, now: Date = .now) throws -> Int {
        lock.lock()
        var changed = 0
        var stale: [SessionRecord] = []
        for f in sessionFiles() {
            // Delete only what can't be *decrypted* (lost key). A file that
            // decrypts but doesn't decode may be from a newer version — keep it.
            guard let data = open(f) else { try? FileManager.default.removeItem(at: f); changed += 1; continue }
            guard let r = try? JSONDecoder().decode(SessionRecord.self, from: data) else { continue }
            if r.words != nil, now.timeIntervalSince(r.startedAt) > Double(transcriptDays) * 86_400 { stale.append(r) }
        }
        lock.unlock()
        for var r in stale { r.words = nil; try save(r); changed += 1 }
        return changed
    }

    /// Remove saved transcripts from every session (opting out).
    public func dropAllTranscripts() throws {
        for var r in all() where r.words != nil { r.words = nil; try save(r) }
    }

    // MARK: Voice print

    private var voiceURL: URL { directory.deletingLastPathComponent().appendingPathComponent("voice.eqv") }
    public func saveVoicePrint(_ v: VoicePrint) throws { try write(v, to: voiceURL) }
    public func loadVoicePrint() -> VoicePrint? { lock.lock(); defer { lock.unlock() }; return read(VoicePrint.self, from: voiceURL) }
    public func deleteVoicePrint() { lock.lock(); defer { lock.unlock() }; try? FileManager.default.removeItem(at: voiceURL) }

    /// "Forget everything": sessions, voice print, and the key itself.
    public func forgetAll() throws {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: voiceURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // New key in place, so later saves aren't sealed with the deleted one.
        Keychain.deleteStoreKey()
        key = (try? Keychain.storeKey()) ?? SymmetricKey(size: .bits256)
    }

    // MARK: Plumbing

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        lock.lock(); defer { lock.unlock() }
        try AES.GCM.seal(data, using: key).combined!.write(to: url, options: .atomic)
    }

    private func open(_ url: URL) -> Data? {
        guard let blob = try? Data(contentsOf: url), let box = try? AES.GCM.SealedBox(combined: blob) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    private func read<T: Decodable>(_: T.Type, from url: URL) -> T? {
        open(url).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func sessionFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "eqs" }
    }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).eqs") }
}

enum Keychain {
    static let service = "dev.halen.eq"
    static let account = "store-key"

    /// The sandboxed App Store build uses the data-protection keychain (its
    /// provisioning profile supplies the application identifier it needs);
    /// the Developer ID build keeps the login keychain it shipped with.
    static var base: [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if APPSTORE
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    static func storeKey() throws -> SymmetricKey {
        var query = base
        query[kSecReturnData as String] = true
        var out: CFTypeRef?
        let found = SecItemCopyMatching(query as CFDictionary, &out)
        if found == errSecSuccess, let data = out as? Data { return SymmetricKey(data: data) }
        // Anything but "not found" (locked keychain, denied ACL) must not
        // silently mint a second key — files sealed with it would be orphaned.
        guard found == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(found)) }
        let key = SymmetricKey(size: .bits256)
        var add = base
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return key
    }

    static func deleteStoreKey() {
        SecItemDelete(base as CFDictionary)
    }
}
