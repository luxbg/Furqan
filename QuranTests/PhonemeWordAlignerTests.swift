import XCTest
@testable import Quran

/// Port of `qrc/tests/test_word_aligner.py`'s regression tests, using a
/// small synthetic corpus (not the real bundled one) so each scenario is
/// isolated and exact - these exist specifically to verify the *logic*
/// (isolated/continued-form fallback, liaison-bleed/repeat stripping) is
/// correct independent of any real ASR/DP-attribution noise.
final class PhonemeWordAlignerTests: XCTestCase {
    /// Minimal stand-in corpus exposing only what `IncrementalWordAligner` needs.
    private func makeCorpus(
        words: [String],
        isolated: [String?]? = nil,
        continued: [String?]? = nil,
        wordTexts: [String?]? = nil
    ) -> PhonemeCorpus {
        let iso = isolated ?? Array(repeating: nil, count: words.count)
        let cont = continued ?? Array(repeating: nil, count: words.count)
        let texts = wordTexts ?? Array(repeating: nil, count: words.count)
        let entries = zip(zip(zip(words, iso), cont), texts).enumerated().map { i, pair -> PhonemeGlobalWordEntry in
            let (((word, isolatedText), continuedText), wordText) = pair
            return PhonemeGlobalWordEntry(
                globalWordIdx: i, surah: 1, ayah: 1, localWordIdx: i,
                phonemeText: word, wordText: wordText,
                isolatedPhonemeText: isolatedText, continuedPhonemeText: continuedText,
                wordTextContinuesPrevious: false
            )
        }
        var offsets: [Int] = []
        var cursor = 0
        var parts: [String] = []
        for w in words {
            offsets.append(cursor)
            parts.append(w)
            cursor += w.phonemeScalars.count
        }
        return PhonemeCorpus(
            ayahsInOrder: [],
            globalWords: entries,
            corpusText: parts.joined(),
            charOffsets: offsets
        )
    }

    private func tokensFor(_ text: String) -> [PhonemeToken] {
        text.phonemeScalars.enumerated().map { PhonemeToken(symbol: String($0.element), timeS: Float($0.offset)) }
    }

    /// Real case from a live session (33:18 -> 33:19): the corpus's
    /// expected `phonemeText` for every ayah-final word assumes a pause
    /// there ("قَلِۦۦلَاا", tanween fatha as alif-madd). A reciter who
    /// instead continues straight into the next ayah produces the
    /// *continued* form instead ("قَلِۦۦلَن", tanween fatha as a nasalized
    /// "-an") - must match, not mismatch.
    func testAyahFinalWordRecitedWithoutPausingNotFlaggedAsMismatch() {
        let words = ["بسم", "الله", "قَلِۦۦلَاا"]
        let continued: [String?] = [nil, nil, "قَلِۦۦلَن"]
        let corpus = makeCorpus(words: words, continued: continued)
        var results: [PhonemeWordCheckResult] = []
        let settings = PhonemeSettings.default
        let aligner = IncrementalWordAligner(corpus: corpus, settings: settings, onWordResult: { results.append($0) })
        aligner.localize(0)

        let corrupted = [words[0], words[1], "قَلِۦۦلَن"]
        aligner.feedTokens(tokensFor(corrupted.joined()))
        aligner.flush()

        let byIdx = Dictionary(uniqueKeysWithValues: results.map { ($0.wordIndex, $0) })
        XCTAssertEqual(byIdx[2]?.status, .match)
        XCTAssertEqual(byIdx[2]?.actualPhonemes, "قَلِۦۦلَن")
    }

