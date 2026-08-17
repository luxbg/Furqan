import XCTest
@testable import Quran

/// Regression tests for `AyahAligner`, built directly from real
/// `quran.sqlite` data (via `QuranDatabase`, loaded once for the whole test
/// class) so cases stay accurate if the underlying text ever changes.
final class AyahAlignerTests: XCTestCase {
    static let database = QuranDatabase()
    var db: QuranDatabase { Self.database }

    private func ayah(_ surah: Int, _ ayahNumber: Int) -> Ayah {
        db.ayahs.first { $0.surah == surah && $0.ayahNumber == ayahNumber }!
    }

    private func ayahIndex(_ surah: Int, _ ayahNumber: Int) -> Int {
        db.ayahs.firstIndex { $0.surah == surah && $0.ayahNumber == ayahNumber }!
    }

    private func flatStart(_ surah: Int, _ ayahNumber: Int) -> Int {
        db.flatStart(ofAyahIndex: ayahIndex(surah, ayahNumber))
    }

    // MARK: - Identification

    /// Baseline: an unaltered tail resolves to the correct ayah.
    func testColdStartExactMatchResolves() {
        let target = ayah(2, 255) // Ayat al-Kursi - long, distinctive
        let tail = Array(target.groundTruthSkeletonWords.suffix(4))
        let result = AyahAligner.identifyAyah(tailWords: tail, database: db, currentPages: target.startPage...target.endPage)
        XCTAssertEqual(result?.ayahIndex, ayahIndex(2, 255))
        let expectedOffset = target.groundTruthSkeletonWords.count - 4
        XCTAssertEqual(result?.flatPosition, flatStart(2, 255) + expectedOffset)
    }

    /// Tolerant of up to 2 consecutive wrong words - substituting 1, then 2,
    /// words in the middle of a long tail must still resolve.
    func testColdStartTolerantOfWrongWords() {
        let target = ayah(2, 255)
        var words = Array(target.groundTruthSkeletonWords.suffix(10))

        words[4] = "غرغبمذ" // 1 garbage word
        var result = AyahAligner.identifyAyah(tailWords: words, database: db, currentPages: nil)
        XCTAssertEqual(result?.ayahIndex, ayahIndex(2, 255), "should tolerate 1 wrong word")

        words[5] = "زقفشثظ" // 2 consecutive garbage words
        result = AyahAligner.identifyAyah(tailWords: words, database: db, currentPages: nil)
        XCTAssertEqual(result?.ayahIndex, ayahIndex(2, 255), "should tolerate 2 consecutive wrong words")
    }

    /// Past the tolerance (3 consecutive wrong words), must not resolve -
    /// no false positive on some other ayah either.
    func testColdStartFailsPastTolerance() {
        let target = ayah(2, 255)
        var words = Array(target.groundTruthSkeletonWords.suffix(10))
        words[4] = "غرغبمذ"
        words[5] = "زقفشثظ"
        words[6] = "طظضذخث"
        let result = AyahAligner.identifyAyah(tailWords: words, database: db, currentPages: nil)
        XCTAssertNil(result)
    }

    /// Generic leading-word leniency (plan's requirement 5, folded into
    /// identification with no muqata'at-specific code): a garbled leading
    /// word still lets the rest of a tail align within a candidate's window
    /// - tested directly against `align` (rather than whole-Quran
    /// `identifyAyah`, which has its own, separately-tested disambiguation
    /// concerns) on both a muqata'at-opening ayah and an ordinary one, to
    /// confirm the mechanism is genuinely content-agnostic.
    func testLeadingUnrecognizedWordsIgnoredGenerically() {
        // Muqata'at case: 2:1 is the single word "الم"; garble it and give
        // the next few real words from 2:2 as context.
        let opening = ayah(2, 1)
        XCTAssertEqual(opening.groundTruthSkeletonWords, ["الم"])
        let next = ayah(2, 2)
        let openingStart = flatStart(2, 1)
        let openingWindowEnd = min(db.flatWords.count, openingStart + opening.groundTruthSkeletonWords.count + 6)
        let openingWindow = db.flatWords[openingStart..<openingWindowEnd].map(\.skeleton)

        var words = ["زحطكango"] // garbled muqata'at
        words.append(contentsOf: next.groundTruthSkeletonWords.prefix(4))
        let alignment = AyahAligner.align(observed: words, candidate: openingWindow, freeLeadingCandidate: true)
        XCTAssertNotNil(alignment, "garbled muqata'at opener should still align within its ayah's window")

        // Ordinary case: same mechanism, unrelated ayah, first word garbled.
        let ordinary = ayah(112, 1) // "قُلْ هُوَ اللَّهُ أَحَدٌ"
        let ordinaryStart = flatStart(112, 1)
        let ordinaryWindowEnd = min(db.flatWords.count, ordinaryStart + ordinary.groundTruthSkeletonWords.count + 6)
        let ordinaryWindow = db.flatWords[ordinaryStart..<ordinaryWindowEnd].map(\.skeleton)

        var ordinaryWords = ["نطزحكصم"]
        ordinaryWords.append(contentsOf: ordinary.groundTruthSkeletonWords.dropFirst())
        let ordinaryAlignment = AyahAligner.align(observed: ordinaryWords, candidate: ordinaryWindow, freeLeadingCandidate: true)
        XCTAssertNotNil(ordinaryAlignment, "should be content-agnostic, not muqata'at-specific")
    }

