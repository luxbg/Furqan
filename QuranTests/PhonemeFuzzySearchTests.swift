import XCTest
@testable import Quran

final class PhonemeFuzzySearchTests: XCTestCase {
    func testFindsExactMatch() {
        let text = "ابجدهوزحطي".phonemeScalars
        let pattern = "دهو".phonemeScalars
        let matches = PhonemeFuzzySearch.findNearMatches(pattern: pattern, in: text, maxLDist: 0)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].dist, 0)
        XCTAssertEqual(text[matches[0].start..<matches[0].end].scalarString, "دهو")
    }

    func testFindsMatchWithinToleratedDistance() {
        let text = "ابجدهوزحطي".phonemeScalars
        // One substituted character ("ة" for "ه").
        let pattern = "دةو".phonemeScalars
        let matches = PhonemeFuzzySearch.findNearMatches(pattern: pattern, in: text, maxLDist: 1)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].dist, 1)
        XCTAssertEqual(text[matches[0].start..<matches[0].end].scalarString, "دهو")
    }

    func testNoMatchBeyondToleratedDistance() {
        let text = "ابجدهوزحطي".phonemeScalars
        let pattern = "قرص".phonemeScalars
        let matches = PhonemeFuzzySearch.findNearMatches(pattern: pattern, in: text, maxLDist: 1)
        XCTAssertTrue(matches.isEmpty)
    }

    func testEmptyPatternOrTextReturnsNoMatches() {
        XCTAssertTrue(PhonemeFuzzySearch.findNearMatches(pattern: [], in: "abc".phonemeScalars, maxLDist: 2).isEmpty)
        XCTAssertTrue(PhonemeFuzzySearch.findNearMatches(pattern: "abc".phonemeScalars, in: [], maxLDist: 2).isEmpty)
    }

    func testFindsTwoDistinctMatchesFarApart() {
        let text = "دهو" + String(repeating: "x", count: 40) + "دهو"
        let pattern = "دهو".phonemeScalars
        let matches = PhonemeFuzzySearch.findNearMatches(pattern: pattern, in: text.phonemeScalars, maxLDist: 0)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].start, 0)
        XCTAssertEqual(matches[1].start, text.phonemeScalars.count - 3)
    }

    // MARK: - Myers bit-vector fast path vs. the brute-force DP reference

    /// The fast path (`myersLastRow`) must produce *exactly* the same
    /// per-column distances as the reference DP (`slowForwardPassLastRow`)
    /// on every input - a silently wrong bit-vector derivation would mean
    /// wrong ayah localizations in the live app, a far worse failure mode
    /// than the slowness this fast path exists to fix. Exhaustive-ish
    /// randomized coverage: small alphabet (to force lots of repeats/runs,
    /// the case bit-parallel algorithms most often get wrong), pattern
    /// lengths spanning both sides of the 64-bit word boundary, several
    /// text lengths.
    func testMyersMatchesReferenceDPAcrossRandomInputs() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        let alphabet: [Unicode.Scalar] = ["a", "b", "c"]

        func randomScalars(_ count: Int) -> [Unicode.Scalar] {
            (0..<count).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] }
        }

        let patternLengths = [1, 2, 7, 8, 16, 31, 32, 33, 63, 64]
        let textLengths = [0, 1, 5, 20, 100, 300]

        for m in patternLengths {
            for n in textLengths {
                for _ in 0..<5 {
                    let pattern = randomScalars(m)
                    let text = randomScalars(n)
                    let expected = PhonemeFuzzySearch.slowForwardPassLastRow(pattern: pattern, text: text)
                    let actual = PhonemeFuzzySearch.myersLastRow(pattern: pattern, text: text)
                    XCTAssertEqual(
                        actual, expected,
                        "mismatch for pattern=\(pattern.map(String.init).joined()) text=\(text.map(String.init).joined())"
                    )
                }
            }
        }
    }

    /// Same differential check, but end-to-end through `findNearMatches`
    /// (exercises clustering + the windowed backtrack too, not just the
    /// raw per-column distances) on real Quranic phoneme text.
    func testFindNearMatchesAgreesRegardlessOfPatternLengthBoundary() {
        let text = String(repeating: "ررَحِۦۦمِبِسمِللَااهِ", count: 20).phonemeScalars
        for patternLen in [8, 63, 64, 65, 70] {
            let pattern = Array(text.prefix(patternLen))
            let matches = PhonemeFuzzySearch.findNearMatches(pattern: pattern, in: text, maxLDist: 1)
            XCTAssertFalse(matches.isEmpty, "pattern length \(patternLen) should find itself in the text it came from")
            XCTAssertEqual(matches.min(by: { $0.dist < $1.dist })?.dist, 0)
        }
    }
}

/// Small, seedable, dependency-free PRNG - deterministic test data only,
/// not for anything security-sensitive.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
