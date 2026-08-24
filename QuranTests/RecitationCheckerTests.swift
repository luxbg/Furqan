import XCTest
@testable import Quran

/// Integration tests against the real bundled phoneme corpus - port of the
/// intent of `qrc`'s `tests/test_pipeline.py` + `tests/test_backtracking.py`.
final class RecitationCheckerTests: XCTestCase {
    static let corpus = try! PhonemeCorpus.loadFromBundle()
    var corpus: PhonemeCorpus { Self.corpus }

    private func tokensFor(_ text: String) -> [PhonemeToken] {
        text.phonemeScalars.enumerated().map { PhonemeToken(symbol: String($0.element), timeS: Float($0.offset)) }
    }

    private func ayahWords(_ surah: Int, _ ayah: Int) -> [String] {
        let entry = corpus.ayahsInOrder.first { $0.ref.surah == surah && $0.ref.ayah == ayah }!
        return entry.words
    }

    private func firstGlobalIdx(_ surah: Int, _ ayah: Int) -> Int {
        corpus.globalWords.first { $0.surah == surah && $0.ayah == ayah && $0.localWordIdx == 0 }!.globalWordIdx
    }

    /// 32:8's last corpus phoneme-word used to be one indivisible unit
    /// covering multiple written words - it must settle as independent
    /// per-word results through the full pipeline (localization included).
    func testMergedAyahVerifiesAsIndependentWordsThroughFullPipeline() {
        let ayahEntries = corpus.globalWords.filter { $0.surah == 32 && $0.ayah == 8 }
        XCTAssertGreaterThan(ayahEntries.count, 1, "sanity: 32:8 should be split into multiple real words in the loaded corpus")

        var results: [PhonemeWordCheckResult] = []
        let checker = RecitationChecker(corpus: corpus, settings: .default, onWordResult: { results.append($0) })
        checker.feedTokens(tokensFor(ayahEntries.map(\.phonemeText).joined()))
        checker.finish()

        let recited = results.filter { $0.surah == 32 && $0.ayah == 8 }
        XCTAssertEqual(recited.count, ayahEntries.count)
        XCTAssertTrue(recited.allSatisfy { $0.status == .match })
        XCTAssertEqual(recited.map(\.wordIndex), Array(0..<ayahEntries.count))
    }

    /// The words consumed while localizing must not be silently dropped and
    /// reported as never-recited once localization completes.
    func testWordsUsedToLocalizeAreNotReportedAsDeleted() {
        let words = ayahWords(112, 1) // Al-Ikhlas: قُل هُوَ للَااهُ ءَحَدڇ
        var results: [PhonemeWordCheckResult] = []
        let checker = RecitationChecker(corpus: corpus, settings: .default, onWordResult: { results.append($0) })
        checker.feedTokens(tokensFor(words.joined()))
        checker.finish()

        let recited = results.filter { $0.surah == 112 && $0.ayah == 1 }
        XCTAssertEqual(recited.count, words.count)
        XCTAssertTrue(recited.allSatisfy { $0.status == .match })
        XCTAssertEqual(recited.map(\.actualPhonemes), words)
    }

    func testLocatorRejectsMatchBeforeFloor() {
        let floorIdx = firstGlobalIdx(112, 2)
        let locator = IncrementalAyahLocator(corpus: corpus, settings: .default)
        locator.minGlobalWordIdx = floorIdx

        var result: PhonemeLocalizeResult?
        for w in ayahWords(112, 1) { // before the floor
            result = locator.addChars(w)
        }

        XCTAssertNil(result)
        XCTAssertEqual(locator.lastRejection, .beforeFloor)
    }

    func testLocatorRejectsMatchBeyondCeiling() {
        let floorIdx = firstGlobalIdx(112, 1)
        let ceilingIdx = firstGlobalIdx(112, 2) - 1
        let locator = IncrementalAyahLocator(corpus: corpus, settings: .default)
        locator.minGlobalWordIdx = floorIdx
        locator.maxGlobalWordIdx = ceilingIdx

        var result: PhonemeLocalizeResult?
        for w in ayahWords(112, 3) { // past the ceiling
            result = locator.addChars(w)
        }

        XCTAssertNil(result)
        XCTAssertEqual(locator.lastRejection, .beyondCeiling)
    }

