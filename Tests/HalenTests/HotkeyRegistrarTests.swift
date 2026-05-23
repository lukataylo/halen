import XCTest
import Carbon.HIToolbox
@testable import Halen

/// Exercises the process-wide `HotkeyConflictRegistry`. We don't drive the
/// real Carbon `RegisterEventHotKey` here — the registry's job is to
/// detect intra-Halen collisions *before* Carbon is touched, so testing
/// at the registry layer is both faster and free of the "headless CI has
/// no event target" failure mode the Carbon path would hit.
@MainActor
final class HotkeyRegistrarTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        HotkeyConflictRegistry.shared._resetForTesting()
    }

    override func tearDown() async throws {
        HotkeyConflictRegistry.shared._resetForTesting()
        try await super.tearDown()
    }

    /// First plugin to claim a chord wins; the registry reports no
    /// conflict and the conflicts list stays empty.
    func testFirstRegistrationSucceeds() {
        let conflict = HotkeyConflictRegistry.shared.claim(
            keyCode: UInt32(kVK_ANSI_H),
            modifiers: UInt32(cmdKey | optionKey),
            owner: "Voice Dictation")
        XCTAssertNil(conflict)
        XCTAssertTrue(HotkeyConflictRegistry.shared.conflicts.isEmpty)
    }

    /// A second plugin claiming the same chord is rejected; the first
    /// owner remains the holder and the conflict is appended for the UI.
    func testSecondRegistrationFailsAndPreservesFirstOwner() {
        let first = HotkeyConflictRegistry.shared.claim(
            keyCode: UInt32(kVK_ANSI_H),
            modifiers: UInt32(cmdKey | optionKey),
            owner: "Voice Dictation")
        XCTAssertNil(first)

        let second = HotkeyConflictRegistry.shared.claim(
            keyCode: UInt32(kVK_ANSI_H),
            modifiers: UInt32(cmdKey | optionKey),
            owner: "Ask Halen")
        XCTAssertNotNil(second)
        XCTAssertEqual(second?.existingOwner, "Voice Dictation")
        XCTAssertEqual(second?.attemptedOwner, "Ask Halen")
        XCTAssertEqual(HotkeyConflictRegistry.shared.conflicts.count, 1)

        // The original owner still holds the chord — a *third* attempt to
        // claim it returns the same existing-owner.
        let third = HotkeyConflictRegistry.shared.claim(
            keyCode: UInt32(kVK_ANSI_H),
            modifiers: UInt32(cmdKey | optionKey),
            owner: "Something Else")
        XCTAssertEqual(third?.existingOwner, "Voice Dictation")
    }

    /// Releasing the first owner frees the chord, so a second plugin
    /// can pick it up cleanly with no conflict surfaced.
    func testReleaseFreesChord() {
        let chord = (keyCode: UInt32(kVK_ANSI_H),
                     modifiers: UInt32(cmdKey | optionKey))
        _ = HotkeyConflictRegistry.shared.claim(
            keyCode: chord.keyCode, modifiers: chord.modifiers,
            owner: "Voice Dictation")

        HotkeyConflictRegistry.shared.release(
            keyCode: chord.keyCode, modifiers: chord.modifiers,
            owner: "Voice Dictation")

        let second = HotkeyConflictRegistry.shared.claim(
            keyCode: chord.keyCode, modifiers: chord.modifiers,
            owner: "Ask Halen")
        XCTAssertNil(second)
        XCTAssertTrue(HotkeyConflictRegistry.shared.conflicts.isEmpty,
                      "release should clear stale conflict rows for the freed chord")
    }

    /// Distinct chords coexist — claiming ⌥⌘H and ⌃⌥E from different
    /// plugins is the common happy path and must not flag anything.
    func testDifferentChordsDoNotConflict() {
        let h = HotkeyConflictRegistry.shared.claim(
            keyCode: UInt32(kVK_ANSI_H),
            modifiers: UInt32(cmdKey | optionKey),
            owner: "Voice Dictation")
        let e = HotkeyConflictRegistry.shared.claim(
            keyCode: UInt32(kVK_ANSI_E),
            modifiers: UInt32(controlKey | optionKey),
            owner: "Email Reply")
        XCTAssertNil(h)
        XCTAssertNil(e)
        XCTAssertTrue(HotkeyConflictRegistry.shared.conflicts.isEmpty)
    }

    /// `displayChord` formats Carbon modifier bits as the conventional
    /// macOS glyph sequence — order matters for the menu-style read.
    func testDisplayChordRendersModifierGlyphs() {
        let conflict = HotkeyConflict(
            keyCode: UInt32(kVK_ANSI_H),
            modifiers: UInt32(cmdKey | optionKey),
            existingOwner: "A", attemptedOwner: "B")
        XCTAssertEqual(conflict.displayChord, "\u{2325}\u{2318}H")
    }
}
