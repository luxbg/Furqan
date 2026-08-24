import Foundation

/// Wires ASR token stream -> locator -> aligner -> callback - port of
/// `qrc/pipeline.py`'s `RecitationChecker`.
///
/// Session lifecycle is continuous (one long-running stream, no resets):
/// the checker rolls forward across ayah boundaries, and relocalizes in
/// place if the aligner's rolling confidence collapses (e.g. the reciter
/// jumped to an unexpected ayah), without discarding the whole session.
final class RecitationChecker {
    private let corpus: PhonemeCorpus
    private let settings: PhonemeSettings
    private let onWordResult: (PhonemeWordCheckResult) -> Void
    private let onStatus: (String) -> Void
    /// Fired whenever a genuine relocalization happens (initial localize,
    /// `rerouteIfBacktrack`, `beginRelocalize`'s eventual re-match, the
    /// ambient backtrack below, or the strict-mode regate probe) -- never
    /// for ordinary forward word-by-word settling. `RecitationSession` uses
    /// this to release a stuck strict-mode gate when the reciter has
    /// genuinely moved backward of it (see `onLocalized`).
    private let onRelocalized: (Int) -> Void

    let locator: IncrementalAyahLocator
    private let aligner: IncrementalWordAligner

    private static let recentTextCap = 200
    private var recentText = ""

    /// Backtracking floor: the session's true start, set once on the first
    /// successful localization and never updated again. The *effective*
    /// floor used for matching (`locator.minGlobalWordIdx`) is kept dynamic
    /// -- see `advanceProgress` -- but never below this.
    private(set) var sessionStartGlobalWordIdx: Int?
    /// Ceiling: the furthest position actually reached this session --
    /// relocalization can go back to redo an earlier ayah, but can't skip
    /// ahead into ayahs never yet recited. Advances as words settle
    /// (match/mismatch only -- never a `deleted` word) or as a
    /// (re)localization reaches a new position.
    private(set) var maxGlobalWordIdxReached: Int?
    private let backtrackWindowWords: Int
    private var flushing = false
    /// Set by `onLocalized` (any source: reroute, regate probe, ambient
    /// backtrack, or EMA-collapse relocalize) and checked/reset around each
    /// `feedTokens` call -- a reroute/regate can fire *synchronously* mid-way
    /// through `aligner.feedTokens(tokens)` (via `onWordSettled`'s own
    /// callback chain), so by the time control returns to `feedTokens`,
    /// `recentText` still reflects the same already-consumed/relocalized
    /// content. Without this guard, `considerAmbientBacktrack` (which reads
    /// `recentText` unconditionally) would independently rediscover the very
    /// same backtrack a second time and commit a redundant, spurious jump on
    /// top of the one that already just happened.
    private var relocalizedDuringCurrentCall = false
    /// Accumulates actualPhonemes from consecutive mismatches only, for the
    /// backtrack-vs-mistake check -- see `rerouteIfBacktrack`.
    private var suspectBuffer = ""
    /// Set to `maxGlobalWordIdxReached` (as it stood just *before* the jump)
    /// for the duration of `onLocalized`'s replay -- see `onWordSettled`.
    private var replayFloor: Int?

    private struct AmbientBacktrackState {
        let committedGlobalWordIdx: Int
        let committedAtMaxReached: Int
    }
    /// Tracks an in-flight ambient backtrack jump so `considerAmbientBacktrack`
    /// suppresses itself for a short grace window right after committing one
    /// -- the aligner is already tracking forward from a fresh jump, off a
    /// full DP alignment of everything recited since; re-running the same
    /// raw 20-char-tail fuzzy search on top of that (an earlier "refinement"
    /// feature used to do exactly this) has no visibility into whether that
    /// forward tracking is already succeeding, and confirmed in practice to
    /// occasionally mis-fire a second, spurious jump moments after a
    /// perfectly good first one -- landing on a truncated slice of
    /// whatever's *currently* being recited (unrelated to the actual
    /// backtrack), replaying it against the wrong expected words, and (with
    /// strict mode on) permanently gating the display on a word the reciter
    /// never actually got wrong. See `considerAmbientBacktrack`.
    private var ambientState: AmbientBacktrackState?