    func testLocatorAcceptsMatchExactlyAtFloor() {
        let floorIdx = firstGlobalIdx(112, 2)
        let locator = IncrementalAyahLocator(corpus: corpus, settings: .default)
        locator.minGlobalWordIdx = floorIdx

        var result: PhonemeLocalizeResult?
        for w in ayahWords(112, 2) {
            result = locator.addChars(w)
            if result != nil { break }
        }

        XCTAssertEqual(result?.globalWordIdx, floorIdx)
    }

    func testPipelineEndToEndBacktrackScenario() {
        var statuses: [String] = []
        let checker = RecitationChecker(corpus: corpus, settings: .default, onWordResult: { _ in }, onStatus: { statuses.append($0) })

        checker.feedTokens(tokensFor(ayahWords(112, 2).joined()))
        checker.finish()
        XCTAssertEqual(checker.sessionStartGlobalWordIdx, firstGlobalIdx(112, 2))

        // Force relocalization so backtracking can be tested without
        // waiting on the aligner's confidence to organically collapse.
        checker.locator.reset()

        // Ayah 1 is before the session's start -- must fail with a clear reason.
        checker.feedTokens(tokensFor(ayahWords(112, 1).joined()))
        XCTAssertFalse(statuses.contains { $0.hasPrefix("localized: surah 112 ayah 1,") })
        XCTAssertTrue(statuses.contains { $0.contains("can't go back before surah 112 ayah 2") })

        // Ayah 2 (exactly the session start) must succeed.
        checker.locator.reset()
        checker.feedTokens(tokensFor(ayahWords(112, 2).joined()))
        XCTAssertTrue(statuses.contains { $0.hasPrefix("localized: surah 112 ayah 2,") })
    }

    func testBacktrackReroutesWithoutReportingAFalseMismatch() {
        var results: [PhonemeWordCheckResult] = []
        let checker = RecitationChecker(corpus: corpus, settings: .default, onWordResult: { results.append($0) })

        checker.feedTokens(tokensFor((ayahWords(112, 1) + ayahWords(112, 2) + ayahWords(112, 3)).joined()))
        XCTAssertTrue(results.allSatisfy { $0.status == .match }, "\(results)")

        // Go back and recite 112:1 again without an explicit relocalize
        // signal -- the aligner is still expecting 112:4 next.
        checker.feedTokens(tokensFor(ayahWords(112, 1).joined()))
        checker.finish()

        XCTAssertFalse(results.contains { $0.status == .mismatch && $0.surah == 112 && $0.ayah == 4 })
        let ayah1Results = results.filter { $0.surah == 112 && $0.ayah == 1 }
        XCTAssertEqual(ayah1Results.count, 8)
        XCTAssertTrue(ayah1Results.allSatisfy { $0.status == .match })
    }

    /// Regression: a relocalize can rediscover a position already reached
    /// (the EMA-collapse path in particular has no `backtrackMinWordGap`
    /// guard at all, unlike `rerouteIfBacktrack`/`considerAmbientBacktrack`
    /// -- it can land right back where the reciter already was). Confirmed
    /// via a live capture that the replay text can come out missing its own
    /// leading syllable ("يُدَبِّرُ", recited and matched correctly moments
    /// earlier, replayed as "دَببِرُ"), settling as a mismatch on content
    /// that was already known-good -- and with strict mode on, opening a
    /// gate the reciter had no way to ever clear, since repeating the word
    /// correctly just triggers the identical truncation on the next replay.
    func testRelocalizeToAlreadyReachedPositionDoesNotReportSpuriousMismatch() {
        var results: [PhonemeWordCheckResult] = []
        let checker = RecitationChecker(corpus: corpus, settings: .default, onWordResult: { results.append($0) })

        checker.feedTokens(tokensFor((ayahWords(112, 1) + ayahWords(112, 2)).joined()))
        let forwardResults = results.filter { $0.surah == 112 && ($0.ayah == 1 || $0.ayah == 2) }
        XCTAssertTrue(forwardResults.allSatisfy { $0.status == .match }, "\(forwardResults)")

        results = []
        // Force a relocalize (mirrors the EMA-collapse path) that rediscovers
        // 112:1 -- already reached -- but with its own first word's replay
        // text missing its leading scalar, simulating the exact truncation
        // confirmed live.
        checker.locator.reset()
        var word0Scalars = Array(ayahWords(112, 1)[0].phonemeScalars)
        word0Scalars.removeFirst()
        let truncatedWord0 = String(String.UnicodeScalarView(word0Scalars))
        let replayText = ([truncatedWord0] + ayahWords(112, 1).dropFirst() + ayahWords(112, 2)).joined()
        checker.feedTokens(tokensFor(replayText))
        checker.finish()

        XCTAssertFalse(results.contains { $0.surah == 112 && $0.ayah == 1 && $0.wordIndex == 0 && $0.status == .mismatch }, "\(results)")
    }