    /// Real case from a live session (33:22 -> 33:23): "وَتَسْلِيمًا"
    /// (tanween fatha) immediately followed by "مِّنَ" - the tanween's
    /// nasal component undergoes idgham bighunna into that leading م,
    /// producing one continuous geminated sound a real ASR splits
    /// unpredictably between the two words. `continuedPhonemeText` (with
    /// one instance of the assimilated م already folded in, per
    /// `build_word_text_map.py`) must still match regardless of exactly
    /// how many extra م's the ASR emits, via tajweed-length collapsing.
    /// Regression for a live-session latency complaint: an ayah-final word
    /// recited without pausing used to only settle once enough of the
    /// *next* ayah's first word had come in too (the DP staying short of
    /// its own boundary against the paused-form `phonemeText` until then).
    /// Feeds only the continued-form audio for the ayah-final word itself
    /// -- nothing from the next word at all -- and asserts it settles
    /// immediately (no `flush()`), proving the fix doesn't depend on a
    /// forced end-of-session settle.
    func testAyahFinalWordSettlesImmediatelyWithoutWaitingOnNextWord() {
        let words = ["بسم", "الله", "قَلِۦۦلَاا", "بَعدَهَا"]
        let continued: [String?] = [nil, nil, "قَلِۦۦلَن", nil]
        let corpus = makeCorpus(words: words, continued: continued)
        var results: [PhonemeWordCheckResult] = []
        let settings = PhonemeSettings.default
        let aligner = IncrementalWordAligner(corpus: corpus, settings: settings, onWordResult: { results.append($0) })
        aligner.localize(0)

        // Only the ayah-final word's own continued-form audio -- not one
        // character of "بَعدَهَا" (the next word).
        let recited = [words[0], words[1], "قَلِۦۦلَن"]
        aligner.feedTokens(tokensFor(recited.joined()))

        let byIdx = Dictionary(uniqueKeysWithValues: results.map { ($0.wordIndex, $0) })
        XCTAssertEqual(byIdx[2]?.status, .match, "should settle from its own audio alone, without needing the next word")
        XCTAssertEqual(byIdx[2]?.actualPhonemes, "قَلِۦۦلَن")
        XCTAssertNil(byIdx[3], "the next word itself must still be untouched/unsettled")
    }

    /// Real live-capture regression (33:18's ayah-final "قَلِيلًا", recited
    /// continuing into 33:19): the ASR's own decode of the tanween nasal
    /// "ن" lagged several real seconds behind the rest of the word --
    /// confirmed via a live capture where the word sat unsettled from
    /// ~10s of audio in until ~13s, the "ن" only surfacing *after* the
    /// next ayah's own opening characters had already streamed in.
    /// `trySettleDroppableTrailing` lets it settle immediately once its
    /// own audio matches the alif-stripped *paused* form instead of
    /// waiting on that specific character at all -- not one character of
    /// the next word's own audio should be needed.
    func testAyahFinalWordSettlesImmediatelyDespiteNeverHearingTanweenNoon() {
        let words = ["بسم", "الله", "قَلِۦۦلَاا", "أَشِحَّةً"]
        let continued: [String?] = [nil, nil, "قَلِۦۦلَن", nil]
        let corpus = makeCorpus(words: words, continued: continued)
        var results: [PhonemeWordCheckResult] = []
        let settings = PhonemeSettings.default
        let aligner = IncrementalWordAligner(corpus: corpus, settings: settings, onWordResult: { results.append($0) })
        aligner.localize(0)

        // قليلا's own audio, missing its connected form's tanween noon
        // entirely -- and nothing at all from the next word.
        let recited = [words[0], words[1], "قَلِۦۦلَ"]
        aligner.feedTokens(tokensFor(recited.joined()))

        let byIdx = Dictionary(uniqueKeysWithValues: results.map { ($0.wordIndex, $0) })
        XCTAssertEqual(byIdx[2]?.status, .match, "the missing noon must be forgiven, not force a wait")
        XCTAssertEqual(byIdx[2]?.actualPhonemes, "قَلِۦۦلَ")
        XCTAssertNil(byIdx[3], "the next word itself must still be untouched/unsettled")
    }