    init(
        corpus: PhonemeCorpus,
        settings: PhonemeSettings,
        onWordResult: @escaping (PhonemeWordCheckResult) -> Void,
        onStatus: @escaping (String) -> Void = { _ in },
        onRelocalized: @escaping (Int) -> Void = { _ in }
    ) {
        self.corpus = corpus
        self.settings = settings
        self.onWordResult = onWordResult
        self.onStatus = onStatus
        self.onRelocalized = onRelocalized

        self.locator = IncrementalAyahLocator(corpus: corpus, settings: settings)
        // Words/page is only an estimate (real Mushaf pagination isn't in
        // the corpus data) -- computed once from the corpus's own average.
        let wordsPerPage = Double(corpus.globalWords.count) / Double(settings.mushafTotalPages)
        self.backtrackWindowWords = Int((wordsPerPage * Double(settings.backtrackWindowPages)).rounded())

        self.aligner = IncrementalWordAligner(corpus: corpus, settings: settings, onWordResult: { _ in })
        // `onWordSettled` needs `self`, so wire the real callback after init
        // (chicken-and-egg: the aligner must exist before `self` is fully
        // initialized, but its callback needs `self`).
        self.aligner.setOnWordResult { [weak self] result in
            self?.onWordSettled(result)
        }
    }

    func feedTokens(_ tokens: [PhonemeToken]) {
        let text = tokens.filter { $0.symbol != "<blank>" }.map(\.symbol).joined()
        guard !text.isEmpty else { return }
        let combined = recentText + text
        let combinedScalars = combined.phonemeScalars
        recentText = combinedScalars.suffix(Self.recentTextCap).scalarString

        if locator.state == .localized {
            relocalizedDuringCurrentCall = false
            aligner.feedTokens(tokens)
            if relocalizedDuringCurrentCall {
                // Already handled synchronously (reroute/regate) during the
                // call above -- re-running ambient/EMA checks against the
                // same now-stale recentText would double-relocalize.
                return
            }
            if aligner.confidenceCollapsed() {
                beginRelocalize()
                return
            }
            considerAmbientBacktrack()
            return
        }

        if let result = locator.addChars(text) {
            onLocalized(globalWordIdx: result.globalWordIdx, matchedText: result.matchedText)
        } else if let rejection = locator.lastRejection {
            reportRejection(rejection)
        }
    }

    /// Call once at end of session/audio to force-settle any tail words.
    func finish() {
        if locator.state == .localized {
            flushing = true
            aligner.flush()
            flushing = false
        }
    }

    private func beginRelocalize() {
        onStatus("lost track of recitation -- relocalizing")
        ambientState = nil
        locator.seedForRelocalize(recentText: recentText)
    }

    private func onWordSettled(_ resultIn: PhonemeWordCheckResult) {
        var result = resultIn
        if result.status == .deleted {
            // See `PhonemeWordCheckResult.isSessionEndDeletion` -- `flushing`
            // is only ever true for the duration of `finish()`'s forced
            // flush, so this distinguishes "the session just ended before
            // reaching this word" from a genuine live skip the DP caught
            // mid-recitation.
            result.isSessionEndDeletion = flushing
        } else {
            advanceProgress(result.globalWordIndex)
        }

        if let floor = replayFloor, result.globalWordIndex <= floor, result.status == .mismatch {
            // This word's position was already confidently reached BEFORE
            // the relocalize now replaying it -- a mismatch here means the
            // replay's own text reconstruction failed to recover content
            // that was already known-good, not new evidence the reciter
            // got it wrong. Confirmed via a live capture: a relocalize's
            // replay text was missing its own leading syllable ("يُدَبِّرُ"
            // settled moments earlier, then replayed as "دَببِرُ"), and with
            // strict mode on this opened a gate the reciter had no way to
            // ever clear -- repeating the word correctly just triggers the
            // exact same truncation on the next replay, since the *replay
            // mechanism* is what's wrong, not the recitation. Silently
            // drop it rather than reporting a mismatch that was never
            // genuine; the original settle already reported the truth.
            return
        }

        // A mismatch might not be a mistake at all -- the reciter may have
        // jumped to an earlier ayah within the backtrack window rather than
        // mispronounced this one. Never while flush() is running: calling
        // locator/aligner localize() here would reset aligner state out
        // from under flush()'s own in-progress loop.
        if result.status == .match {
            suspectBuffer = ""
        } else if result.status == .mismatch, let actual = result.actualPhonemes {
            suspectBuffer += actual
        }

        let gateWorthy = !flushing && settings.strictMode && isStrictGateWorthy(result)
        if gateWorthy, result.status == .mismatch {
            // `pinToGate` below is about to wipe the aligner's own
            // in-flight buffer with no replay (see its own doc for why) --
            // rescue it into `suspectBuffer` first, the same accumulator
            // `rerouteIfBacktrack` searches with, so pinning back onto the
            // same word doesn't cost evidence that would otherwise have
            // kept accumulating as the aligner drifted forward on its own
            // (which is how `rerouteIfBacktrack` found a genuine backtrack
            // before pinning existed). Deliberately scoped to `.mismatch`
            // only, not every gate-worthy result -- widening this to a
            // `.deleted` live-skip's own (unattributed, noisier) leftover
            // was confirmed live to trigger false-positive backtracks
            // during otherwise-ordinary forward recitation (two ayahs
            // sharing an identical opening phrase).
            suspectBuffer += aligner.actualBufferText
        }

        if !flushing, result.status == .mismatch, rerouteIfBacktrack(result) {
            return
        }

        onWordResult(result)

        if gateWorthy {
            pinToGate(result.globalWordIndex)
        }
    }

