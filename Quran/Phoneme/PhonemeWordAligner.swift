import Foundation

enum PhonemeWordStatus: Equatable {
    case match
    case mismatch
    case deleted
}

struct PhonemeWordCheckResult {
    let surah: Int
    let ayah: Int
    let wordIndex: Int  // 0-based, within the ayah (matches the corpus's per-ayah word list)
    let globalWordIndex: Int
    let expectedPhonemes: String
    let actualPhonemes: String?  // nil for a fully skipped/deleted word
    let status: PhonemeWordStatus
    let similarity: Double
    /// Real Uthmani script word(s) -- nil if `word_text_map.json` couldn't
    /// confidently map this specific word.
    let wordText: String?
    /// True when `wordText` is the *same* real written word as the
    /// previous settled result (a muqatta'at split) -- consumers must treat
    /// a `wordTextContinuesPrevious` run as one logical word.
    let wordTextContinuesPrevious: Bool
    /// Only meaningful when `status == .deleted`: true when this word was
    /// never recited because the session simply ended before reaching it
    /// (`RecitationChecker.finish()`'s forced flush), as opposed to a live,
    /// mid-recitation skip the DP alignment caught in real time (the
    /// reciter's audio jumped straight from one word to a later one, with
    /// nothing matching this word's expected phonemes in between). Set by
    /// `RecitationChecker.onWordSettled`, not at construction -- always
    /// `false` here. Consumers (see `RecitationProgressTracker`) use this to
    /// gate strict mode on a genuine live skip without also gating on
    /// "the reciter just stopped for now".
    var isSessionEndDeletion = false
}

private struct PendingWord {
    let entry: PhonemeGlobalWordEntry
    let startOffset: Int  // start scalar offset in expectedBuffer (inclusive)
    let endOffset: Int    // end scalar offset in expectedBuffer (exclusive)
}

/// Character-level (Option B) online alignment - port of
/// `qrc/align/word_aligner.py`'s `IncrementalWordAligner`.
///
/// The ASR alphabet has no space/word-boundary token, so we can't buffer
/// ASR output between word emissions. Instead we DP-align the growing
/// recognized-phoneme buffer against a known-in-advance concatenation of
/// upcoming expected words' phonemes, and use the DP's own convergence (how
/// far the alignment frontier has moved past a word's boundary) to decide
/// when that word's verdict is safe to emit.
///
/// Known limitation (inherited from `qrc`): because there are no ASR-side
/// word boundaries, a whole extra recited word not in the expected text
/// can't be reported as its own "inserted" entry -- it shows up as inflated
/// `actualPhonemes` on the nearest expected word, surfaced as a
/// low-similarity mismatch.
final class IncrementalWordAligner {
    private let corpus: PhonemeCorpus
    private let settings: PhonemeSettings
    private var onWordResult: (PhonemeWordCheckResult) -> Void

    private var actualBuffer: [Unicode.Scalar] = []
    private var pendingWords: [PendingWord] = []
    private var expectedBuffer: [Unicode.Scalar] = []
    private var nextGlobalWordIdx: Int?
    private(set) var rollingSimilarityEma: Double = 1.0

    /// The actualPhonemes of the last word settled with genuine content
    /// (match/mismatch, not deleted) -- used to detect a repeated word
    /// bleeding into the next one, see `stripRepeatedPrefix`.
    private var lastSettledActual: [Unicode.Scalar]?
    /// The isolatedPhonemeText of the last word settled as a genuine
    /// *match* (not mismatch/deleted) -- used to recover cross-word
    /// tajweed-liaison bleed into the next word, see `stripLiaisonBleed`.
    /// nil whenever the previous word wasn't a clean match: with no
    /// confirmed idea what was actually said, there's nothing trustworthy
    /// to attribute a leading bleed to.
    private var lastSettledIsolated: [Unicode.Scalar]?