    /// Real live-capture regression (32:2's last word, "ٱلْعَـٰلَمِينَ"):
    /// the corpus's phoneme_text has a 4-repeat madd run ("مِۦۦۦۦن"), but
    /// the actually-recited audio only produced 2 repeats ("مِۦۦن") -- an
    /// entirely normal amount of elongation-duration variance, nothing
    /// mispronounced. Before `PhonemeAlignDP` treated a repeat of the
    /// immediately-preceding character as a free edit, the plain DP's
    /// global-minimum boundary landed 2 characters short of the word's
    /// true end (cheaper to substitute the actual's trailing ن for one of
    /// the expected run's repeats than to explain the whole run), so this
    /// word only ever settled once further audio (in the live capture,
    /// the *next* ayah entirely) piled up enough to tip the arithmetic
    /// back. Feeding only this word's own (slightly-short-of-corpus)
    /// audio must be enough on its own.
    func testWordWithShorterMaddRunThanCorpusSettlesFromItsOwnAudioAlone() {
        let words = ["بسم", "الله", "ررَببِ", "لعَاالَمِۦۦۦۦن", "ءَميَقُۥۥلُۥۥنَ"]
        let corpus = makeCorpus(words: words)
        var results: [PhonemeWordCheckResult] = []
        let settings = PhonemeSettings.default
        let aligner = IncrementalWordAligner(corpus: corpus, settings: settings, onWordResult: { results.append($0) })
        aligner.localize(0)

        // "لعَاالَمِۦۦن" -- only 2 madd repeats, not the corpus's 4 -- and
        // nothing at all from the next word.
        let recited = [words[0], words[1], words[2], "لعَاالَمِۦۦن"]
        aligner.feedTokens(tokensFor(recited.joined()))

        let byIdx = Dictionary(uniqueKeysWithValues: results.map { ($0.wordIndex, $0) })
        XCTAssertEqual(byIdx[3]?.status, .match, "a shorter madd run than the corpus's should still settle from its own audio, without needing the next word")
        XCTAssertNil(byIdx[4], "the next word itself must still be untouched/unsettled")
    }

    /// Real live-capture regression (33:1's last word, "حَكِيمًۭا"): the
    /// reciter *did* pause, producing an exact literal match to the
    /// corpus's own paused phonemeText ("حَكِۦۦمَاا", ending in a doubled
    /// alif-madd "اا") -- no run-length shortfall, no continued-form
    /// divergence, nothing to tolerate at all. It still sat unsettled
    /// until the *next* ayah's audio arrived, because the free-repeat
    /// costs above made stopping *one character short* of the boundary
    /// (explaining actual's own trailing "ا" as a free repeat-insertion
    /// against a one-character-short expected prefix) tie the true
    /// boundary's cost exactly -- and first-occurrence tie-breaking always
    /// prefers the short one. `lastArgmin`'s largest-tied-index
    /// tie-breaking is what actually closes this gap.
    func testExactMatchEndingInADoubledLetterStillReachesTheBoundary() {
        let words = ["بسم", "الله", "حَكِۦۦمَاا", "وَتتَبِع"]
        let corpus = makeCorpus(words: words)
        var results: [PhonemeWordCheckResult] = []
        let settings = PhonemeSettings.default
        let aligner = IncrementalWordAligner(corpus: corpus, settings: settings, onWordResult: { results.append($0) })
        aligner.localize(0)

        // Exact literal match to the word's own expected phonemes -- not
        // one character of the next word.
        let recited = [words[0], words[1], "حَكِۦۦمَاا"]
        aligner.feedTokens(tokensFor(recited.joined()))

        let byIdx = Dictionary(uniqueKeysWithValues: results.map { ($0.wordIndex, $0) })
        XCTAssertEqual(byIdx[2]?.status, .match, "an exact match ending in a doubled letter should still reach its own boundary from its own audio alone")
        XCTAssertEqual(byIdx[2]?.actualPhonemes, "حَكِۦۦمَاا")
        XCTAssertNil(byIdx[3], "the next word itself must still be untouched/unsettled")
    }