    /// Strict mode only: mirrors `RecitationProgressTracker.isGateWorthy` --
    /// same predicate (a genuine mismatch, or a live mid-recitation skip,
    /// but never a word left unrecited only because the session ended)
    /// -- needed here too since strict mode's halt-on-mistake behavior is
    /// implemented at this layer (pinning the aligner itself), while the
    /// tracker's own copy governs what actually gates the *display*.
    private func isStrictGateWorthy(_ result: PhonemeWordCheckResult) -> Bool {
        result.status == .mismatch || (result.status == .deleted && !result.isSessionEndDeletion)
    }

    /// Strict mode's halt: re-pins the aligner right back onto the word
    /// that just failed to settle correctly, so it keeps expecting that
    /// exact word next instead of drifting forward into whatever comes
    /// after it -- confirmed with the user: a wrong word must fully halt
    /// further recognition until either that exact word is said correctly
    /// (which is then just an entirely ordinary forward `.match`, needing
    /// no special-casing) or the reciter genuinely backtracks. Backtracking
    /// out of a pin is handled by `rerouteIfBacktrack` above: the rescue
    /// step right before this is called (see `onWordSettled`) keeps feeding
    /// it real mismatch evidence across repeated pin cycles even though the
    /// aligner itself never drifts forward through several words the way it
    /// used to. `considerAmbientBacktrack`'s own continuous search is
    /// deliberately left out of that job here -- see point 2 below.
    ///
    /// Deliberately calls `aligner.localize` directly rather than going
    /// through `onLocalized` (unlike every other jump in this file) --
    /// two reasons, both confirmed by an actual failure while building
    /// this:
    /// 1. `onLocalized` replays `aligner.actualBufferText` (the old,
    ///    about-to-be-reset aligner's own unconsumed tail) into the fresh
    ///    aligner. Unlike a genuine backtrack, that leftover is exactly the
    ///    audio the DP *just* considered and decided doesn't belong to
    ///    this word (that's what made it settle as mismatch/deleted in the
    ///    first place) -- replaying the same content back against the same
    ///    word is deterministic and reaches the same non-match verdict,
    ///    which re-pins again with the same still-unconsumed leftover: an
    ///    infinite synchronous loop that blew the stack in practice
    ///    (confirmed via a live crash during a live-skip test and a
    ///    chunk-boundary-mismatch test). Skipping the replay only loses at
    ///    most one small `feedChunkChars`-sized fragment already in
    ///    flight; the reciter's next real audio is fed fresh against the
    ///    re-pinned word as usual.
    /// 2. `aligner.localize` also resets `rollingSimilarityEma` back to
    ///    1.0, which keeps `considerAmbientBacktrack`'s own confidence
    ///    guard closed right after a pin, same as it would be right after
    ///    any other fresh localize. Tried the opposite (preserving the low
    ///    post-mismatch confidence across a pin, to give the continuous
    ///    ambient search more chances to run while stuck) and confirmed it
    ///    live-fires false-positive backtracks: two ayahs sharing an
    ///    identical opening phrase, recited straight through with no
    ///    mistake at all, still relocalized several times over on nothing
    ///    but chunk-boundary noise, because a stuck pin now gave the
    ///    ambient search far more low-confidence chances to stumble onto
    ///    the *other* ayah's identical opening than it would ever get in
    ///    ordinary (non-strict) operation. `rerouteIfBacktrack`'s own
    ///    evidence-gated search (point above) is deliberately the only
    ///    backtrack path strict mode leans on while pinned.
    private func pinToGate(_ globalWordIdx: Int) {
        aligner.localize(globalWordIdx)
    }

