import XCTest
@testable import Halen

/// `SentimentRulesStore` mirrors `ClarityRulesStore` — built-ins seed on
/// first launch, user-added rules persist, removes skip built-ins. These
/// tests pin the behaviour Sentiment Guard depends on at runtime. The
/// runtime path that fires the classifier needs `services.eventBus` plus
/// `text.pause` events, so that part stays in integration testing; the
/// store itself is pure data and gets unit coverage here.
@MainActor
final class SentimentRulesStoreTests: XCTestCase {

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("halen-sentiment-rules-\(UUID().uuidString).json")
    }

    // MARK: - Builtins

    /// Every shipped builtin id must appear in a fresh store. Adding a
    /// builtin without updating this check would mean it never reaches
    /// users on a fresh install — the rule would only exist in source.
    func testBuiltinsSeedFreshStore() {
        let store = SentimentRulesStore(fileURL: tempURL())
        let ids = Set(store.rules.map(\.id))
        for builtin in SentimentRulesStore.builtins {
            XCTAssertTrue(ids.contains(builtin.id),
                          "Missing builtin rule \(builtin.id)")
        }
    }

    /// Default-enabled set: hostile + irritated are on; everything else
    /// is off until the user opts in. Regression-protect — Sentiment
    /// Guard popping up on every anxious-sounding email would be the
    /// fastest way to lose users.
    func testDefaultEnabledIsHostileAndIrritatedOnly() {
        let store = SentimentRulesStore(fileURL: tempURL())
        let enabledIds = Set(store.rules.filter(\.enabled).map(\.id))
        XCTAssertEqual(enabledIds, ["hostile", "irritated"])
    }

    // MARK: - Toggle

    func testSetEnabledRoundTrips() {
        let store = SentimentRulesStore(fileURL: tempURL())
        store.setEnabled("anxious", enabled: true)
        let anxious = store.rules.first(where: { $0.id == "anxious" })
        XCTAssertEqual(anxious?.enabled, true)

        store.setEnabled("anxious", enabled: false)
        XCTAssertEqual(store.rules.first(where: { $0.id == "anxious" })?.enabled, false)
    }

    // MARK: - Custom rules

    /// Custom rules append, get a slugged id, and ship enabled by default.
    /// `colorName` is preserved so the user's pick shows up in the popover.
    func testAddCustomRuleSlugsIdAndPreservesColor() {
        let store = SentimentRulesStore(fileURL: tempURL())
        store.addCustomRule(label: "Eager beaver",
                            prompt: "is overly enthusiastic to the point of distracting",
                            colorName: "green")
        let added = store.rules.last
        XCTAssertEqual(added?.label, "Eager beaver")
        XCTAssertEqual(added?.builtin, false)
        XCTAssertEqual(added?.enabled, true)
        XCTAssertEqual(added?.colorName, "green")
    }

    func testAddCustomRuleRejectsEmptyFields() {
        let store = SentimentRulesStore(fileURL: tempURL())
        let before = store.rules.count
        store.addCustomRule(label: "   ", prompt: "valid prompt", colorName: "red")
        store.addCustomRule(label: "Label", prompt: "", colorName: "red")
        XCTAssertEqual(store.rules.count, before)
    }

    // MARK: - Remove

    func testRemoveSkipsBuiltins() {
        let store = SentimentRulesStore(fileURL: tempURL())
        let beforeBuiltinCount = store.rules.filter(\.builtin).count
        store.remove("hostile")
        XCTAssertEqual(store.rules.filter(\.builtin).count, beforeBuiltinCount,
                       "Built-in 'hostile' must not be deletable")
    }

    func testRemoveDeletesCustomRule() {
        let store = SentimentRulesStore(fileURL: tempURL())
        store.addCustomRule(label: "Eager beaver",
                            prompt: "is overly enthusiastic",
                            colorName: "green")
        let id = store.rules.last!.id
        store.remove(id)
        XCTAssertFalse(store.rules.contains(where: { $0.id == id }))
    }

    // MARK: - Persistence

    /// User toggles must survive a fresh store opened at the same URL.
    /// The detail view and the classifier each construct their own store
    /// instance; cross-instance consistency is the contract that matters.
    func testToggleSurvivesReopen() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = SentimentRulesStore(fileURL: url)
        writer.setEnabled("anxious", enabled: true)
        writer.setEnabled("hostile", enabled: false)

        let reader = SentimentRulesStore(fileURL: url)
        XCTAssertEqual(reader.rules.first(where: { $0.id == "anxious" })?.enabled, true)
        XCTAssertEqual(reader.rules.first(where: { $0.id == "hostile" })?.enabled, false)
    }

    func testCustomRuleSurvivesReopen() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = SentimentRulesStore(fileURL: url)
        writer.addCustomRule(label: "Eager beaver",
                             prompt: "is overly enthusiastic",
                             colorName: "green")

        let reader = SentimentRulesStore(fileURL: url)
        XCTAssertTrue(reader.rules.contains(where: { $0.label == "Eager beaver" }))
    }
}