    /// The tail of the last word's *connected* phonemeText that its
    /// standalone form doesn't have -- e.g. tanween fatha's nasal "ن",
    /// present in "قَلِۦۦلَن" but not the standalone "قَلِۦۦلَاا". Set only
    /// when that word settled via its standalone form (`matchedIsolated`):
    /// the connected form's own extra tail was never heard as part of it,
    /// and can show up recognized late, bled into the *next* word's actual
    /// content instead -- see `stripConnectedTailBleed`. nil whenever the
    /// previous word matched its connected form outright (nothing unheard
    /// to have bled) or wasn't a clean match at all.
    private var lastSettledConnectedBleed: [Unicode.Scalar]?

    private let lookaheadWords = 8
    private let minRepeatOverlap = 2
    /// Large input is processed in small increments, not dumped into
    /// `actualBuffer` all at once -- `expectedBuffer` only ever holds
    /// `lookaheadWords` words (a few dozen characters); letting
    /// `actualBuffer` grow far past that before a settle attempt runs would
    /// make the DP explain a huge buffer against a tiny one, and the DP
    /// itself becomes slow at that size.
    private let feedChunkChars = 20

    /// Exposed so `RecitationChecker` can rescue not-yet-settled text
    /// across a backtrack reroute -- mirrors `qrc`'s `aligner.actual_buffer`.
    var actualBufferText: String { actualBuffer.scalarString }

    /// The bleed-stripping context describing whatever word settled right
    /// before whatever's pending now -- see `lastSettledActual`/
    /// `lastSettledIsolated`/`lastSettledConnectedBleed`'s own docs.
    /// Exposed so `RecitationChecker.pinToGate` can preserve it across a
    /// strict-mode re-pin -- see `localize(_:preservingBleedContext:)`.
    struct BleedContext {
        let actual: [Unicode.Scalar]?
        let isolated: [Unicode.Scalar]?
        let connectedBleed: [Unicode.Scalar]?
    }
    var currentBleedContext: BleedContext {
        BleedContext(actual: lastSettledActual, isolated: lastSettledIsolated, connectedBleed: lastSettledConnectedBleed)
    }

    init(corpus: PhonemeCorpus, settings: PhonemeSettings, onWordResult: @escaping (PhonemeWordCheckResult) -> Void) {
        self.corpus = corpus
        self.settings = settings
        self.onWordResult = onWordResult
    }

    /// Lets `RecitationChecker` wire its own settled-word callback after
    /// construction, so that callback can capture `self` without a
    /// chicken-and-egg init ordering problem.
    func setOnWordResult(_ callback: @escaping (PhonemeWordCheckResult) -> Void) {
        onWordResult = callback
    }

    /// `preservingBleedContext`: normally a fresh localize means a genuine
    /// jump to a new position, where whatever word used to precede the
    /// current one no longer does -- discarding the bleed context is
    /// correct there. Strict mode's own re-pin (`RecitationChecker.pinToGate`)
    /// is different: it keeps re-targeting the *same* still-mismatching
    /// word, so the word genuinely preceding it hasn't changed at all.
    /// Confirmed live: without this, a legitimate cross-word tajweed bleed
    /// (a trailing elongation/liaison lagging from the previous word into
    /// this one, e.g. "هُۥۥۥۥوَعدَ" instead of "وَعدَ") could never be
    /// stripped on a re-pin cycle, even once the reciter said the pinned
    /// word perfectly correctly -- `lastSettledIsolated`/
    /// `lastSettledConnectedBleed` (what `stripLiaisonBleed`/
    /// `stripConnectedTailBleed` need) get wiped to nil on every single
    /// `localize()`, permanently disabling those heuristics for as long as
    /// the pin holds, and looking indistinguishable from being stuck.
    func localize(_ globalWordIdx: Int, preservingBleedContext context: BleedContext? = nil) {
        nextGlobalWordIdx = globalWordIdx
        actualBuffer = []
        pendingWords = []
        expectedBuffer = []
        rollingSimilarityEma = 1.0
        lastSettledActual = context?.actual
        lastSettledIsolated = context?.isolated
        lastSettledConnectedBleed = context?.connectedBleed
        refillExpected()
    }

