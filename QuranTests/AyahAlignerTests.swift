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
    /// page hint, and resolves once a page hint narrows it to one occurrence
    /// - marked `isProvisional` appropriately, and not resolved at all if
    /// too few words have been heard yet.
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
                XCTAssertEqual(
                    resolved?.isProvisional, tail.count < AyahAligner.solidEvidenceWordCount,
                    "isProvisional should reflect whether enough words have been heard"
                )
                let shortTail = Array(tail.prefix(AyahAligner.minWordsForPageAssistedResolve - 1))
                let shortResult = AyahAligner.identifyAyah(tailWords: shortTail, database: db, currentPages: target.startPage...target.endPage)
                XCTAssertNil(shortResult, "page hint should not be trusted below minWordsForPageAssistedResolve")
                return // found a clean example exercising both halves of the behavior
            }
        }
        XCTFail("no repeated-ayah pair found where a page hint alone disambiguates - data may have changed")
    }

    /// A tie wider than `maxPageAssistedTieSize` must not be resolved by a
    /// page hint, even when exactly one occurrence happens to be on that
    /// page - narrowing a dozen-plus equally-good candidates down to one via
    /// page alone is too weak to trust. The Ar-Rahman refrain (or whichever
    /// ayah repeats most in the current data) is the natural real-world case.
    func testPageHintRefusedWhenTieTooWide() {
        var groups: [String: [Int]] = [:]
        for (idx, a) in db.ayahs.enumerated() where a.groundTruthSkeletonWords.count >= 5 {
            groups[a.groundTruthSkeletonWords.joined(separator: " "), default: []].append(idx)
        }
        guard let wideGroup = groups.values.first(where: { $0.count > AyahAligner.maxPageAssistedTieSize }) else {
            XCTFail("no ayah repeated more than maxPageAssistedTieSize times found - data may have changed")
            return
        }
        let target = db.ayahs[wideGroup[0]]
        let tail = target.groundTruthSkeletonWords
        let result = AyahAligner.identifyAyah(tailWords: tail, database: db, currentPages: target.startPage...target.endPage)
        XCTAssertNil(result, "a page hint should not resolve a tie wider than maxPageAssistedTieSize")
    }

    /// A candidate that shares its opening with another ayah, but strictly
    /// diverges within tolerance once more words are heard, must resolve to
    /// the textually-correct one outright - even when the page hint points
    /// at the other, worse-cost candidate. This is the core fix: page
    /// context must never override better textual evidence.
    func testCostRankingOverridesPageHint() {
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

        // A genuinely repeated ayah, extended a couple of words into
        // whatever actually comes next after *this* occurrence. The two
        // occurrences' real continuations differ, which breaks what would
        // otherwise be a dead tie: the extended tail costs 0 against the
        // correct occurrence but 1-2 against the other (its continuation
        // doesn't match the extra words) - so cost ranking alone should
        // resolve it, even with a page hint actively pointing at the
        // *other*, worse-cost, occurrence. The old "any candidate + page
        // tiebreak" logic would have wrongly trusted that page hint here.
        for indices in cleanPairs {
            let correctIdx = indices[0]
            let wrongIdx = indices[1]
            let correctStart = flatStart(db.ayahs[correctIdx].surah, db.ayahs[correctIdx].ayahNumber)
            let ownCount = db.ayahs[correctIdx].groundTruthSkeletonWords.count
            let extendEnd = min(db.flatWords.count, correctStart + ownCount + 2)
            let tail = db.flatWords[correctStart..<extendEnd].map(\.skeleton)
            guard tail.count == ownCount + 2 else { continue } // need real room to extend into

            let wrong = db.ayahs[wrongIdx]
            let result = AyahAligner.identifyAyah(tailWords: tail, database: db, currentPages: wrong.startPage...wrong.endPage)
            if result?.ayahIndex == correctIdx {
                return // cost ranking alone resolved it, despite a page hint pointing at `wrong`
            }
        }
        XCTFail("no repeated-ayah pair found where extending past the duplicate breaks the tie by cost - data may have changed")
    }

    /// A word that's genuinely unique across the whole Quran (e.g. "تتجافى",
    /// 32:16) must resolve immediately off a single observed word - a cost-0
    /// match with every other candidate strictly worse is real evidence
    /// regardless of tail length, so there must be no blanket minimum-word
    /// gate blocking it. Found dynamically so this tracks real data.
    func testUniqueSingleWordResolvesImmediately() {
        var counts: [String: Int] = [:]
        for w in db.flatWords { counts[w.skeleton, default: 0] += 1 }
        guard let uniqueWord = db.flatWords.first(where: { counts[$0.skeleton] == 1 }) else {
            XCTFail("no globally-unique word found - data may have changed")
            return
        }
        let result = AyahAligner.identifyAyah(tailWords: [uniqueWord.skeleton], database: db, currentPages: nil)
        XCTAssertEqual(
            result?.ayahIndex, uniqueWord.ayahIndex,
            "a globally-unique word should resolve immediately off a single observed word"
        )
    }

    /// `excluding` keeps a previously-rejected ayah from being re-picked,
    /// even as the otherwise-unique best-cost match.
    func testExcludingSkipsRejectedCandidate() {
        let target = ayah(2, 255)
        let tail = Array(target.groundTruthSkeletonWords.suffix(4))
        let withoutExclusion = AyahAligner.identifyAyah(tailWords: tail, database: db, currentPages: nil)
        XCTAssertEqual(withoutExclusion?.ayahIndex, ayahIndex(2, 255))

        let withExclusion = AyahAligner.identifyAyah(tailWords: tail, database: db, currentPages: nil, excluding: [ayahIndex(2, 255)])
        XCTAssertNotEqual(withExclusion?.ayahIndex, ayahIndex(2, 255), "excluded ayah must never be returned")
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

    // MARK: - Tashkeel/segmentation equivalence

    /// A ta marbuta (ة) pronounced in construct state sounds identical to a
    /// plain ta (ت) - "نِعْمَةَ اللَّهِ" (33:9, word 6/22) is correctly
    /// recited with a /t/ sound, which the ASR spells "نِعْمَتَ". Must
    /// resolve as a clean match with correct tashkeel, not a substituted or
    /// wrong-tashkeel word.
    func testTaMarbutaConnectedPronunciationCountsAsCorrect() {
        let start = flatStart(33, 9)
        let ayahA = ayah(33, 9)
        let wordIndex = 5 // "نِعْمَةَ"

        // Simulate the ASR spelling the connected-state ة as ت - the raw
        // text it would actually emit for this word.
        let rawObservedWord = foldTaMarbutaForComparison(ayahA.groundTruthWords[wordIndex])
        var observed = ayahA.groundTruthSkeletonWords
        var observedTashkeel = ayahA.groundTruthWords
        observed[wordIndex] = normalizeArabicSkeleton(rawObservedWord)
        observedTashkeel[wordIndex] = rawObservedWord

        let result = AyahAligner.advance(
            observed: observed, observedTashkeel: observedTashkeel, confirmedPosition: start, floor: start, database: db
        )
        guard case .forward = result.outcome else {
            return XCTFail("expected forward progress, got \(result.outcome)")
        }
        let step = result.commitSteps.first { $0.flatIndex == start + wordIndex }
        XCTAssertEqual(step?.step.kind, .match, "connected ta marbuta must align as the same word, not a substitution")
        XCTAssertEqual(step?.tashkeelOK, true, "connected-state ة sounding like ت is correct recitation, not wrong tashkeel")
    }

    /// The ASR sometimes splits a single ground-truth word into two
    /// transcribed tokens (e.g. "إِنَّ" + "مَا" for "إِنَّمَا", 2:11 word
    /// 9/11). Must resolve as one merged match at the right position, not a
    /// substitution/extra pair, and must not throw off the following word's
    /// position.
    func testSplitWordMergesIntoSingleCandidateMatch() {
        let start = flatStart(2, 11)
        let ayahA = ayah(2, 11)
        let wordIndex = 8 // "إِنَّمَا"

        // Split the real ground-truth word right before its meem, so the
        // two halves are guaranteed to skeleton-fold and tashkeel-concat
        // back to exactly the original (no hand-typed diacritics to get
        // subtly wrong).
        let word = ayahA.groundTruthWords[wordIndex]
        let scalars = Array(word.unicodeScalars)
        guard let meemIndex = scalars.firstIndex(where: { $0.value == 0x0645 }) else {
            return XCTFail("expected ayah word to contain a meem to split on")
        }
        let firstHalf = String(String.UnicodeScalarView(Array(scalars[..<meemIndex])))
        let secondHalf = String(String.UnicodeScalarView(Array(scalars[meemIndex...])))

        var observed = ayahA.groundTruthSkeletonWords
        var observedTashkeel = ayahA.groundTruthWords
        observed.replaceSubrange(wordIndex...wordIndex, with: [normalizeArabicSkeleton(firstHalf), normalizeArabicSkeleton(secondHalf)])
        observedTashkeel.replaceSubrange(wordIndex...wordIndex, with: [firstHalf, secondHalf])

        let result = AyahAligner.advance(
            observed: observed, observedTashkeel: observedTashkeel, confirmedPosition: start, floor: start, database: db
        )
        guard case .forward = result.outcome else {
            return XCTFail("expected forward progress, got \(result.outcome)")
        }
        let step = result.commitSteps.first { $0.flatIndex == start + wordIndex }
        XCTAssertEqual(step?.step.kind, .match, "a word split across two ASR tokens must still resolve as a single match")
        XCTAssertEqual(step?.tashkeelOK, true)
        let nextWord = result.commitSteps.first { $0.flatIndex == start + wordIndex + 1 }
        XCTAssertEqual(nextWord?.step.kind, .match, "the word after the split must not drift off position")
    }

    // MARK: - Provisional-state bookkeeping

    func testProvisionalUpdateTransitions() {
        // Not provisional -> passthrough regardless of outcome.
        let passthrough = AyahAligner.provisionalUpdate(isProvisional: false, wordsRemaining: 0, outcome: .forward, commitSteps: [])
        XCTAssertFalse(passthrough.isProvisional)
        XCTAssertFalse(passthrough.shouldReopen)

        // Provisional + frozen -> reopen, not just sit frozen.
        let reopened = AyahAligner.provisionalUpdate(isProvisional: true, wordsRemaining: 3, outcome: .frozen, commitSteps: [])
        XCTAssertTrue(reopened.shouldReopen)

        // Provisional + enough matches -> confirmed.
        let matchSteps: [(flatIndex: Int, step: AyahAligner.Step, tashkeelOK: Bool?)] = (0..<4).map {
            (flatIndex: $0, step: AyahAligner.Step(kind: .match, observedIndex: $0, candidateIndex: $0), tashkeelOK: true)
        }
        let confirmed = AyahAligner.provisionalUpdate(isProvisional: true, wordsRemaining: 4, outcome: .forward, commitSteps: matchSteps)
        XCTAssertFalse(confirmed.isProvisional)
        XCTAssertFalse(confirmed.shouldReopen)

        // A substitute counts toward verification too - forward alignment
        // holding at all is the real signal, not word-level cleanliness.
        let subSteps: [(flatIndex: Int, step: AyahAligner.Step, tashkeelOK: Bool?)] = [
            (flatIndex: 0, step: AyahAligner.Step(kind: .substitute, observedIndex: 0, candidateIndex: 0), tashkeelOK: false)
        ]
        let stillProvisional = AyahAligner.provisionalUpdate(isProvisional: true, wordsRemaining: 4, outcome: .forward, commitSteps: subSteps)
        XCTAssertTrue(stillProvisional.isProvisional)
        XCTAssertEqual(stillProvisional.wordsRemaining, 3)
        XCTAssertFalse(stillProvisional.shouldReopen)
    }

    // MARK: - Verification leniency

    func testPositionBasedLeniencyThreshold() {
        XCTAssertFalse(AyahAligner.shouldScore(wordsSinceIdentification: 0))
        XCTAssertFalse(AyahAligner.shouldScore(wordsSinceIdentification: 1))
        XCTAssertTrue(AyahAligner.shouldScore(wordsSinceIdentification: 2))
        XCTAssertTrue(AyahAligner.shouldScore(wordsSinceIdentification: 5))
    }
}