    /// A word skipped mid-recitation (audio jumps straight from one word to
    /// a later one) settles `.deleted` live -- via the DP alignment itself,
    /// not `finish()`'s forced flush -- and must be flagged as such
    /// (`isSessionEndDeletion == false`) so strict mode can gate on it (see
    /// `RecitationProgressTracker.isGateWorthy`), unlike a `.deleted` word
    /// that's only unreached because the session simply ended.
    func testLiveSkippedWordSettlesAsDeletedWithoutSessionEndFlag() {
        var results: [PhonemeWordCheckResult] = []
        let checker = RecitationChecker(corpus: corpus, settings: .default, onWordResult: { results.append($0) })

        checker.feedTokens(tokensFor(ayahWords(112, 1).joined()))
        // 112:2 word 0 is skipped entirely -- straight to word 1, then into
        // 112:3 for the DP to have enough lookahead to confirm the boundary.
        let ayah2 = ayahWords(112, 2)
        checker.feedTokens(tokensFor(ayah2[1] + ayahWords(112, 3).joined()))

        let skipped = results.first { $0.surah == 112 && $0.ayah == 2 && $0.wordIndex == 0 }
        XCTAssertEqual(skipped?.status, .deleted, "\(results)")
        XCTAssertEqual(skipped?.isSessionEndDeletion, false, "a live skip must not be mistaken for the session just ending")
    }

    /// Contrast case: a word left unrecited only because the session ended
    /// before reaching it (`finish()`'s forced flush) must be flagged
    /// `isSessionEndDeletion == true`, so strict mode does NOT gate on it.
    func testSessionEndDeletionIsFlagged() {
        var results: [PhonemeWordCheckResult] = []
        let checker = RecitationChecker(corpus: corpus, settings: .default, onWordResult: { results.append($0) })

        checker.feedTokens(tokensFor(ayahWords(112, 1).joined()))
        checker.finish()

        let unrecited = results.first { $0.surah == 112 && $0.ayah == 2 && $0.wordIndex == 0 }
        XCTAssertEqual(unrecited?.status, .deleted, "\(results)")
        XCTAssertEqual(unrecited?.isSessionEndDeletion, true)
    }

    // MARK: - Ambient backtrack (feature 2): windowed search

    func testPhonemeSearchWindowCandidatesExcludesMatchesOutsideTheWindow() {
        let floorIdx = firstGlobalIdx(112, 2)
        let ceilingIdx = firstGlobalIdx(112, 4) - 1
        let query = ayahWords(112, 1).joined() // entirely before the window

        let candidates = phonemeSearchWindowCandidates(
            corpus: corpus, query: query, settings: .default,
            minGlobalWordIdx: floorIdx, maxGlobalWordIdx: ceilingIdx,
            confidenceThreshold: 0.5, marginThreshold: 0.0, similarityDelta: 1.0
        )

        XCTAssertNil(candidates, "the window can't see 112:1's own text at all once it's excluded from the search range")
    }

