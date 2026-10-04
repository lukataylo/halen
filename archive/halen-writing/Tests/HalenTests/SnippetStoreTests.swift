import XCTest
@testable import Halen

/// `SnippetStore` is the data layer behind Snippet Expander. The runtime that
/// consumes it (caret pause → trigger match → inline rewrite) needs AX + a
/// running NSApp, so those paths aren't testable in unit form. The store
/// itself is straightforward Codable + bounded mutation — every regression
/// we've shipped here came from either the bounds slipping or the builtin-
/// override merge picking the wrong copy on launch. Tests lock both.
@MainActor
final class SnippetStoreTests: XCTestCase {

    /// Each test gets a fresh on-disk store at a unique URL inside the OS
    /// temp dir. We don't share file URLs between tests because `addCustom`
    /// writes synchronously, and a stale file would leak builtins across
    /// runs.
    private func makeStore() -> SnippetStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("halen-snippet-store-\(UUID().uuidString).json")
        return SnippetStore(fileURL: url)
    }

    // MARK: - Builtins

    /// Fresh store should ship every builtin trigger, on every launch, with
    /// no user file present. Builtins live in source code (`SnippetStore.builtins`)
    /// so adding one and missing this assertion would be a silent regression.
    func testBuiltinsLoadIntoFreshStore() {
        let store = makeStore()
        let triggers = Set(store.snippets.map(\.trigger))
        for builtin in SnippetStore.builtins {
            XCTAssertTrue(triggers.contains(builtin.trigger),
                          "Missing builtin trigger \(builtin.trigger)")
        }
    }

    // MARK: - Trigger / value bounds

    /// `triggerMaxLength` is 32 today. A 33-char trigger must be rejected so
    /// pasting a paragraph into the trigger field can't blow past the cap.
    func testRejectsTriggerOverMaxLength() {
        let store = makeStore()
        let triggerLen = SnippetStore.triggerMaxLength + 1
        let oversized = ";" + String(repeating: "a", count: triggerLen - 1)
        XCTAssertEqual(oversized.count, triggerLen)
        let before = store.snippets.count
        store.addCustom(trigger: oversized, kind: .staticText,
                        value: "x", displayName: "Oversized")
        XCTAssertEqual(store.snippets.count, before,
                       "Oversized trigger leaked into the store")
    }

    /// `valueMaxLength` is 4 000. A larger value must be rejected — the
    /// guard exists to stop a JSON-import or programmatic call from
    /// stuffing a 50 KB prompt in.
    func testRejectsValueOverMaxLength() {
        let store = makeStore()
        let oversized = String(repeating: "x", count: SnippetStore.valueMaxLength + 1)
        let before = store.snippets.count
        store.addCustom(trigger: ";big", kind: .staticText,
                        value: oversized, displayName: "Big")
        XCTAssertEqual(store.snippets.count, before,
                       "Oversized value leaked into the store")
    }

    /// `triggerMinChars` is 2 (semicolon + at least one letter). A bare ";"
    /// must be rejected so an empty trigger can't shadow every word.
    func testRejectsTooShortTrigger() {
        let store = makeStore()
        let before = store.snippets.count
        store.addCustom(trigger: ";", kind: .staticText,
                        value: "x", displayName: "Empty")
        XCTAssertEqual(store.snippets.count, before)
    }

    /// Triggers with no leading `;` are normalised — the user typing `sig`
    /// in the add-form should land as `;sig`.
    func testAutoPrependsSemicolon() {
        let store = makeStore()
        store.addCustom(trigger: "mytag", kind: .staticText,
                        value: "value", displayName: "My Tag")
        XCTAssertNotNil(store.snippet(for: ";mytag"))
    }

    // MARK: - Lookup

    /// Lookup is case-insensitive — Halen's trigger detection lowercases the
    /// typed token before matching, and the store has to behave the same way
    /// so a snippet added as `;Sig` still fires for `;sig`.
    func testLookupIsCaseInsensitive() {
        let store = makeStore()
        store.addCustom(trigger: ";Sig", kind: .staticText,
                        value: "v", displayName: "Sig")
        XCTAssertNotNil(store.snippet(for: ";sig"))
        XCTAssertNotNil(store.snippet(for: ";SIG"))
    }

    // MARK: - Builtin override

    /// When the user "edits" a builtin (e.g. `;sig`), the store suppresses the
    /// original builtin entry and persists a custom one in its place. The
    /// regression here is that on the next `ensureBuiltins()` pass the
    /// builtin must NOT come back — `;sig` should resolve to the user's
    /// value, not the shipped default.
    func testEditingBuiltinReplacesItPermanently() {
        let store = makeStore()
        let originalSig = store.snippet(for: ";sig")
        XCTAssertNotNil(originalSig, "Builtin ;sig should ship by default")
        XCTAssertTrue(originalSig?.builtin == true)

        store.update(trigger: ";sig", kind: .staticText,
                     value: "— custom override",
                     displayName: "Sig override")

        let after = store.snippet(for: ";sig")
        XCTAssertEqual(after?.value, "— custom override")
        XCTAssertFalse(after?.builtin ?? true,
                       "Edited builtin must not stay flagged as builtin")
    }

    // MARK: - Remove

    /// Removing a builtin must be a no-op — they're shipped defaults, not
    /// user content. Removing a custom snippet works.
    func testRemoveSkipsBuiltinsButRemovesCustom() {
        let store = makeStore()
        let beforeBuiltinCount = store.snippets.filter(\.builtin).count
        store.remove(";sig")
        XCTAssertEqual(store.snippets.filter(\.builtin).count, beforeBuiltinCount,
                       "Remove of a builtin trigger must be a no-op")

        store.addCustom(trigger: ";custom", kind: .staticText,
                        value: "v", displayName: "Custom")
        XCTAssertNotNil(store.snippet(for: ";custom"))
        store.remove(";custom")
        XCTAssertNil(store.snippet(for: ";custom"))
    }

    // MARK: - Persistence

    /// Round-trip: writing through one store instance and re-opening at the
    /// same URL surfaces the custom snippet. Builtins re-merge alongside.
    func testRoundTripsThroughDisk() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("halen-snippet-roundtrip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = SnippetStore(fileURL: url)
        writer.addCustom(trigger: ";lunch", kind: .staticText,
                         value: "Out for lunch — back at 1.",
                         displayName: "Lunch")

        let reader = SnippetStore(fileURL: url)
        let restored = reader.snippet(for: ";lunch")
        XCTAssertEqual(restored?.value, "Out for lunch — back at 1.")
        XCTAssertEqual(restored?.builtin, false)
    }
}
