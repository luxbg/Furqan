import XCTest
@testable import Quran

/// Regression tests for QuranDatabase's words-table load and the SVG-slot /
/// Tanzil-word reconciliation it depends on (WordLocation.swift), built
/// from real quran.sqlite data (via QuranDatabase, loaded once for the
/// whole test class) so cases stay accurate if the underlying data changes.
final class WordLocationTests: XCTestCase {
    static let database = QuranDatabase()
    var db: QuranDatabase { Self.database }

    private func ayahIndex(_ surah: Int, _ ayahNumber: Int) -> Int {
        db.ayahs.firstIndex { $0.surah == surah && $0.ayahNumber == ayahNumber }!
    }

    /// Core invariant the whole word-highlighting UI depends on: slot count
    /// must equal the ayah's Tanzil ground-truth word count, for every
    /// ayah - whether reconciled cleanly or via the proportional fallback.
    func testEverySlotCountMatchesGroundTruthWordCount() {
        for (index, ayah) in db.ayahs.enumerated() {
            XCTAssertEqual(
                db.wordMaps[index].slots.count, ayah.groundTruthWords.count,
                "slot count mismatch for \(ayah.surah):\(ayah.ayahNumber)"
            )
        }
    }

    /// The reconciliation fallback should stay a small, bounded set (last
    /// measured directly against the data: ~281 of 6236 ayahs, all mushaf-
    /// rasm word-fusion cases like a vocative "يا" prefix) - a regression
    /// guard against it silently growing, which would mean word highlights
    /// are landing on the wrong word more often than expected.
    func testReconciliationFallbackStaysBounded() {
        XCTAssertLessThan(db.wordSlotFallbackAyahIndices.count, 400)
    }

    func testFirstWordOfAlFatihaMapsToKnownSVGElement() {
        let map = db.wordMaps[ayahIndex(1, 1)]
        XCTAssertEqual(map.slots.first?.svgElementIds, ["md-word-002"])
        XCTAssertEqual(map.page, 1)
    }

    /// Regression case for the reconciliation algorithm itself: 2:21 opens
    /// with "يَا أَيُّهَا" (2 Tanzil words) drawn as one connected mushaf glyph
    /// "يَٰٓأَيُّهَا" (1 SVG slot) - both Tanzil word positions must map to
    /// that same slot, cleanly (not via the fallback).
    func testFusedVocativeYaResolvesToSharedSlot() {
        let index = ayahIndex(2, 21)
        XCTAssertFalse(db.wordSlotFallbackAyahIndices.contains(index), "2:21 should reconcile cleanly, not via fallback")
        let slots = db.wordMaps[index].slots
        XCTAssertEqual(slots[0].svgElementIds, slots[1].svgElementIds, "\"يا\" and \"أيها\" should share one svg slot")
        XCTAssertFalse(slots[0].svgElementIds.isEmpty)
    }

    /// Regression case for the ordinary (non-fused) waw-al-atf merge, kept
    /// from the original implementation: 1:5's "وَإِيَّاكَ" is one Tanzil
    /// word, two SVG glyphs (md-word-021, md-word-022).
    func testWawAlatfMergesIntoOneSlot() {
        let index = ayahIndex(1, 5)
        let slots = db.wordMaps[index].slots
        XCTAssertEqual(slots.count, 4)
        XCTAssertEqual(slots[2].svgElementIds, ["md-word-021", "md-word-022"])
    }

    // MARK: - reconcileWordSlots / proportionalWordSlotMapping (pure functions)

    func testReconcileExactCounts() {
        let mapping = reconcileWordSlots(svgSkeletons: ["a", "b", "c"], tanzilSkeletons: ["a", "b", "c"])
        XCTAssertEqual(mapping, [0, 1, 2])
    }

    func testReconcileTwoWordFusion() {
        // svg slot 1 ("xy") is the concatenation of tanzil words "x"+"y".
        let mapping = reconcileWordSlots(svgSkeletons: ["a", "xy", "c"], tanzilSkeletons: ["a", "x", "y", "c"])
        XCTAssertEqual(mapping, [0, 1, 1, 2])
    }

    func testReconcileFailsOnGenuineMismatch() {
        let mapping = reconcileWordSlots(svgSkeletons: ["a", "b"], tanzilSkeletons: ["a", "z"])
        XCTAssertNil(mapping)
    }

    func testReconcileEmptyInputsFail() {
        XCTAssertNil(reconcileWordSlots(svgSkeletons: [], tanzilSkeletons: ["a"]))
        XCTAssertNil(reconcileWordSlots(svgSkeletons: ["a"], tanzilSkeletons: []))
    }

    func testProportionalFallbackMappingStaysInBounds() {
        let mapping = proportionalWordSlotMapping(svgCount: 3, tanzilCount: 7)
        XCTAssertEqual(mapping.count, 7)
        for index in mapping {
            XCTAssertTrue((0..<3).contains(index))
        }
        XCTAssertEqual(mapping.first, 0)
        XCTAssertEqual(mapping.last, 2)
    }

    func testProportionalFallbackWithZeroSvgSlots() {
        let mapping = proportionalWordSlotMapping(svgCount: 0, tanzilCount: 3)
        XCTAssertEqual(mapping, [0, 0, 0])
    }
}
