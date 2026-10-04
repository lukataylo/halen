import XCTest
@testable import Halen

/// Tone Profiles is the host service Sentiment Guard and Clarity Checker read
/// to decide whether a given app's text is "formal" or "casual." A drift in
/// the store's contract — wrong default, dropped persistence, neutral entries
/// bloating the file — would silently bias every classifier on macOS. These
/// tests pin the contract.
@MainActor
final class AppToneProfileStoreTests: XCTestCase {

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("halen-tone-profiles-\(UUID().uuidString).json")
    }

    // MARK: - Default

    /// Unknown bundle ids resolve to `.neutral` — that's the only safe
    /// default for an app the user hasn't told us about. A classifier
    /// reading `.formal` for every unconfigured app would over-flag casual
    /// Slack messages on day one.
    func testDefaultProfileIsNeutral() {
        let store = AppToneProfileStore(fileURL: tempURL())
        XCTAssertEqual(store.profile(for: "com.unknown.app"), .neutral)
    }

    /// A nil bundle id (no focused app) also resolves to `.neutral`.
    func testNilBundleIdIsNeutral() {
        let store = AppToneProfileStore(fileURL: tempURL())
        XCTAssertEqual(store.profile(for: nil), .neutral)
    }

    // MARK: - Set / get round-trip

    /// Setting a non-neutral profile persists it and surfaces on the next
    /// `profile(for:)` read.
    func testRoundTripFormalProfile() {
        let store = AppToneProfileStore(fileURL: tempURL())
        store.setProfile(.formal, for: "com.apple.mail")
        XCTAssertEqual(store.profile(for: "com.apple.mail"), .formal)
    }

    func testRoundTripCasualProfile() {
        let store = AppToneProfileStore(fileURL: tempURL())
        store.setProfile(.casual, for: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(store.profile(for: "com.tinyspeck.slackmacgap"), .casual)
    }

    // MARK: - Neutral elision

    /// Writing `.neutral` for an app is functionally a *remove* — neutral is
    /// the default, so storing it bloats the file and clutters the editor.
    /// Regression: this used to persist neutral entries.
    func testSettingNeutralRemovesEntry() {
        let store = AppToneProfileStore(fileURL: tempURL())
        store.setProfile(.formal, for: "com.apple.mail")
        XCTAssertEqual(store.profiles["com.apple.mail"], .formal)

        store.setProfile(.neutral, for: "com.apple.mail")
        XCTAssertNil(store.profiles["com.apple.mail"],
                     "Setting .neutral must remove the entry, not store it")
        XCTAssertEqual(store.profile(for: "com.apple.mail"), .neutral,
                       "Removed entry still resolves to .neutral via default")
    }

    // MARK: - Whitespace handling

    /// Bundle ids are trimmed on write. A whitespace-only id is rejected
    /// because it can never be a real app identifier and would create a
    /// poisoned entry the editor can't display.
    func testBlankBundleIdIsRejected() {
        let store = AppToneProfileStore(fileURL: tempURL())
        store.setProfile(.formal, for: "   ")
        XCTAssertTrue(store.profiles.isEmpty)
    }

    // MARK: - Remove

    func testRemoveProfileClearsEntry() {
        let store = AppToneProfileStore(fileURL: tempURL())
        store.setProfile(.casual, for: "com.tinyspeck.slackmacgap")
        store.removeProfile(for: "com.tinyspeck.slackmacgap")
        XCTAssertNil(store.profiles["com.tinyspeck.slackmacgap"])
    }

    // MARK: - Persistence

    /// Writes through one instance must surface in a fresh instance opened
    /// at the same URL — the editor and the classifier each construct their
    /// own store, so cross-instance consistency is the contract that matters.
    func testRoundTripsThroughDisk() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = AppToneProfileStore(fileURL: url)
        writer.setProfile(.formal, for: "com.apple.mail")
        writer.setProfile(.casual, for: "com.tinyspeck.slackmacgap")

        let reader = AppToneProfileStore(fileURL: url)
        XCTAssertEqual(reader.profile(for: "com.apple.mail"), .formal)
        XCTAssertEqual(reader.profile(for: "com.tinyspeck.slackmacgap"), .casual)
        XCTAssertEqual(reader.profiles.count, 2)
    }

    // MARK: - sortedEntries

    /// Editor list is stable across launches — the sorted-by-bundle-id
    /// invariant is what the detail view relies on for a non-jumpy display.
    func testSortedEntriesIsStable() {
        let store = AppToneProfileStore(fileURL: tempURL())
        store.setProfile(.formal, for: "com.zzz.app")
        store.setProfile(.casual, for: "com.aaa.app")
        store.setProfile(.formal, for: "com.mmm.app")

        let sorted = store.sortedEntries.map(\.bundleId)
        XCTAssertEqual(sorted, ["com.aaa.app", "com.mmm.app", "com.zzz.app"])
    }

    // MARK: - ToneProfile enum

    /// `promptClause` is what's spliced into classifier / rewrite prompts.
    /// Every case has to return a non-empty clause — an empty string would
    /// silently neutralise the profile signal for that case.
    func testAllProfilesHaveNonEmptyPromptClauses() {
        for profile in ToneProfile.allCases {
            XCTAssertFalse(profile.promptClause.isEmpty,
                           "\(profile.rawValue) has an empty promptClause")
            XCTAssertFalse(profile.label.isEmpty,
                           "\(profile.rawValue) has an empty label")
        }
    }

    // MARK: - Register classifier token parsing (Sentiment Guard target-tone)

    /// `fromClassifierToken` maps the small model's register reply back to a
    /// profile. The exact-match contract is load-bearing: a substring scan
    /// once read "informal" as `.formal` (its opposite), silently suppressing
    /// the flag. Pin the real labels AND the off-list rejects.
    func testFromClassifierTokenMapsRealRegisters() {
        XCTAssertEqual(ToneProfile.fromClassifierToken("formal"), .formal)
        XCTAssertEqual(ToneProfile.fromClassifierToken("casual"), .casual)
        XCTAssertEqual(ToneProfile.fromClassifierToken("business-casual"), .businessCasual)
        XCTAssertEqual(ToneProfile.fromClassifierToken("business casual"), .businessCasual)
        // First-token parse can clip "business casual" to "business".
        XCTAssertEqual(ToneProfile.fromClassifierToken("business"), .businessCasual)
        XCTAssertEqual(ToneProfile.fromClassifierToken("FORMAL"), .formal)
    }

    func testFromClassifierTokenRejectsOffListReplies() {
        // The bug that motivated this: "informal" must NOT resolve to .formal.
        XCTAssertNil(ToneProfile.fromClassifierToken("informal"))
        XCTAssertNil(ToneProfile.fromClassifierToken("neutral"))
        XCTAssertNil(ToneProfile.fromClassifierToken(""))
        XCTAssertNil(ToneProfile.fromClassifierToken("polite and nice"))
    }

    /// Detection only flags a message that reads *less* formal than the app's
    /// target (`actual.formalityRank < target.formalityRank`). Pin the rank
    /// ordering the comparison depends on, and the `enforcesTarget` gate.
    func testFormalityRankOrderingAndEnforcement() {
        XCTAssertGreaterThan(ToneProfile.formal.formalityRank,
                             ToneProfile.businessCasual.formalityRank)
        XCTAssertGreaterThan(ToneProfile.businessCasual.formalityRank,
                             ToneProfile.casual.formalityRank)
        XCTAssertGreaterThan(ToneProfile.casual.formalityRank,
                             ToneProfile.neutral.formalityRank)
        // Teams=Business casual flags casual, not formal.
        XCTAssertLessThan(ToneProfile.casual.formalityRank,
                          ToneProfile.businessCasual.formalityRank)
        XCTAssertFalse(ToneProfile.formal.formalityRank
                       < ToneProfile.businessCasual.formalityRank)
        // Only non-neutral profiles impose a target.
        XCTAssertTrue(ToneProfile.formal.enforcesTarget)
        XCTAssertTrue(ToneProfile.businessCasual.enforcesTarget)
        XCTAssertFalse(ToneProfile.neutral.enforcesTarget)
        // Every enforcing profile has a non-nil target descriptor (the
        // register prompt + rephrase rely on it being present).
        for p in ToneProfile.allCases where p.enforcesTarget {
            XCTAssertNotNil(p.targetDescriptor, "\(p.rawValue) missing targetDescriptor")
        }
        XCTAssertNil(ToneProfile.neutral.targetDescriptor)
    }
}
