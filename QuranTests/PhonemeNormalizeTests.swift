import XCTest
@testable import Quran

final class PhonemeNormalizeTests: XCTestCase {
    // MARK: - collapseRuns

    func testCollapseRunsCollapsesRepeatedSymbol() {
        let collapsed = PhonemeNormalize.collapseRuns("ۥۥۥۥ".phonemeScalars)
        XCTAssertEqual(collapsed.scalarString, "ۥ")
    }

    func testCollapseRunsNeverMergesDifferentSymbols() {
        let collapsed = PhonemeNormalize.collapseRuns("ۥۥيي".phonemeScalars)
        XCTAssertEqual(collapsed.scalarString, "ۥي")
    }

    // MARK: - phonemesMatch

    func testIdenticalStringsMatch() {
        XCTAssertTrue(PhonemeNormalize.phonemesMatch("بِسمِ", "بِسمِ"))
    }

    func testTajweedLengthVariationIsTolerated() {
        // Madd length rendered as 4 vs 2 harakat -- both legitimate.
        XCTAssertTrue(PhonemeNormalize.phonemesMatch("ررَحِۦۦۦۦم", "ررَحِۦۦم"))
    }

    func testWaqfTrailingShortVowelDropIsTolerated() {
        // A pause drops a trailing short vowel -- one char longer, prefix match.
        XCTAssertTrue(PhonemeNormalize.phonemesMatch("بِسمِ", "بِسم"))
    }

    /// قليلا's standalone (paused) phoneme rendering ends in an alif-madd
    /// elongation ("قَلِۦۦلَاا", tanween fatha as "...aa") -- exactly the
    /// part an ASR model most often clips right at a word boundary, leaving
    /// "قَلِۦۦلَ". Same tolerance as a dropped trailing short vowel, one
    /// character short after tajweed-length collapsing.
    func testTrailingAlifMaddDropIsTolerated() {
        XCTAssertTrue(PhonemeNormalize.phonemesMatch("قَلِۦۦلَاا", "قَلِۦۦلَ"))
    }

    /// Real-world report: "عَزِيزٌ ذُو ٱنتِقَامٍ" (3:4) recited normally
    /// (not paused) came back as "ذُ" against the corpus's "ذُۥۥ" -- ذُو's
    /// own natural (2-count) waw-madd elongation, the same kind of trailing
    /// sound an ASR model clips just as readily as a trailing short vowel.
    func testTrailingWawMaddDropIsTolerated() {
        XCTAssertTrue(PhonemeNormalize.phonemesMatch("ذُۥۥ", "ذُ"))
    }

    /// A wrong final letter is still a real mistake, not a rendering
    /// choice, even when it's one character short -- must never be
    /// silently tolerated just because the lengths line up.
    func testTrailingWrongConsonantIsNotTolerated() {
        XCTAssertFalse(PhonemeNormalize.phonemesMatch("قَلِۦۦلَن", "قَلِۦۦلَ"))
    }

    /// A *wrong* short vowel is a real phoneme-identity mistake, not a
    /// tajweed rendering choice -- must never be silently tolerated by
    /// independently stripping trailing vowels from both sides.
    func testWrongShortVowelIsNotTolerated() {
        XCTAssertFalse(PhonemeNormalize.phonemesMatch("رَ", "رُ"))
    }

    /// Regression: the droppable-trailing-vowel tolerance must be one-way
    /// only (forgiving `expected`'s own vowel being dropped at a pause) --
    /// a genuinely WRONG vowel tacked onto `actual`, one character longer
    /// than `expected`, must never be forgiven just because that wrong
    /// vowel happens to also be a member of the droppable set. Confirmed
    /// live: "أَلْفَ" ("ءَلفَ", fatha) recited with the wrong final vowel
    /// ("ءَلفُ", damma) matched anyway via the isolated/paused-form fallback
    /// ("ءَلف", no vowel at all) -- ANY appended vowel looked "droppable"
    /// against a form that has none, regardless of whether it was the
    /// right one.
    func testWrongTrailingVowelAppendedToActualIsNotTolerated() {
        XCTAssertFalse(PhonemeNormalize.phonemesMatch("بِسم", "بِسمِ"), "expected shorter (paused/isolated form), actual has an extra vowel - must not be forgiven")
        XCTAssertFalse(PhonemeNormalize.phonemesMatch("ءَلف", "ءَلفُ"), "isolated form has no vowel at all - any appended vowel on actual is a real mismatch, not a drop")
    }

    /// A single wrong character in an otherwise-long word must still be
    /// caught -- exact equality after normalization, not a fuzzy
    /// similarity threshold that would under-penalize it.
    func testSingleWrongCharacterInLongWordIsCaught() {
        XCTAssertFalse(PhonemeNormalize.phonemesMatch("ررَحِۦۦمِيلَاا", "ررَحِۦۦمِيلَاٱ"))
    }

    // MARK: - phonemeSimilarity

    func testSimilarityOfIdenticalStringsIsOne() {
        XCTAssertEqual(PhonemeNormalize.phonemeSimilarity("بِسمِ", "بِسمِ"), 1.0, accuracy: 0.0001)
    }

    func testSimilarityOfEmptyStringsIsOne() {
        XCTAssertEqual(PhonemeNormalize.phonemeSimilarity("", ""), 1.0, accuracy: 0.0001)
    }

    func testSimilarityIsNotTheMatchGate() {
        // High similarity, but not an exact (post-normalization) match --
        // phonemesMatch must independently reject this.
        let expected = "ررَحِۦۦمِيلَاا"
        let actual = "ررَحِۦۦمِيلَاٱ"
        XCTAssertGreaterThan(PhonemeNormalize.phonemeSimilarity(expected, actual), 0.85)
        XCTAssertFalse(PhonemeNormalize.phonemesMatch(expected, actual))
    }
}