    /// Runs continuously (every `feedTokens` call, no prior mismatch
    /// evidence needed) against the raw recognized-character stream, unlike
    /// `rerouteIfBacktrack` which only searches once several mismatched
    /// words have already accumulated -- this is what makes a genuine
    /// backtrack feel instant instead of lagging by several words. Windowed
    /// to the same backtrack range via `phonemeSearchWindowCandidates`
    /// (cheap: searches only that window, not the whole Quran), with
    /// stricter confidence thresholds than the base reroute since this runs
    /// with no corroborating mismatch evidence at all. Among candidates
    /// that tie within `ambientTieBreakSimilarityDelta`, prefers the
    /// closest/latest one. Suppressed for `ambientRefineMaxWords` words
    /// right after a jump commits (see `ambientState`) -- deliberately does
    /// NOT re-search and second-guess a jump that's already settling in.
    private func considerAmbientBacktrack() {
        guard settings.ambientBacktrackEnabled, !flushing, let maxIdx = maxGlobalWordIdxReached else { return }
        // Forward tracking is already succeeding -- nothing to second-guess.
        // See `ambientSkipWhenConfidenceAtLeast`'s own doc for why this
        // matters: without it, a phrase repeated verbatim across two
        // ayahs/surahs (e.g. Al-Ma'idah 1 and 2's shared opening) can find
        // its *own* earlier occurrence as a perfectly-confident "backtrack"
        // candidate even though the current position already explains the
        // audio just fine.
        guard aligner.rollingSimilarityEma < settings.ambientSkipWhenConfidenceAtLeast else { return }

        if let state = ambientState {
            if maxIdx - state.committedAtMaxReached <= settings.ambientRefineMaxWords {
                return
            }
            ambientState = nil
        }

        let tailScalars = recentText.phonemeScalars.suffix(settings.ambientSearchChars)
        guard tailScalars.count >= settings.ambientMinChars else { return }

        guard let candidates = phonemeSearchWindowCandidates(
            corpus: corpus,
            query: tailScalars.scalarString,
            settings: settings,
            minGlobalWordIdx: locator.minGlobalWordIdx,
            maxGlobalWordIdx: maxIdx,
            confidenceThreshold: settings.ambientConfidenceThreshold,
            marginThreshold: settings.ambientMarginThreshold,
            similarityDelta: settings.ambientTieBreakSimilarityDelta
        ), !candidates.isEmpty else { return }

        guard let best = candidates.min(by: { abs(maxIdx - $0.globalWordIdx) < abs(maxIdx - $1.globalWordIdx) }) else { return }
        guard abs(best.globalWordIdx - maxIdx) >= settings.ambientBacktrackMinWordGap else { return }

        commitAmbientJump(best)
    }

    private func commitAmbientJump(_ candidate: PhonemeCandidateMatch) {
        let leftover = aligner.actualBufferText
        suspectBuffer = ""
        let baseline = maxGlobalWordIdxReached ?? candidate.globalWordIdx
        ambientState = AmbientBacktrackState(committedGlobalWordIdx: candidate.globalWordIdx, committedAtMaxReached: baseline)
        // `candidate.matchedText` (the ambient search's own query -- a
        // fixed-size tail of `recentText`, the raw ASR history) and
        // `leftover` (the old, about-to-be-discarded aligner's own
        // not-yet-settled buffer) are BOTH suffixes of the exact same fed-
        // character stream ending at "now", unlike `rerouteIfBacktrack`'s
        // own `suspectBuffer` (which is itself built from already-
        // *consumed*, already-settled content, so `leftover` -- what's
        // left AFTER that consumption --
        // never overlaps them). Concatenating here would instead double up
        // whichever's shorter (it's wholly contained in the longer one's
        // own tail), replaying a chunk of real audio twice into the fresh
        // aligner and corrupting the first word or two it settles after
        // the jump. Since both already end at the same point, the longer
        // one alone is the correct, complete replay text.
        let replayText = leftover.phonemeScalars.count > candidate.matchedText.phonemeScalars.count ? leftover : candidate.matchedText
        onLocalized(globalWordIdx: candidate.globalWordIdx, matchedText: replayText)
    }