    func testPhonemeSearchWindowCandidatesFindsAMatchInsideTheWindow() {
        let floorIdx = firstGlobalIdx(112, 1)
        let ceilingIdx = firstGlobalIdx(112, 4) - 1
        let query = ayahWords(112, 2).joined()

        let candidates = phonemeSearchWindowCandidates(
            corpus: corpus, query: query, settings: .default,
            minGlobalWordIdx: floorIdx, maxGlobalWordIdx: ceilingIdx,
            confidenceThreshold: 0.5, marginThreshold: 0.0, similarityDelta: 0.05
        )

        XCTAssertEqual(candidates?.first?.globalWordIdx, firstGlobalIdx(112, 2))
    }

    /// Regression: `commitAmbientJump` used to replay `candidate.matchedText`
    /// (a fixed-size tail of the raw ASR history) concatenated with
    /// `aligner.actualBufferText` (the old aligner's own unconsumed tail) --
    /// both suffixes of the exact same character stream ending at "now", so
    /// concatenating them duplicated whatever they overlapped on. Confirmed
    /// (by temporarily reverting the fix) that this cascaded: 3 of the 6
    /// words replayed after the jump came out mismatched, not just the one
    /// right at the jump itself -- the corrupted `lastSettledActual`/buffer
    /// state from one bad word was throwing off the next. With the fix, only
    /// the single word straddling the jump can still show a stale-prefix
    /// artifact (`candidate.matchedText`'s fixed-size window can still mix in
    /// pre-jump characters when little new evidence has accumulated yet --
    /// a separate, narrower, self-healing limitation of the ambient search
    /// window itself, not this replay-duplication bug) -- everything after
    /// it must settle clean. Fed in small increments (not one big
    /// `feedTokens` call) so the ambient path -- which runs continuously,
    /// with no mismatch evidence required -- gets a real chance to fire
    /// before `rerouteIfBacktrack`'s own (already-correct) mismatch-buffer
    /// path would.
    func testAmbientBacktrackReplayDoesNotCascadeMismatches() {
        var results: [PhonemeWordCheckResult] = []
        // Not testing strict mode -- explicitly off so an incidental
        // chunk-boundary mismatch (this test's own comment already
        // tolerates one) drifts forward and settles normally instead of
        // strict mode's own halt-on-mismatch pinning it in place, which
        // would just be testing a different feature.
        var settings = PhonemeSettings.default
        settings.strictMode = false
        let checker = RecitationChecker(corpus: corpus, settings: settings, onWordResult: { results.append($0) })

        checker.feedTokens(tokensFor((ayahWords(112, 1) + ayahWords(112, 2) + ayahWords(112, 3) + ayahWords(112, 4)).joined()))
        let forwardCount = results.count
        XCTAssertTrue(results.allSatisfy { $0.status == .match }, "\(results)")

        // Backtrack ambiently (no relocalize signal, no prior mismatch) to
        // repeat 112:1+112:2 -- fed in small, realistic-sized chunks (not
        // one big call) so the continuous ambient path, not
        // `rerouteIfBacktrack`'s own mismatch-buffer path, gets a real
        // chance to catch it.
        let backtrackScalars = Array((ayahWords(112, 1) + ayahWords(112, 2)).joined().phonemeScalars)
        var i = 0
        while i < backtrackScalars.count {
            let end = min(i + 6, backtrackScalars.count)
            let chunk = String(String.UnicodeScalarView(backtrackScalars[i..<end]))
            checker.feedTokens(tokensFor(chunk))
            i = end
        }
        checker.finish()

        let secondPassResults = results[forwardCount...].filter { $0.surah == 112 && ($0.ayah == 1 || $0.ayah == 2) }
        XCTAssertFalse(secondPassResults.isEmpty)
        XCTAssertTrue(secondPassResults.dropFirst().allSatisfy { $0.status == .match }, "corruption must not cascade past the word right at the jump: \(secondPassResults)")
    }