    /// A reciter repeating a word (self-correction, memorization practice)
    /// leaves the repeat's trailing characters attributed to the *next*
    /// word instead, since the DP has no way to know they're a repeat
    /// rather than new content. Strips the longest prefix of `actual`
    /// that's also a suffix of the previously settled word's actual
    /// content (min 2 chars, to avoid stripping a coincidental
    /// single-character overlap).
    private func stripRepeatedPrefix(_ actual: [Unicode.Scalar]) -> [Unicode.Scalar] {
        guard let last = lastSettledActual, !last.isEmpty, !actual.isEmpty else { return actual }
        let maxOverlap = min(last.count, actual.count)
        var length = maxOverlap
        while length >= minRepeatOverlap {
            if last.suffix(length).elementsEqual(actual.prefix(length)) {
                return Array(actual.dropFirst(length))
            }
            length -= 1
        }
        return actual
    }

    /// A word recited in its own standalone (waqf) form leaves its
    /// liaison-absorbed trailing content attributed to the *next* word
    /// instead. Strips the longest prefix of `actual` that's also a suffix
    /// of the *previous settled word's own* isolated-pronunciation
    /// phonemes. Unlike `stripRepeatedPrefix`, a 1-char overlap is trusted
    /// here: it's a specific word's own known standalone pronunciation, not
    /// arbitrary preceding text, and the caller still requires the
    /// stripped result to exactly match this word's own expected phonemes
    /// before adopting it.
    private func stripLiaisonBleed(_ actual: [Unicode.Scalar]) -> [Unicode.Scalar] {
        guard let last = lastSettledIsolated, !last.isEmpty, !actual.isEmpty else { return actual }
        let maxOverlap = min(last.count, actual.count)
        var length = maxOverlap
        while length >= 1 {
            if last.suffix(length).elementsEqual(actual.prefix(length)) {
                return Array(actual.dropFirst(length))
            }
            length -= 1
        }
        return actual
    }

    /// How many of the next word's own leading characters can plausibly be
    /// recognized *before* the previous word's delayed connected-only tail
    /// (see `lastSettledConnectedBleed`) finally resolves -- the nasal
    /// resonance of a dropped tanween noon, say, is a trailing acoustic
    /// artifact the ASR may only settle on a beat after it's moved on to
    /// the next word's own onset. Small and fixed, not the whole word: this
    /// is only meant to absorb that short recognition lag, not go hunting
    /// for a coincidental later occurrence of the same character(s).
    private let connectedBleedSearchSlack = 4

    /// The last word's connected-only tail showing up recognized late,
    /// injected into the *next* word's actual content a few characters in
    /// (however many of that word's own leading characters the ASR
    /// resolved before the delayed tail did) rather than necessarily right
    /// at the very front. Removes the first occurrence of that tail found
    /// within `connectedBleedSearchSlack` characters of the start of
    /// `actual`, if any -- unlike `stripLiaisonBleed`'s suffix-vs-prefix
    /// overlap, this searches for the bled content verbatim, since it's a
    /// specific known short string (e.g. one nasal `ن`), not an arbitrary
    /// trailing run. Also absorbs any further immediate repeats of the
    /// bleed's own last character: `trySettleDroppableTrailing` settles the
    /// previous word the moment its shortened form matches, without
    /// waiting to see whether more of a tajweed-length run (gemination,
    /// elongation) was still coming -- if so, that whole run ends up
    /// unclaimed and bleeds forward too, not just one instance of it.
    ///
    /// Tries the *whole* bleed first, then progressively shorter trailing
    /// suffixes of it down to just its last character. A multi-character
    /// bleed (a tanween's short vowel plus its nasal `ن`, e.g. "ُن") isn't
    /// always recognized in full -- confirmed live: the ASR emitted only
    /// the trailing `ن` of a damma-tanween's "ُن" tail, dropping the vowel
    /// entirely, and the old exact-whole-bleed search never found it since
    /// "ن" alone never appears as a substring equal to the 2-character
    /// bleed. The dropped leading vowel is coarticulated and easily
    /// swallowed; the trailing nasal consonant is the acoustically salient
    /// part and the one most likely to survive alone -- so a shorter
    /// suffix is checked only once the full bleed fails, same trust level
    /// `stripLiaisonBleed` already gives a 1-character overlap of a known,
    /// specific (not arbitrary) previous-word artifact.
    private func stripConnectedTailBleed(_ actual: [Unicode.Scalar]) -> [Unicode.Scalar] {
        guard let bleed = lastSettledConnectedBleed, !bleed.isEmpty else { return actual }
        var length = bleed.count
        while length >= 1 {
            let sub = Array(bleed.suffix(length))
            defer { length -= 1 }
            guard actual.count >= sub.count else { continue }
            let maxStart = min(actual.count - sub.count, connectedBleedSearchSlack)
            guard maxStart >= 0 else { continue }
            for start in 0...maxStart where actual[start..<start + sub.count].elementsEqual(sub) {
                var result = actual
                var end = start + sub.count
                let repeatChar = sub[sub.count - 1]
                while end < result.count, result[end] == repeatChar { end += 1 }
                result.removeSubrange(start..<end)
                return result
            }
        }
        return actual
    }