    /// `trySettleDroppableTrailing` (added alongside the alif-forgiveness
    /// fix) settles this word the instant its own audio matches the
    /// alif-stripped *paused* form ("وووَتَسلِۦۦمَ"), rather than waiting
    /// to see whether the reciter is still mid-way through the longer
    /// *continued* form's own boundary gemination -- a deliberate
    /// latency/precision trade-off (see `trySettleDroppableTrailing`'s
    /// doc): the match verdict is still correct either way (the dropped
    /// tail is forgiven), it just may not capture every trailing repeat
    /// the ASR eventually emits.
    func testAyahFinalWordSettlesEarlyViaPausedFormDespiteBoundaryGemination() {
        let words = ["بسم", "الله", "وووَتَسلِۦۦمَاا"]
        let continued: [String?] = [nil, nil, "وَتَسلِۦۦمَم"]
        let corpus = makeCorpus(words: words, continued: continued)
        var results: [PhonemeWordCheckResult] = []
        let settings = PhonemeSettings.default
        let aligner = IncrementalWordAligner(corpus: corpus, settings: settings, onWordResult: { results.append($0) })
        aligner.localize(0)

        let corrupted = [words[0], words[1], "وووَتَسلِۦۦمَممم"]
        aligner.feedTokens(tokensFor(corrupted.joined()))
        aligner.flush()

        let byIdx = Dictionary(uniqueKeysWithValues: results.map { ($0.wordIndex, $0) })
        XCTAssertEqual(byIdx[2]?.status, .match)
        XCTAssertEqual(byIdx[2]?.actualPhonemes, "وووَتَسلِۦۦمَ")
    }

    /// The gemination "ممم" left unclaimed by the early settle above isn't
    /// just dropped when a *real* next word follows -- `stripConnectedTailBleed`
    /// absorbs the whole leftover run (not just one "م"), so the next
    /// word's own audio still matches cleanly.
    func testLeftoverGeminationRunBleedingIntoNextWordIsFullyAbsorbed() {
        let words = ["بسم", "الله", "وووَتَسلِۦۦمَاا", "بَعدَهُم"]
        let continued: [String?] = [nil, nil, "وَتَسلِۦۦمَم", nil]
        let corpus = makeCorpus(words: words, continued: continued)
        var results: [PhonemeWordCheckResult] = []
        let settings = PhonemeSettings.default
        let aligner = IncrementalWordAligner(corpus: corpus, settings: settings, onWordResult: { results.append($0) })
        aligner.localize(0)

        // قليلا-style: the word's own audio settles early (missing the
        // gemination tail entirely), then the leftover "ممم" streams in
        // fused with the next word's own real audio.
        aligner.feedTokens(tokensFor([words[0], words[1], "وووَتَسلِۦۦمَ"].joined()))
        aligner.feedTokens(tokensFor("ممم" + "بَعدَهُم"))
        aligner.flush()

        let byIdx = Dictionary(uniqueKeysWithValues: results.map { ($0.wordIndex, $0) })
        XCTAssertEqual(byIdx[2]?.status, .match)
        XCTAssertEqual(byIdx[3]?.status, .match, "the whole leftover gemination run, not just one repeat, must be absorbed")
        XCTAssertEqual(byIdx[3]?.actualPhonemes, "بَعدَهُم")
    }

