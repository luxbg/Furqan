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
