import XCTest
@testable import Halen

/// `ClarityRulesStore` is the rule-set Clarity Checker feeds into its
/// multi-label classification prompt. Modeled identically to
/// `SentimentRulesStore` and `StyleRulesStore` (which already have tests);
/// the bar here is the same: builtins seed on first launch, user toggles
/// persist, custom rules round-trip, and `remove` can't delete a builtin.
@MainActor
final class ClarityRulesStoreTests: XCTestCase {

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("halen-clarity-rules-\(UUID().uuidString).json")
    }

    // MARK: - Builtins

    /// Fresh store ships every shipped builtin rule. Adding a builtin and
    /// missing this assertion would mean it never reaches new installs.
    func testBuiltinsSeedFreshStore() {
        let store = ClarityRulesStore(fileURL: tempURL())
        let ids = Set(store.rules.map(\.id))
        for builtin in ClarityRulesStore.builtins {
            XCTAssertTrue(ids.contains(builtin.id),
                          "Missing builtin rule \(builtin.id)")
        }
    }

    /// Default enabled set excludes "hedging" — it ships off because it
    /// catches polite-but-fine writing too often. Regression-protect that
    /// the default isn't accidentally flipped on.
    func testHedgingShipsDisabledByDefault() {
        let store = ClarityRulesStore(fileURL: tempURL())
        let hedging = store.rules.first(where: { $0.id == "hedging" })
        XCTAssertEqual(hedging?.enabled, false,
                       "hedging must ship disabled — too many false positives on polite writing")
    }

    // MARK: - Enabled set

    func testEnabledRulesFiltersDisabled() {
        let store = ClarityRulesStore(fileURL: tempURL())
        store.setEnabled("passive_voice", enabled: false)
        XCTAssertFalse(store.enabledRules.contains(where: { $0.id == "passive_voice" }))
    }

    // MARK: - Custom rules

    /// Adding a custom rule slugs the label into an id and appends to the
    /// store. The custom rule is `builtin: false` and `enabled: true`.
    func testAddCustomRuleAppends() {
        let store = ClarityRulesStore(fileURL: tempURL())
        let before = store.rules.count
        store.addCustomRule(label: "Buzzword check",
                            prompt: "uses buzzwords like synergy or leverage")
        XCTAssertEqual(store.rules.count, before + 1)
        let added = store.rules.last
        XCTAssertEqual(added?.label, "Buzzword check")
        XCTAssertEqual(added?.builtin, false)
        XCTAssertEqual(added?.enabled, true)
    }

    /// Empty / whitespace-only label or prompt is rejected.
    func testAddCustomRuleRejectsEmptyFields() {
        let store = ClarityRulesStore(fileURL: tempURL())
        let before = store.rules.count
        store.addCustomRule(label: "   ", prompt: "valid prompt")
        store.addCustomRule(label: "Valid label", prompt: "")
        XCTAssertEqual(store.rules.count, before, "Empty inputs must be rejected")
    }

    // MARK: - Remove

    /// Removing a builtin must be a no-op. They're shipped defaults; the
    /// user toggles them off via `setEnabled(_:, enabled:)` instead.
    func testRemoveSkipsBuiltins() {
        let store = ClarityRulesStore(fileURL: tempURL())
        let beforeBuiltinCount = store.rules.filter(\.builtin).count
        store.remove("passive_voice")
        XCTAssertEqual(store.rules.filter(\.builtin).count, beforeBuiltinCount)
    }

    /// Removing a custom rule succeeds.
    func testRemoveDeletesCustomRule() {
        let store = ClarityRulesStore(fileURL: tempURL())
        store.addCustomRule(label: "Buzzword check",
                            prompt: "uses buzzwords like synergy or leverage")
        let id = store.rules.last!.id
        store.remove(id)
        XCTAssertFalse(store.rules.contains(where: { $0.id == id }))
    }

    // MARK: - Sort

    /// Sort places builtins first, then alphabetical-by-label inside each
    /// group. The detail view depends on this for a stable display.
    func testSortPutsBuiltinsBeforeCustom() {
        let store = ClarityRulesStore(fileURL: tempURL())
        store.addCustomRule(label: "AAA custom early",
                            prompt: "a custom rule prompt")
        let sorted = store.sorted
        let firstNonBuiltin = sorted.firstIndex(where: { !$0.builtin }) ?? sorted.count
        let lastBuiltin = sorted.lastIndex(where: { $0.builtin }) ?? -1
        XCTAssertLessThan(lastBuiltin, firstNonBuiltin,
                          "All builtins must sort before all custom rules")
    }

    // MARK: - Persistence

    /// Custom rules survive a fresh store opened at the same URL.
    func testCustomRulesRoundTripThroughDisk() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = ClarityRulesStore(fileURL: url)
        writer.addCustomRule(label: "Adverb watch",
                             prompt: "leans on adverbs where a stronger verb would do")

        let reader = ClarityRulesStore(fileURL: url)
        XCTAssertTrue(reader.rules.contains(where: { $0.label == "Adverb watch" }))
    }

    /// User-toggled built-ins persist across launches — disabling
    /// passive_voice once should leave it disabled on the next open.
    func testBuiltinToggleSurvivesReopen() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = ClarityRulesStore(fileURL: url)
        writer.setEnabled("passive_voice", enabled: false)

        let reader = ClarityRulesStore(fileURL: url)
        let passive = reader.rules.first(where: { $0.id == "passive_voice" })
        XCTAssertEqual(passive?.enabled, false)
    }
}