    /// Real-world regression: قليلا (mid-ayah, not ayah-final) recited
    /// normally, but the ASR never emits its trailing tanween nasal "ن" as
    /// part of its own audio at all -- forgiven against the word's own
    /// standalone form ("قَلِۦۦلَاا", tanween fatha as alif-madd), same
    /// tolerance as a dropped trailing short vowel. The delayed "ن" then
    /// surfaces recognized a couple of characters into the *next* word's
    /// own audio instead of right at its front (enough of that word's own
    /// audio -- "بَ" here -- had to stream in first to give قليلا's own DP
    /// boundary enough pressure to resolve at all) -- must still be
    /// recovered, not just a clean leading case.
    func testDelayedTanweenNoonBleedIntoNextWordIsStripped() {
        let words = ["بسم", "الله", "قَلِۦۦلَن", "بَعدَهُم"]
        let isolated: [String?] = [nil, nil, "قَلِۦۦلَاا", nil]
        let corpus = makeCorpus(words: words, isolated: isolated)
        var results: [PhonemeWordCheckResult] = []
        let settings = PhonemeSettings.default
        let aligner = IncrementalWordAligner(corpus: corpus, settings: settings, onWordResult: { results.append($0) })
        aligner.localize(0)

        // قليلا missing its own trailing "ن" entirely, plus just enough of
        // the next word's own leading audio ("بَ") to push the DP past
        // قليلا's boundary -- none of the delayed "ن" has streamed in yet.
        let firstChunk = [words[0], words[1], "قَلِۦۦلَ", "بَ"]
        aligner.feedTokens(tokensFor(firstChunk.joined()))

        // The delayed "ن", then the rest of the next word's own audio.
        aligner.feedTokens(tokensFor("ن" + "عدَهُم"))
        aligner.flush()

        let byIdx = Dictionary(uniqueKeysWithValues: results.map { ($0.wordIndex, $0) })
        XCTAssertEqual(byIdx[2]?.status, .match, "قليلا's own missing tanween noon must be forgiven against its standalone form")
        XCTAssertEqual(byIdx[2]?.actualPhonemes, "قَلِۦۦلَ")
        XCTAssertEqual(byIdx[3]?.status, .match, "the bled noon landing inside the next word's own audio must still be recovered")
        XCTAssertEqual(byIdx[3]?.actualPhonemes, "بَعدَهُم")
    }

    /// Real-world report: reciting Al-Baqarah continuously, ayah 2 flows
    /// straight into ayah 3's "ٱلَّذِينَ" with no pause between them --
    /// hamzat wasl is only pronounced when a reciter starts fresh on that
    /// word, so the actual audio has no hamza at all ("للَذِۦۦنَ", not the
    /// corpus's ayah-initial-assuming "ءَللَذِۦۦنَ"). Must match, not flag
    /// a phantom hamza mistake.
    func testAyahInitialHamzatWaslWordRecitedWithoutPauseNotFlaggedAsMismatch() {
        let words = ["بسم", "الله", "ءَللَذِۦۦنَ"]
        let wordTexts: [String?] = [nil, nil, "ٱلَّذِينَ"]
        let corpus = makeCorpus(words: words, wordTexts: wordTexts)
        var results: [PhonemeWordCheckResult] = []
        let settings = PhonemeSettings.default
        let aligner = IncrementalWordAligner(corpus: corpus, settings: settings, onWordResult: { results.append($0) })
        aligner.localize(0)

        let recited = [words[0], words[1], "للَذِۦۦنَ"]
        aligner.feedTokens(tokensFor(recited.joined()))
        aligner.flush()

        let byIdx = Dictionary(uniqueKeysWithValues: results.map { ($0.wordIndex, $0) })
        XCTAssertEqual(byIdx[2]?.status, .match, "hamzat wasl elided on a continuous recitation must be forgiven, not flagged")
        XCTAssertEqual(byIdx[2]?.actualPhonemes, "للَذِۦۦنَ")
    }

    /// Real live-capture regression (2:2 -> 2:3, continuous recitation):
    /// the ASR dropped the hamza itself but still emitted a residual
    /// leading fatha ("َللَذِۦۦنَ") rather than silencing the whole
    /// hamza+vowel pair cleanly. Still just "hamza not pronounced", not a
    /// second real pronunciation -- `waslElidedForms` must accept this
    /// variant too.
    func testAyahInitialHamzatWaslWordWithResidualVowelStillMatches() {
        let words = ["بسم", "الله", "ءَللَذِۦۦنَ"]
        let wordTexts: [String?] = [nil, nil, "ٱلَّذِينَ"]
        let corpus = makeCorpus(words: words, wordTexts: wordTexts)
        var results: [PhonemeWordCheckResult] = []
        let settings = PhonemeSettings.default
        let aligner = IncrementalWordAligner(corpus: corpus, settings: settings, onWordResult: { results.append($0) })
        aligner.localize(0)

        let recited = [words[0], words[1], "َللَذِۦۦنَ"]
        aligner.feedTokens(tokensFor(recited.joined()))
        aligner.flush()

        let byIdx = Dictionary(uniqueKeysWithValues: results.map { ($0.wordIndex, $0) })
        XCTAssertEqual(byIdx[2]?.status, .match, "hamza dropped with a residual leading vowel must still be forgiven")
        XCTAssertEqual(byIdx[2]?.actualPhonemes, "َللَذِۦۦنَ")
    }