    /// The suffix of `connected` (a word's connected/continued phonemeText
    /// -- what it *would* sound like recited straight through) that
    /// `actual` (what this word actually settled with, however it got
    /// there -- direct match, standalone-form fallback, or the
    /// droppable-trailing fast path) never covered -- e.g. "ن" when actual
    /// is "قَلِۦۦلَ" and connected is "قَلِۦۦلَن". Both sides collapsed
    /// first so tajweed-length variation (madd repeats) never masquerades
    /// as a divergence. Only trusted when `actual` collapses to a genuine
    /// *prefix* of `connected` -- a divergence partway through is a real
    /// phoneme mismatch (a different word's audio), not a dropped tail,
    /// and has nothing trustworthy to attribute forward.
    private func connectedTailBleed(actual: [Unicode.Scalar], connected: String) -> [Unicode.Scalar] {
        let a = PhonemeNormalize.collapseRuns(actual)
        let c = PhonemeNormalize.collapseRuns(connected.phonemeScalars)
        var i = 0
        while i < a.count, i < c.count, a[i] == c[i] { i += 1 }
        guard i == a.count, i < c.count else { return [] }
        return Array(c[i...])
    }

    private func refillExpected() {
        guard let next = nextGlobalWordIdx else { return }
        var idx = next + pendingWords.count
        while pendingWords.count < lookaheadWords {
            guard let entry = corpus.wordAt(idx) else { break }
            let start = expectedBuffer.count
            expectedBuffer.append(contentsOf: entry.phonemeText.phonemeScalars)
            pendingWords.append(PendingWord(entry: entry, startOffset: start, endOffset: expectedBuffer.count))
            idx += 1
        }
    }

    func feedTokens(_ tokens: [PhonemeToken]) {
        let text = tokens.filter { $0.symbol != "<blank>" }.map(\.symbol).joined()
        feedText(text)
    }

    /// Feed raw recognized phoneme characters directly -- used to replay
    /// text the locator already consumed while localizing, so those words
    /// aren't silently dropped.
    func feedText(_ text: String) {
        let scalars = text.phonemeScalars
        var start = 0
        while start < scalars.count {
            let end = min(start + feedChunkChars, scalars.count)
            actualBuffer.append(contentsOf: scalars[start..<end])
            refillExpected()
            trySettle()
            start = end
        }
    }

