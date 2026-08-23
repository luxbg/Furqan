import XCTest
@testable import Quran

/// Regression tests for QuranDatabase's words-table load
/// (`flatWords`/`wordMaps`, built directly from the mushaf SVG's own
/// per-word rows) and the generic `reconcileWordSlots`/
/// `proportionalWordSlotMapping` reconciliation machinery in
/// `WordLocation.swift`, which `PhonemeWordMapping` reuses to align the
/// phoneme corpus's independently-segmented words onto these same slots.
final class WordLocationTests: XCTestCase {
    static let database = QuranDatabase()
    var db: QuranDatabase { Self.database }

    private func ayahIndex(_ surah: Int, _ ayahNumber: Int) -> Int {
        db.ayahs.firstIndex { $0.surah == surah && $0.ayahNumber == ayahNumber }!
    }

    /// Core invariant the whole word-highlighting UI depends on:
    /// `wordMaps[i].slots.count` must equal the number of `flatWords`
    /// belonging to that ayah, for every ayah - true by construction now
    /// (both are built from the same SVG raw-slot pass), but worth pinning
    /// down as a regression guard.
    func testEverySlotCountMatchesFlatWordCount() {
        for (index, _) in db.ayahs.enumerated() {
            XCTAssertEqual(
                db.wordMaps[index].slots.count, db.flatWords(inAyahIndex: index).count,
                "slot count mismatch for ayah index \(index)"
            )
        }
    }

    func testFirstWordOfAlFatihaMapsToKnownSVGElement() {
        let map = db.wordMaps[ayahIndex(1, 1)]
        XCTAssertEqual(map.slots.first?.svgElementIds, ["md-word-002"])
        XCTAssertEqual(map.page, 1)
    }

    /// Regression case for the ordinary waw-al-atf merge: 1:5's
    /// "وَإِيَّاكَ" is one real word, two SVG glyphs (md-word-021,
    /// md-word-022).
    func testWawAlatfMergesIntoOneSlot() {
        let index = ayahIndex(1, 5)
        let slots = db.wordMaps[index].slots
        XCTAssertEqual(slots.count, 4)
        XCTAssertEqual(slots[2].svgElementIds, ["md-word-021", "md-word-022"])
    }

    // MARK: - reconcileWordSlots / proportionalWordSlotMapping (pure functions)

    func testReconcileExactCounts() {
        let mapping = reconcileWordSlots(leftSkeletons: ["a", "b", "c"], rightSkeletons: ["a", "b", "c"])
        XCTAssertEqual(mapping, [0, 1, 2])
    }

    func testReconcileTwoWordFusion() {
        // left slot 1 ("xy") is the concatenation of right-hand words "x"+"y".
        let mapping = reconcileWordSlots(leftSkeletons: ["a", "xy", "c"], rightSkeletons: ["a", "x", "y", "c"])
        XCTAssertEqual(mapping, [0, 1, 1, 2])
    }

    func testReconcileFailsOnGenuineMismatch() {
        let mapping = reconcileWordSlots(leftSkeletons: ["a", "b"], rightSkeletons: ["a", "z"])
        XCTAssertNil(mapping)
    }

    func testReconcileEmptyInputsFail() {
        XCTAssertNil(reconcileWordSlots(leftSkeletons: [], rightSkeletons: ["a"]))
        XCTAssertNil(reconcileWordSlots(leftSkeletons: ["a"], rightSkeletons: []))
    }

    func testProportionalFallbackMappingStaysInBounds() {
        let mapping = proportionalWordSlotMapping(leftCount: 3, rightCount: 7)
        XCTAssertEqual(mapping.count, 7)
        for index in mapping {
            XCTAssertTrue((0..<3).contains(index))
        }
        XCTAssertEqual(mapping.first, 0)
        XCTAssertEqual(mapping.last, 2)
    }

    func testProportionalFallbackWithZeroLeftSlots() {
        let mapping = proportionalWordSlotMapping(leftCount: 0, rightCount: 3)
        XCTAssertEqual(mapping, [0, 0, 0])
    }
}