    /// A word beginning with a *real* hamza (qat', always pronounced --
    /// e.g. "إِنَّ", written with إ not the wasl sign ٱ) reciting without
    /// its hamza is a genuine mistake, not a wasl elision -- must still be
    /// flagged. Guards `waslElidedForm`'s gate on `wordText`'s own leading
    /// character.
    func testRealHamzaWordMissingItsHamzaStillFlaggedAsMismatch() {
        let words = ["بسم", "الله", "ءِننننَ"]
        let wordTexts: [String?] = [nil, nil, "إِنَّ"]
        let corpus = makeCorpus(words: words, wordTexts: wordTexts)
        var results: [PhonemeWordCheckResult] = []
        let settings = PhonemeSettings.default
        let aligner = IncrementalWordAligner(corpus: corpus, settings: settings, onWordResult: { results.append($0) })
        aligner.localize(0)

        let recited = [words[0], words[1], "نننَ"]
        aligner.feedTokens(tokensFor(recited.joined()))
        aligner.flush()

        let byIdx = Dictionary(uniqueKeysWithValues: results.map { ($0.wordIndex, $0) })
        XCTAssertEqual(byIdx[2]?.status, .mismatch, "a real hamza is never elided -- dropping it is a genuine mistake")
    }

    /// Real live-session regression (11:57, "تَضُرُّونَهُۥ شَيْـًٔا"): word2
    /// ends in a droppable doubled madd ("ۥۥ") and settles early via
    /// `trySettleDroppableTrailing`, before its own real trailing "ۥۥ"
    /// audio has arrived. That audio then streams in and correctly bleeds
    /// into word3's actual buffer as a leading "ۥۥ" -- `stripConnectedTailBleed`
    /// strips it fine. But word3 was recited with a pause, so its *own*
    /// content only matches its standalone form ("شَيءَاا"), not the
    /// connected one ("شَيءَن") the old code exclusively re-checked a
    /// debled candidate against -- a debled-but-still-mismatched word
    /// wrongly displayed the *raw*, bleed-contaminated actual too.
    func testBleedStrippedCandidateIsAlsoCheckedAgainstIsolatedForm() {
        let words = ["بسم", "الله", "تَضُررُۥۥنَهُۥۥ", "شَيءَن"]
        let isolated: [String?] = [nil, nil, nil, "شَيءَاا"]
        let corpus = makeCorpus(words: words, isolated: isolated)
        var results: [PhonemeWordCheckResult] = []
        let settings = PhonemeSettings.default
        let aligner = IncrementalWordAligner(corpus: corpus, settings: settings, onWordResult: { results.append($0) })
        aligner.localize(0)

        // Word2's own audio, missing its trailing "ۥۥ" -- settles early via
        // the droppable-trailing fast path.
        aligner.feedTokens(tokensFor([words[0], words[1], "تَضُررُۥۥنَهُ"].joined()))
        // The delayed "ۥۥ" bleeds into word3, which was then recited fully
        // in its own paused/standalone form.
        aligner.feedTokens(tokensFor("ۥۥ" + "شَيءَاا"))
        aligner.flush()

        let byIdx = Dictionary(uniqueKeysWithValues: results.map { ($0.wordIndex, $0) })
        XCTAssertEqual(byIdx[2]?.status, .match)
        XCTAssertEqual(byIdx[3]?.status, .match, "the bled prefix must be stripped, then rechecked against word3's own standalone form")
        XCTAssertEqual(byIdx[3]?.actualPhonemes, "شَيءَاا")
    }
}