    func testOnRelocalizedFiresOnEveryGenuineRelocalizationWithTheNewPosition() {
        var relocalizedTo: [Int] = []
        let checker = RecitationChecker(
            corpus: corpus, settings: .default,
            onWordResult: { _ in },
            onRelocalized: { relocalizedTo.append($0) }
        )

        checker.feedTokens(tokensFor((ayahWords(112, 1) + ayahWords(112, 2) + ayahWords(112, 3)).joined()))
        checker.finish()
        XCTAssertEqual(relocalizedTo.first, firstGlobalIdx(112, 1), "initial localization fires onRelocalized too")

        // Backtrack within the session's own already-reached range (must
        // stay >= sessionStartGlobalWordIdx, per the locator's floor).
        checker.locator.reset()
        checker.feedTokens(tokensFor(ayahWords(112, 1).joined()))

        XCTAssertEqual(relocalizedTo.last, firstGlobalIdx(112, 1))
    }

    // MARK: - Strict mode halt (feature 3)

    /// The core ask: a mismatch must fully halt forward recognition, not
    /// just the display -- reciting the *rest of the ayah* correctly after
    /// a mistake must not get silently consumed as progress on words past
    /// the wrong one. Only the exact word said wrong, repeated correctly,
    /// counts as passing it. 112:1 recites correctly first, in one go, to
    /// actually localize (a lone word or two isn't enough raw text to
    /// clear the locator's own `minTriggerChars` -- unrelated to strict
    /// mode, just how localization works) -- the mismatch then lands on
    /// 112:2's own first word.
    func testStrictModeHaltsRecognitionPastAMismatchedWordUntilItsCorrected() {
        var results: [PhonemeWordCheckResult] = []
        var settings = PhonemeSettings.default
        settings.strictMode = true
        let checker = RecitationChecker(corpus: corpus, settings: settings, onWordResult: { results.append($0) })

        let word0Idx = firstGlobalIdx(112, 2)
        checker.feedTokens(tokensFor(ayahWords(112, 1).joined()))
        // 112:2 word 0 wrong (garbage), then keep going straight through
        // the rest of 112:2 and into 112:3 as if nothing happened.
        checker.feedTokens(tokensFor("ططططططططططططططط"))
        checker.feedTokens(tokensFor((ayahWords(112, 2).dropFirst() + ayahWords(112, 3)).joined()))
        checker.finish()

        XCTAssertTrue(results.contains { $0.globalWordIndex == word0Idx && $0.status == .mismatch }, "\(results)")
        // Nothing past the mismatched word may ever settle while it's
        // still unresolved -- the rest of the recitation must instead
        // keep getting DP-aligned against that word itself (repeatedly
        // mismatching/skipping there), not attributed to words further on.
        XCTAssertFalse(results.contains { $0.globalWordIndex > word0Idx }, "\(results)")
    }

    /// Once the halted word is finally said correctly, recognition resumes
    /// normally from right after it.
    func testStrictModeResumesOnceTheHaltedWordIsCorrected() {
        var results: [PhonemeWordCheckResult] = []
        var settings = PhonemeSettings.default
        settings.strictMode = true
        let checker = RecitationChecker(corpus: corpus, settings: settings, onWordResult: { results.append($0) })

        let word0Idx = firstGlobalIdx(112, 2)
        checker.feedTokens(tokensFor(ayahWords(112, 1).joined()))
        checker.feedTokens(tokensFor("ططططططططططططططط"))
        XCTAssertTrue(results.contains { $0.globalWordIndex == word0Idx && $0.status == .mismatch }, "\(results)")

        // Say the rest of the recitation correctly, starting with the word just missed.
        checker.feedTokens(tokensFor((ayahWords(112, 2) + ayahWords(112, 3)).joined()))
        checker.finish()

        XCTAssertTrue(results.contains { $0.globalWordIndex == word0Idx && $0.status == .match }, "\(results)")
        XCTAssertTrue(results.contains { $0.globalWordIndex == word0Idx + 1 }, "recognition must resume past the corrected word: \(results)")
    }