    private func advanceProgress(_ globalWordIdx: Int) {
        // "Deleted" words (nothing recited) never advance progress -- see
        // caller. Only genuine recited content (match/mismatch) counts,
        // otherwise flush()'s speculative lookahead tail would silently
        // inflate both the skip-ahead ceiling and the backtrack window.
        if maxGlobalWordIdxReached == nil || globalWordIdx > maxGlobalWordIdxReached! {
            maxGlobalWordIdxReached = globalWordIdx
        }
        locator.maxGlobalWordIdx = maxGlobalWordIdxReached

        let floor = sessionStartGlobalWordIdx ?? 0
        locator.minGlobalWordIdx = max(floor, (maxGlobalWordIdxReached ?? floor) - backtrackWindowWords)
    }

    private func rerouteIfBacktrack(_ result: PhonemeWordCheckResult) -> Bool {
        // suspectBuffer, not a slice of recentText: it accumulates
        // actualPhonemes from consecutive mismatches only (cleared on any
        // match), so it never mixes in old, already-correct content ahead
        // of the new backtracked speech.
        let query = suspectBuffer
        guard query.phonemeScalars.count >= settings.minTriggerChars else { return false }

        guard let candidate = phonemeSearchWindow(
            corpus: corpus,
            query: query,
            settings: settings,
            minGlobalWordIdx: locator.minGlobalWordIdx,
            maxGlobalWordIdx: maxGlobalWordIdxReached
        ) else { return false }

        // Only a jump to somewhere clearly different counts as a backtrack
        // -- a match right around where we already are is just an ordinary
        // mismatch/ASR noise, not proof the reciter went elsewhere.
        guard abs(candidate.globalWordIdx - result.globalWordIndex) >= settings.backtrackMinWordGap else { return false }

        // Any characters already fed to the old (wrong-position) aligner
        // but not yet attributed to a settled word would otherwise be lost
        // when localize() resets actualBuffer -- rescue them.
        let leftover = aligner.actualBufferText
        suspectBuffer = ""
        ambientState = nil
        onLocalized(globalWordIdx: candidate.globalWordIdx, matchedText: candidate.matchedText + leftover)
        return true
    }

    private func onLocalized(globalWordIdx: Int, matchedText: String) {
        relocalizedDuringCurrentCall = true
        let entry = corpus.wordAt(globalWordIdx)
        let previouslyReached = maxGlobalWordIdxReached

        if sessionStartGlobalWordIdx == nil {
            sessionStartGlobalWordIdx = globalWordIdx
        }

        advanceProgress(globalWordIdx)

        aligner.localize(globalWordIdx)
        // The text that led to a successful localization was actually
        // recited -- replay it into the aligner rather than discarding it.
        if !matchedText.isEmpty {
            // `previouslyReached` (not the just-updated `maxGlobalWordIdxReached`
            // above, which this jump may have already raised) -- see
            // `onWordSettled`'s use of `replayFloor`.
            replayFloor = previouslyReached
            aligner.feedText(matchedText)
            replayFloor = nil
        }
        if let entry {
            onStatus("localized: surah \(entry.surah) ayah \(entry.ayah), word \(entry.localWordIdx)")
        }
        onRelocalized(globalWordIdx)
    }

    private func reportRejection(_ reason: PhonemeRejectionReason) {
        let bound: Int?
        let verb: String
        let note: String
        if reason == .beforeFloor {
            bound = locator.minGlobalWordIdx
            verb = "go back before"
            note = "the last \(settings.backtrackWindowPages) pages"
        } else {
            bound = maxGlobalWordIdxReached
            verb = "skip ahead of"
            note = "haven't recited that far yet"
        }

        guard let boundIdx = bound, let entry = corpus.wordAt(boundIdx) else { return }
        onStatus("can't \(verb) surah \(entry.surah) ayah \(entry.ayah) (\(note))")
    }
}