    private func wordIndexForOffset(_ offset: Int) -> Int {
        // bisect_right over pendingWords' end offsets.
        var lo = 0, hi = pendingWords.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if pendingWords[mid].endOffset <= offset {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return min(lo, pendingWords.count - 1)
    }

    private func trySettle() {
        while !pendingWords.isEmpty, !actualBuffer.isEmpty {
            let result = PhonemeAlignDP.editDistanceWithBackpointers(actualBuffer, expectedBuffer)
            let lastRow = result.dp[actualBuffer.count]
            let boundary = pendingWords[0].endOffset
            let jStar = PhonemeAlignDP.argmin(lastRow, preferringBoundary: boundary)
            if jStar - boundary >= settings.settleLookaheadChars {
                let path = PhonemeAlignDP.traceback(result.bp, actualBuffer.count, jStar)
                emitFirstWord(path)
                continue
            }

            if trySettleContinuedForm(boundary: boundary) { continue }
            if trySettleDroppableTrailing(boundary: boundary) { continue }

            break
        }
    }

    /// `expectedBuffer` always queues an ayah-final word's *paused*
    /// `phonemeText` (see `PhonemeGlobalWordEntry.continuedPhonemeText`'s
    /// doc), so a reciter who instead continues straight into the next
    /// ayah produces audio that matches a different -- often differently
    /// sized -- spelling than what's queued for it. The ordinary DP above
    /// can then sit short of `boundary` until enough of the *next* word's
    /// audio arrives to force it past, which is exactly the "last word of
    /// the ayah only appears after the first word of the next one" lag
    /// (worst for a noon-ending whose idgham/ikhfa/iqlab liaison makes the
    /// paused and continued spellings diverge most). Re-running the DP
    /// with just this one word's span swapped to its continued form lets
    /// it settle as soon as *that* form's own audio is in, with no
    /// dependency on the next word at all.
    private func trySettleContinuedForm(boundary: Int) -> Bool {
        guard let continuedText = pendingWords[0].entry.continuedPhonemeText else { return false }
        return trySettleAltForm(continuedText.phonemeScalars, boundary: boundary, logLabel: "continued-form")
    }

    /// A word whose actual audio ends exactly where a forgivable trailing
    /// character (a short vowel or an alif-madd elongation -- see
    /// `PhonemeNormalize.isDroppableWordFinal`) would begin shouldn't sit
    /// waiting for that specific character's arrival before settling: a
    /// subtle trailing sound like tanween nasalization or vowel elongation
    /// can lag the ASR's own decode by several real seconds (confirmed via
    /// a live capture -- 33:18's ayah-final "قَلِيلًا" sat unsettled from
    /// ~10s of audio in until ~13s, waiting on a "ن" that was ultimately
    /// recognized *after* the next ayah's own first characters). Tries each
    /// of the word's own known forms (default, standalone, continued) with
    /// its trailing forgivable run stripped, mirroring
    /// `trySettleContinuedForm`'s alt-expected-buffer technique -- the
    /// eventual match verdict still runs through `PhonemeNormalize`
    /// (`finalizeSettledWord`), this only changes *when* the word settles.
    private func trySettleDroppableTrailing(boundary: Int) -> Bool {
        let entry = pendingWords[0].entry
        let forms = [entry.phonemeText, entry.isolatedPhonemeText, entry.continuedPhonemeText].compactMap { $0 }
        for form in forms {
            var scalars = form.phonemeScalars
            guard let last = scalars.last, PhonemeNormalize.isDroppableWordFinal(last) else { continue }
            while scalars.last == last { scalars.removeLast() }
            guard !scalars.isEmpty else { continue }
            if trySettleAltForm(scalars, boundary: boundary, logLabel: "droppable-trailing") { return true }
        }
        return false
    }

    /// Shared by `trySettleContinuedForm` and `trySettleDroppableTrailing`:
    /// tries settling word0 against `altFormScalars` (that word's own
    /// alternate rendering) instead of the default `expectedBuffer`, using
    /// the same "append the normal lookahead after it, settle-check against
    /// its own boundary, then truncate ownership at that boundary"
    /// technique either way.
    private func trySettleAltForm(_ altFormScalars: [Unicode.Scalar], boundary: Int, logLabel: String) -> Bool {
        let firstWord = pendingWords[0]
        var altExpected = altFormScalars
        altExpected.append(contentsOf: expectedBuffer[boundary...])
        let altBoundary = altFormScalars.count

        let altResult = PhonemeAlignDP.editDistanceWithBackpointers(actualBuffer, altExpected)
        let altLastRow = altResult.dp[actualBuffer.count]
        let altJStar = PhonemeAlignDP.argmin(altLastRow, preferringBoundary: altBoundary)
        guard altJStar - altBoundary >= settings.settleLookaheadChars else { return false }
//        print("[aligner] \(logLabel) fast path settled word \(firstWord.entry.globalWordIdx) (surah \(firstWord.entry.surah) ayah \(firstWord.entry.ayah) word \(firstWord.entry.localWordIdx))")

        let path = PhonemeAlignDP.traceback(altResult.bp, actualBuffer.count, altJStar)
        var actualChars: [Unicode.Scalar] = []
        var consumedACount = 0
        var jConsumed = 0
        // Mirrors `wordIndexForOffset`'s own clamp-to-word-0-when-nothing-
        // else-is-pending behavior: an insertA step's fallback ownership
        // (`jConsumed`, a *count*, not a real expected-buffer index) lands
        // exactly on `altBoundary` right after word 0's own span is fully
        // consumed, which is genuinely ambiguous -- "the tail of this
        // word's content" vs. "noise before the next word". When there's
        // no real next word queued in `altExpected` at all (single
        // remaining pending word), there's nothing to hand it to but this
        // word, so never cut it off there.
        let hasFollowingWord = pendingWords.count > 1
        for step in path {
            let ownershipJ = step.j ?? jConsumed
            if hasFollowingWord, ownershipJ >= altBoundary { break }

            switch step.op {
            case .match:
                actualChars.append(actualBuffer[step.i!])
                consumedACount += 1
                jConsumed += 1
            case .insertA:
                actualChars.append(actualBuffer[step.i!])
                consumedACount += 1
            case .deleteA:
                jConsumed += 1
            }
        }

        finalizeSettledWord(firstWord: firstWord, actualChars: actualChars, consumedACount: consumedACount)
        return true
    }

    private func emitFirstWord(_ path: [PhonemeAlignDP.Step]) {
        let firstWord = pendingWords[0]
        var actualChars: [Unicode.Scalar] = []
        var consumedACount = 0
        var jConsumed = 0

        for step in path {
            let ownershipJ = step.j ?? jConsumed
            let ownerWord = wordIndexForOffset(ownershipJ)
            if ownerWord > 0 { break }

            switch step.op {
            case .match:
                actualChars.append(actualBuffer[step.i!])
                consumedACount += 1
                jConsumed += 1
            case .insertA:
                actualChars.append(actualBuffer[step.i!])
                consumedACount += 1
            case .deleteA:
                jConsumed += 1
            }
        }

        finalizeSettledWord(firstWord: firstWord, actualChars: actualChars, consumedACount: consumedACount)
    }

    private func finalizeSettledWord(firstWord: PendingWord, actualChars: [Unicode.Scalar], consumedACount: Int) {
        var actualPhonemes: [Unicode.Scalar]? = actualChars.isEmpty ? nil : actualChars
        let expectedPhonemes = firstWord.entry.phonemeText
        let isolatedPhonemes = firstWord.entry.isolatedPhonemeText
        let continuedPhonemes = firstWord.entry.continuedPhonemeText
        let waslElidedForms = PhonemeNormalize.waslElidedForms(phonemeText: expectedPhonemes, wordText: firstWord.entry.wordText)
        var matchedIsolated = false
        var matchedContinued = false
        var matchedWaslElided: String?

        // Checks a candidate against all of this word's own valid forms --
        // connected (default), standalone/paused, ayah-final continued, and
        // hamzat-wasl-elided -- same priority order either way. Shared by
        // the raw `actual` check and, below, each bleed-cleanup candidate:
        // a word recited with a brief pause right after it comes out in its
        // own standalone pronunciation, which can differ from the corpus's
        // connected-recitation form (or, at an ayah's end, its continued
        // form differs from the always-paused `phoneme_text`) -- and that's
        // just as true of a candidate that only became legible once a
        // previous word's bled-forward tail was stripped off the front.
        func matchForms(_ candidate: [Unicode.Scalar]) -> (matched: Bool, isolated: Bool, continued: Bool, waslElided: String?) {
            let text = candidate.scalarString
            if PhonemeNormalize.phonemesMatch(expectedPhonemes, text) {
                return (true, false, false, nil)
            }
            if let isolated = isolatedPhonemes, PhonemeNormalize.phonemesMatch(isolated, text) {
                return (true, true, false, nil)
            }
            if let continued = continuedPhonemes, PhonemeNormalize.phonemesMatch(continued, text) {
                // The mirror image, for an ayah's own last word: phoneme_text
                // there always assumes a pause, but continuing straight into
                // the next ayah is equally valid and some words' forms
                // genuinely differ (e.g. tanween fatha).
                return (true, false, true, nil)
            }
            if let waslElided = waslElidedForms.first(where: { PhonemeNormalize.phonemesMatch($0, text) }) {
                // This word's own hamzat-wasl elided (see
                // waslElidedForms) -- a reciter who continued straight out
                // of the previous word instead of pausing before this one.
                return (true, false, false, waslElided)
            }
            return (false, false, false, nil)
        }

        if let actual = actualPhonemes {
            let rawMatch = matchForms(actual)
            if rawMatch.matched {
                matchedIsolated = rawMatch.isolated
                matchedContinued = rawMatch.continued
                matchedWaslElided = rawMatch.waslElided
            } else {
                // Repeat-prefix stripping is a fallback for an otherwise-
                // mismatched word, never applied to content that already
                // matches. Only adopt a candidate that actually produces a
                // match, against any of this word's own forms above --
                // not just the default connected one.
                let candidates = [stripRepeatedPrefix(actual), stripConnectedTailBleed(actual), stripLiaisonBleed(actual)]
                for candidate in candidates where candidate != actual {
                    let m = matchForms(candidate)
                    guard m.matched else { continue }
                    actualPhonemes = candidate.isEmpty ? nil : candidate
                    matchedIsolated = m.isolated
                    matchedContinued = m.continued
                    matchedWaslElided = m.waslElided
                    break
                }
            }
        }

        let similarityReference: String
        if matchedIsolated, let isolated = isolatedPhonemes {
            similarityReference = isolated
        } else if matchedContinued, let continued = continuedPhonemes {
            similarityReference = continued
        } else if let waslElided = matchedWaslElided {
            similarityReference = waslElided
        } else {
            similarityReference = expectedPhonemes
        }
        let similarity: Double
        if let actual = actualPhonemes {
            similarity = PhonemeNormalize.phonemeSimilarity(similarityReference, actual.scalarString)
        } else {
            similarity = 0.0
        }

        let status: PhonemeWordStatus
        if actualPhonemes == nil {
            status = .deleted
        } else if matchedIsolated || matchedContinued || matchedWaslElided != nil || PhonemeNormalize.phonemesMatch(expectedPhonemes, actualPhonemes!.scalarString) {
            status = .match
        } else {
            status = .mismatch
        }

        if let actual = actualPhonemes {
            lastSettledActual = actual
        }
        lastSettledIsolated = (status == .match) ? isolatedPhonemes?.phonemeScalars : nil
        if status == .match, let actual = actualPhonemes {
            let connectedReference = continuedPhonemes ?? expectedPhonemes
            let tail = connectedTailBleed(actual: actual, connected: connectedReference)
            lastSettledConnectedBleed = tail.isEmpty ? nil : tail
        } else {
            lastSettledConnectedBleed = nil
        }

        let alpha = settings.relocalizeEmaAlpha
        rollingSimilarityEma = alpha * similarity + (1 - alpha) * rollingSimilarityEma

        let result = PhonemeWordCheckResult(
            surah: firstWord.entry.surah,
            ayah: firstWord.entry.ayah,
            wordIndex: firstWord.entry.localWordIdx,
            globalWordIndex: firstWord.entry.globalWordIdx,
            expectedPhonemes: expectedPhonemes,
            actualPhonemes: actualPhonemes?.scalarString,
            status: status,
            similarity: similarity,
            wordText: firstWord.entry.wordText,
            wordTextContinuesPrevious: firstWord.entry.wordTextContinuesPrevious
        )

        // Trim: drop word 0 and shift remaining pending words' offsets down.
        let shift = firstWord.endOffset
        actualBuffer = Array(actualBuffer.dropFirst(consumedACount))
        expectedBuffer = Array(expectedBuffer.dropFirst(shift))
        pendingWords = pendingWords.dropFirst().map {
            PendingWord(entry: $0.entry, startOffset: $0.startOffset - shift, endOffset: $0.endOffset - shift)
        }
        nextGlobalWordIdx = firstWord.entry.globalWordIdx + 1
        refillExpected()

        onWordResult(result)
    }

    func confidenceCollapsed() -> Bool {
        rollingSimilarityEma < settings.relocalizeEmaThreshold
    }

    /// Force-settle every currently-pending word (end of session/ayah/Quran).
    /// Deliberately not one big forced alignment against the whole pending
    /// window (targeting the very end of `expectedBuffer`) -- that lets the
    /// DP "spread" genuinely-recited characters thin to help cover words
    /// with zero audio, truncating the last real word. Instead, each
    /// iteration either settles a word the *natural* (unforced) alignment
    /// already fully covers, or -- for the one word straddling where the
    /// actual audio trails off -- forces just up to that word's own
    /// boundary (not further).
    func flush() {
        while !pendingWords.isEmpty, !actualBuffer.isEmpty {
            let result = PhonemeAlignDP.editDistanceWithBackpointers(actualBuffer, expectedBuffer)
            let lastRow = result.dp[actualBuffer.count]
            let jStar = PhonemeAlignDP.argmin(lastRow)
            let boundary = pendingWords[0].endOffset
            let jTarget = jStar >= boundary ? jStar : boundary
            let path = PhonemeAlignDP.traceback(result.bp, actualBuffer.count, jTarget)
            emitFirstWord(path)
        }

        // Counted, not `while !pendingWords.isEmpty`: emitDeletedWord calls
        // refillExpected, which would otherwise keep pulling in new words
        // forever (there's always more Quran text) instead of just
        // draining what was actually pending when flush() was called.
        let remaining = pendingWords.count
        for _ in 0..<remaining {
            emitDeletedWord()
        }
    }

    private func emitDeletedWord() {
        let firstWord = pendingWords[0]
        // A skipped word breaks the physical adjacency stripLiaisonBleed /
        // stripConnectedTailBleed rely on -- nothing was actually recited
        // here to bleed from.
        lastSettledIsolated = nil
        lastSettledConnectedBleed = nil
        let result = PhonemeWordCheckResult(
            surah: firstWord.entry.surah,
            ayah: firstWord.entry.ayah,
            wordIndex: firstWord.entry.localWordIdx,
            globalWordIndex: firstWord.entry.globalWordIdx,
            expectedPhonemes: firstWord.entry.phonemeText,
            actualPhonemes: nil,
            status: .deleted,
            similarity: 0.0,
            wordText: firstWord.entry.wordText,
            wordTextContinuesPrevious: firstWord.entry.wordTextContinuesPrevious
        )

        let shift = firstWord.endOffset
        expectedBuffer = Array(expectedBuffer.dropFirst(shift))
        pendingWords = pendingWords.dropFirst().map {
            PendingWord(entry: $0.entry, startOffset: $0.startOffset - shift, endOffset: $0.endOffset - shift)
        }
        nextGlobalWordIdx = firstWord.entry.globalWordIdx + 1
        refillExpected()

        onWordResult(result)
    }
}