    /// A genuine backtrack must still be honored while halted -- confirmed
    /// with the user this is the one way out besides correcting the word.
    /// Mirrors `testCloseBacktrackStillReroutesEvenThoughFartherThanAmbientGap`'s
    /// own already-proven pattern (a mismatch's own evidence feeds
    /// `rerouteIfBacktrack`, which runs -- and can still succeed -- before
    /// strict mode's pin ever gets a chance to hold the display at 112:3).
    func testStrictModeStillAllowsABacktrackWhileHalted() {
        var results: [PhonemeWordCheckResult] = []
        var settings = PhonemeSettings.default
        settings.strictMode = true
        let checker = RecitationChecker(corpus: corpus, settings: settings, onWordResult: { results.append($0) })

        checker.feedTokens(tokensFor((ayahWords(112, 1) + ayahWords(112, 2)).joined()))
        XCTAssertTrue(results.allSatisfy { $0.status == .match }, "\(results)")
        results = []

        // Redo 112:2 instead of continuing into 112:3 -- a real backtrack.
        checker.feedTokens(tokensFor(ayahWords(112, 2).joined()))
        checker.finish()

        let repeatedAyah2 = results.filter { $0.surah == 112 && $0.ayah == 2 }
        XCTAssertFalse(repeatedAyah2.isEmpty, "the backtrack must actually be recognized as 112:2 again, not stuck retrying 112:3: \(results)")
        XCTAssertTrue(repeatedAyah2.contains { $0.status == .match }, "\(results)")
    }

    /// Real live-capture regression (2:14, reciting straight through with
    /// no actual backtrack at all): with `ambientBacktrackMinWordGap` at its
    /// old shared value of 0, the ambient search's own "far enough away"
    /// guard was a no-op (`abs(...) >= 0` always holds), so a coincidental
    /// nearby fuzzy match during completely ordinary forward recitation
    /// could commit as a spurious "backtrack" -- confirmed live: word 9
    /// ("شَيَـٰطِينِهِمْ") settled correctly, then got relocalized right
    /// back onto itself moments later and re-processed a second time (that
    /// reprocessing then came out wrong, since the replay text was never
    /// actually a repeat). Fed one whole word at a time -- realistically
    /// sized, and deliberately never splits a word's own audio across two
    /// calls, so this isolates the ambient path itself (which runs on every
    /// call regardless of match/mismatch) without conflating it with
    /// `rerouteIfBacktrack`'s own separate, deliberately-accepted close-range
    /// risk (see `backtrackMinWordGap`'s doc) from a genuinely mismatched
    /// chunk boundary.
    func testOrdinaryForwardRecitationNeverTriggersASpuriousNearbyRelocalize() {
        var statuses: [String] = []
        var results: [PhonemeWordCheckResult] = []
        let checker = RecitationChecker(corpus: corpus, settings: .default, onWordResult: { results.append($0) }, onStatus: { statuses.append($0) })

        for word in ayahWords(2, 14) {
            checker.feedTokens(tokensFor(word))
        }
        checker.finish()

        XCTAssertEqual(statuses.filter { $0.hasPrefix("localized:") }.count, 1, "only the initial localization -- no spurious relocalize during ordinary forward recitation: \(statuses)")
        let counts = Dictionary(grouping: results.filter { $0.surah == 2 && $0.ayah == 14 }, by: { $0.wordIndex }).mapValues { $0.count }
        XCTAssertTrue(counts.allSatisfy { $0.value == 1 }, "no word should be reported twice: \(counts)")
    }