    /// A genuinely repeated ayah (found dynamically, on two cleanly
    /// page-separated occurrences so this tracks real data instead of an
    /// assumption that could silently stop holding) stays ambiguous with no
    /// page hint, and resolves once a page hint narrows it to one occurrence.
    func testAmbiguousRepeatedAyahStaysAmbiguousUntilDisambiguated() {
        var groups: [String: [Int]] = [:]
        for (idx, a) in db.ayahs.enumerated() where a.groundTruthSkeletonWords.count >= 5 {
            groups[a.groundTruthSkeletonWords.joined(separator: " "), default: []].append(idx)
        }
        let cleanPairs = groups.values.filter { indices in
            guard indices.count == 2 else { return false }
            let a = db.ayahs[indices[0]], b = db.ayahs[indices[1]]
            return a.endPage < b.startPage || b.endPage < a.startPage
        }
        guard !cleanPairs.isEmpty else {
            XCTFail("no cleanly page-separated repeated ayah found - data may have changed")
            return
        }

        // A page hint disambiguates *this* pair from each other, but a
        // fuzzy (tolerant-of-2-wrong-words) match against some unrelated
        // third ayah that happens to share the same page is a separate,
        // real possibility for any single candidate phrase - not what this
        // test is checking. Scanning for one pair where that doesn't
        // incidentally happen keeps the test meaningful without being
        // flaky about which exact pair the real Quran text happens to offer.
        for indices in cleanPairs {
            let tail = db.ayahs[indices[0]].groundTruthSkeletonWords
            guard AyahAligner.identifyAyah(tailWords: tail, database: db, currentPages: nil) == nil else { continue }
            let target = db.ayahs[indices[0]]
            let resolved = AyahAligner.identifyAyah(tailWords: tail, database: db, currentPages: target.startPage...target.endPage)
            if resolved?.ayahIndex == indices[0] {
                return // found a clean example exercising both halves of the behavior
            }
        }
        XCTFail("no repeated-ayah pair found where a page hint alone disambiguates - data may have changed")
    }

    // MARK: - Tracking

    /// Forward tracking tolerant of 1-2 wrong words: substituted words
    /// still advance and get flagged, not frozen.
    func testForwardTrackingTolerantOfWrongWords() {
        let start = flatStart(2, 255)
        let ayahWords = ayah(2, 255).groundTruthSkeletonWords
        let ayahTashkeel = ayah(2, 255).groundTruthWords
        var observed = Array(ayahWords.prefix(10))
        observed[2] = "غرغبمذ" // 1 wrong word, well before the grace tail
        observed.append(contentsOf: ayahWords[10..<13]) // real continuation, past finalizeGrace
        var observedTashkeel = Array(ayahTashkeel.prefix(10))
        observedTashkeel[2] = "غرغبمذ"
        observedTashkeel.append(contentsOf: ayahTashkeel[10..<13])

        let result = AyahAligner.advance(
            observed: observed, observedTashkeel: observedTashkeel, confirmedPosition: start, floor: start, database: db
        )
        guard case .forward = result.outcome else {
            return XCTFail("expected forward progress, got \(result.outcome)")
        }
        let wrongStep = result.commitSteps.first { $0.flatIndex == start + 2 }
        XCTAssertEqual(wrongStep?.step.kind, .substitute)
    }

    /// Past tolerance (3 consecutive wrong words) with floor == position
    /// (no room to backtrack), tracking must freeze rather than resolve.
    func testForwardTrackingFreezesPastTolerance() {
        let start = flatStart(2, 255)
        var observed = ayah(2, 255).groundTruthSkeletonWords
        observed[2] = "غرغبمذ"
        observed[3] = "زقفشثظ"
        observed[4] = "طظضذخث"

        let result = AyahAligner.advance(
            observed: observed, observedTashkeel: [], confirmedPosition: start, floor: start, database: db
        )
        XCTAssertEqual(result.outcome, .frozen)
    }