    /// Real-world report: Al-Ma'idah 5:1 and 5:2 both open with the
    /// identical phrase "يَـٰٓأَيُّهَا ٱلَّذِينَ ءَامَنُوا۟". Reciting 5:1
    /// (22 words) straight through into 5:2 repeats that phrase again as
    /// 5:2's own opening -- a perfectly ordinary forward match, no mistake
    /// at all -- but the ambient search, run unconditionally, could still
    /// find 5:1's *own* identical opening as a confident "backtrack"
    /// candidate, far outside `ambientBacktrackMinWordGap`'s reach (a
    /// distance-based gap can't help when the false match is a whole
    /// 22-word ayah away). `ambientSkipWhenConfidenceAtLeast` fixes this at
    /// the source: skip the search entirely whenever forward tracking is
    /// already succeeding.
    func testRepeatedOpeningPhraseAcrossAyahsIsNotMistakenForABacktrack() {
        var statuses: [String] = []
        var results: [PhonemeWordCheckResult] = []
        // Not testing strict mode -- explicitly off so an incidental
        // chunk-boundary mismatch drifts forward and settles normally
        // instead of strict mode's own halt-on-mismatch pinning it in
        // place, which (confirmed live) gives the ambient search far more
        // low-confidence chances to fire than it ever gets in ordinary
        // operation, right into the exact false-positive this test guards
        // against.
        var settings = PhonemeSettings.default
        settings.strictMode = false
        let checker = RecitationChecker(corpus: corpus, settings: settings, onWordResult: { results.append($0) }, onStatus: { statuses.append($0) })

        let scalars = Array((ayahWords(5, 1) + ayahWords(5, 2)).joined().phonemeScalars)
        var i = 0
        while i < scalars.count {
            let end = min(i + 6, scalars.count)
            checker.feedTokens(tokensFor(String(String.UnicodeScalarView(scalars[i..<end]))))
            i = end
        }
        checker.finish()

        XCTAssertEqual(statuses.filter { $0.hasPrefix("localized:") }.count, 1, "only the initial localization -- 5:2 repeating 5:1's opening phrase must not look like a backtrack: \(statuses)")
        // Not asserting every word matches -- the crude fixed-size chunking
        // (needed to give the ambient path, which runs on every chunk, a
        // real chance to misfire mid-word) can itself introduce a stray
        // chunk-boundary mismatch or two, unrelated to what this test
        // actually checks. What must never happen is the SAME word being
        // reported twice (the signature of a spurious relocalize replaying
        // already-settled content).
        let recited = results.filter { $0.surah == 5 && ($0.ayah == 1 || $0.ayah == 2) }
        let counts = Dictionary(grouping: recited, by: { AyahWord(ayah: $0.ayah, word: $0.wordIndex) }).mapValues { $0.count }
        XCTAssertTrue(counts.allSatisfy { $0.value == 1 }, "no word should be reported twice: \(counts)")
    }

    private struct AyahWord: Hashable { let ayah: Int; let word: Int }

    /// `ambientBacktrackMinWordGap`'s stricter floor (see above) must not
    /// cost genuine responsiveness to a *close* backtrack -- a reciter
    /// redoing just the last short ayah, not restarting the whole passage.
    /// This only has to travel through `rerouteIfBacktrack` (mismatch
    /// evidence first, then search), which deliberately kept its own gap at
    /// 0 -- unlike the ambient path, it never runs without that evidence
    /// already in hand. A transient mismatch on the word the repeat first
    /// lands on (113:3's own first word) is expected and fine -- that
    /// mismatch is literally the evidence the reroute needs to notice the
    /// backtrack in the first place, not a bug -- the property this test
    /// actually cares about is that the repeat then gets correctly
    /// recognized as 112:2 again, not left blobbed into that mismatch.
    func testCloseBacktrackStillReroutesEvenThoughFartherThanAmbientGap() {
        var results: [PhonemeWordCheckResult] = []
        let checker = RecitationChecker(corpus: corpus, settings: .default, onWordResult: { results.append($0) })

        checker.feedTokens(tokensFor((ayahWords(112, 1) + ayahWords(112, 2)).joined()))
        XCTAssertTrue(results.allSatisfy { $0.status == .match }, "\(results)")

        // Redo just 112:2 (a 2-word distance backtrack -- well under
        // `ambientBacktrackMinWordGap`'s default of 8) instead of moving on
        // to 112:3.
        checker.feedTokens(tokensFor(ayahWords(112, 2).joined()))
        checker.finish()

        let secondPass = results.drop(while: { !($0.surah == 112 && $0.ayah == 2 && $0.status == .match) }).dropFirst()
        let repeatedAyah2 = secondPass.filter { $0.surah == 112 && $0.ayah == 2 }
        XCTAssertFalse(repeatedAyah2.isEmpty, "the repeat must actually be recognized as 112:2 again, not blobbed into a mismatch: \(results)")
        XCTAssertTrue(repeatedAyah2.allSatisfy { $0.status == .match }, "\(results)")
    }
}