    /// Backtrack: reciter repeats an earlier phrase within the 2-page/floor
    /// window - recognized and resolves *behind* the current position.
    func testBacktrackWithinWindowRecognized() {
        let ayahAStart = flatStart(2, 30)
        let ayahA = ayah(2, 30)
        let confirmed = ayahAStart + ayahA.groundTruthSkeletonWords.count // just past ayah A

        // Repeat the last 5 words of ayah A, then genuinely continue forward
        // (ayah A's real next-in-sequence content) past the grace tail -
        // real continuation, not arbitrary padding, so it doesn't itself
        // read as extra/wrong words and break the tolerance streak.
        var observed = Array(ayahA.groundTruthSkeletonWords.suffix(5))
        observed.append(contentsOf: ayah(2, 31).groundTruthSkeletonWords.prefix(3))
        var observedTashkeel = Array(ayahA.groundTruthWords.suffix(5))
        observedTashkeel.append(contentsOf: ayah(2, 31).groundTruthWords.prefix(3))

        let result = AyahAligner.advance(
            observed: observed, observedTashkeel: observedTashkeel, confirmedPosition: confirmed, floor: ayahAStart, database: db
        )
        guard case .backtrack = result.outcome else {
            return XCTFail("expected backtrack, got \(result.outcome)")
        }
        // The repeated words themselves re-verify content *before* the old
        // confirmed position - newPosition itself may legitimately land
        // back at (or past) the old position once grace-period commits
        // catch up, since nothing was really lost, just re-said.
        XCTAssertTrue(
            result.commitSteps.contains { $0.flatIndex < confirmed },
            "backtrack should re-verify at least one word before the old position"
        )
        XCTAssertTrue(result.commitSteps.allSatisfy { $0.flatIndex >= ayahAStart })
    }

    /// The same repeated content, but with the floor set *after* it (i.e.
    /// beyond where this identification attempt began) must not resolve as
    /// a backtrack - clamped, not resolved.
    func testBacktrackBeyondFloorRejected() {
        let ayahAStart = flatStart(2, 30)
        let ayahA = ayah(2, 30)
        let confirmed = ayahAStart + ayahA.groundTruthSkeletonWords.count

        var observed = Array(ayahA.groundTruthSkeletonWords.suffix(5))
        observed.append(contentsOf: ayah(2, 31).groundTruthSkeletonWords.prefix(3))

        // Floor pinned at the current position itself - no backtrack room.
        let result = AyahAligner.advance(
            observed: observed, observedTashkeel: [], confirmedPosition: confirmed, floor: confirmed, database: db
        )
        XCTAssertEqual(result.outcome, .frozen)
    }

    /// Forward tracking flows across an ayah boundary with no special event.
    func testForwardTrackingCrossesAyahBoundary() {
        let ayahA = ayah(2, 1) // "الم" - short, so the boundary is reached fast
        let ayahAStart = flatStart(2, 1)
        let ayahB = ayah(2, 2)

        var observed = ayahA.groundTruthSkeletonWords
        observed.append(contentsOf: ayahB.groundTruthSkeletonWords.prefix(7)) // real words throughout, past finalizeGrace
        var observedTashkeel = ayahA.groundTruthWords
        observedTashkeel.append(contentsOf: ayahB.groundTruthWords.prefix(7))

        let result = AyahAligner.advance(
            observed: observed, observedTashkeel: observedTashkeel, confirmedPosition: ayahAStart, floor: ayahAStart, database: db
        )
        guard case .forward = result.outcome else {
            return XCTFail("expected forward progress, got \(result.outcome)")
        }
        let crossedIntoB = result.commitSteps.contains { db.flatWords[$0.flatIndex].ayahIndex == ayahIndex(2, 2) }
        XCTAssertTrue(crossedIntoB, "should flow into the next ayah with no special transition needed")
    }

    // MARK: - Verification leniency

    func testPositionBasedLeniencyThreshold() {
        XCTAssertFalse(AyahAligner.shouldScore(wordsSinceIdentification: 0))
        XCTAssertFalse(AyahAligner.shouldScore(wordsSinceIdentification: 1))
        XCTAssertTrue(AyahAligner.shouldScore(wordsSinceIdentification: 2))
        XCTAssertTrue(AyahAligner.shouldScore(wordsSinceIdentification: 5))
    }
}
