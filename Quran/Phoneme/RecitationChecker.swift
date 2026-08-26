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
    /// `rerouteIfBacktrack`, `beginRelocalize`'s eventual re-match, or the
    /// ambient backtrack below) -- never for ordinary forward word-by-word
    /// settling, and never for strict mode's own `pinToGate` (a "still
    /// stuck" re-pin onto the same word, not a real jump -- see its own
    /// doc). `RecitationSession` uses this to release a stuck strict-mode
    /// gate when the reciter has genuinely moved backward of it (see
    /// `onLocalized`).
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
    /// Set by `onLocalized` (any source: reroute, ambient backtrack, or
    /// EMA-collapse relocalize) and checked/reset around each `feedTokens`
    /// call -- a reroute can fire *synchronously* mid-way through
    /// `aligner.feedTokens(tokens)` (via `onWordSettled`'s own
    /// callback chain), so by the time control returns to `feedTokens`,
    /// `recentText` still reflects the same already-consumed/relocalized
    /// content. Without this guard, `considerAmbientBacktrack` (which reads
    /// `recentText` unconditionally) would independently rediscover the very
    /// same backtrack a second time and commit a redundant, spurious jump on
    /// top of the one that already just happened.
    private var relocalizedDuringCurrentCall = false
    /// Accumulates actualPhonemes from consecutive mismatches only, for the
    /// backtrack-vs-mistake check -- see `rerouteIfBacktrack`. Bounded to
    /// `suspectBufferCap` (see `appendSuspect`) -- unbounded, this can grow
    /// far past "the last word or short phrase" `backtrackMinWordGap`'s own
    /// doc says this path is meant for. Confirmed live: with a strict-mode
    /// pin holding, every one of the reciter's subsequent words -- all
    /// genuinely correct, just repeatedly re-attributed to the pinned word
    /// -- keeps appending here every cycle, so an unresolved pin can
    /// accumulate a whole ayah's worth of real (but non-contiguous, since
    /// the pinned word's own botched attempt is mixed in) Quran text. A
    /// blob that long and that textually real is no longer "recent
    /// unexplained audio" -- it can fuzzy-match a coincidentally similar
    /// passage the reciter never actually went anywhere near, well before
    /// the pinned word. The cap alone doesn't rule that out; see
    /// `rerouteIfBacktrack`'s own candidate-vs-pin check and
    /// `pinnedBacktrackConfidenceThreshold` for the guards that actually
    /// do.
    private var suspectBuffer = ""
    private static let suspectBufferCap = 40
    private func appendSuspect(_ text: String) {
        let combined = (suspectBuffer + text).phonemeScalars
        suspectBuffer = combined.suffix(Self.suspectBufferCap).scalarString
    }
    /// Set to `maxGlobalWordIdxReached` (as it stood just *before* the jump)
    /// for the duration of `onLocalized`'s replay -- see `onWordSettled`.
    private var replayFloor: Int?
    /// True for the duration of `onLocalized`'s own `aligner.feedText`
    /// replay -- guards `rerouteIfBacktrack` the same way `flushing` already
    /// guards it (see that check's own doc): triggering a *second*,
    /// synchronous relocalization from inside the first one's still-in-
    /// progress replay resets the aligner state that replay is actively
    /// using, mid-loop. Confirmed live and reproducible: the session's very
    /// first localize can buffer (and then replay) a long run of text
    /// before the locator becomes confident -- `replayFloor` is `nil` for
    /// this specific replay (nothing was "already reached" before the
    /// session's own first word), so a DP chunking artifact producing one
    /// spurious mismatch on otherwise-perfectly-correct replayed text isn't
    /// suppressed the way it would be for a later jump's replay. With
    /// strict mode on, that spurious mismatch opened a pin, and
    /// `suspectBuffer` (built from that same replay's own real, correct
    /// text) trivially self-matched elsewhere *within the very block still
    /// being replayed*, at perfect confidence -- no threshold tuning
    /// prevents an exact match -- cascading into repeated nested
    /// relocalizations before the original replay had even finished.
    private var replaying = false

    /// Strict mode's halt target: the word recognition is currently pinned
    /// on, or nil if nothing's gated. Set once, the first time a word goes
    /// gate-worthy, and held fixed from then on -- `pinToGate` always
    /// re-targets *this* word, never whatever word most recently failed to
    /// settle. Without that distinction, a later word corrupted by the
    /// original mismatch's own knock-on effects (confirmed live: a
    /// mis-segmented DP boundary right after a pin can leave a *different*
    /// word settling badly next) would silently become the new pin target,
    /// letting recognition drift forward exactly the way strict mode exists
    /// to prevent. Cleared by a genuine match at this same word (passed) or
    /// by any relocalization (`onLocalized` -- a real backtrack moved
    /// somewhere else, so this word's own gate no longer applies).
    private var pinnedGateGlobalWordIdx: Int?
    /// Snapshot of `aligner.currentBleedContext` taken the moment this pin
    /// first opened (before that first mismatch's own settle could
    /// overwrite it with garbage) -- describes the word genuinely preceding
    /// the pinned one, which doesn't change for as long as the same word
    /// stays pinned. Passed to every `pinToGate` re-localize so cross-word
    /// bleed-stripping (`stripLiaisonBleed`/`stripConnectedTailBleed`)
    /// keeps working on repeated pin cycles instead of going permanently
    /// blind the moment the pin's own first `localize()` would otherwise
    /// wipe it -- see `pinToGate`'s own doc.
    private var pinBleedContext: IncrementalWordAligner.BleedContext?
    /// The aligner's own bleed context as of the most recent genuine
    /// `.match` -- kept up to date on every match so it's always ready the
    /// moment a gate opens (by the time `onWordSettled` sees a mismatch,
    /// `finalizeSettledWord` has already overwritten the aligner's own
    /// `lastSettledActual`/etc with *that mismatch's own* content, too late
    /// to read the true preceding word from there -- this is captured
    /// proactively instead, one match ahead).
    private var lastCleanBleedContext: IncrementalWordAligner.BleedContext?

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
                // Already handled synchronously (reroute) during the call
                // above -- re-running ambient/EMA checks against the same
                // now-stale recentText would double-relocalize.
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
        //
        // Kept unconditional (accumulates every cycle, even while a pin is
        // already holding) -- capped in length by `appendSuspect`, and
        // `rerouteIfBacktrack` below only ever accepts a candidate strictly
        // before the pin, at a much stricter confidence bar while pinned
        // (see `pinnedBacktrackConfidenceThreshold`'s own doc). That's what
        // lets an unresolved pin's own accumulating evidence still recover
        // a word whose correct retake got DP-merged with noise right in
        // front of it (the merged blob's own best explanation turns out to
        // be a position just *before* the pin, and replaying it with full
        // context there correctly re-segments the noise from the retake) --
        // freezing this after the first cycle was tried and confirmed to
        // break exactly that recovery, since the retake's own evidence
        // never gets a second chance once merged.
        if result.status == .match {
            suspectBuffer = ""
            // Captured proactively, one match ahead -- see the property's
            // own doc for why this can't just be read off the aligner
            // reactively once a mismatch/gate shows up.
            lastCleanBleedContext = aligner.currentBleedContext
        } else if result.status == .mismatch, let actual = result.actualPhonemes {
            appendSuspect(actual)
        }

        // `!replaying` too -- a gate opened here would target a position
        // the replay's own natural forward continuation (still unblocked;
        // only the reentrant `localize()` calls below are suppressed while
        // replaying, not ordinary DP settling) is about to carry straight
        // past within this same replay anyway, since there's no live audio
        // stream actually paused waiting for a correction to reconstructed,
        // already-known historical audio. Confirmed live: holding the pin
        // open past the replay and re-establishing it afterward instead
        // just rewound the aligner back onto an already-superseded position,
        // discarding real forward progress the same replay had already
        // made and correctly reported.
        let gateWorthy = !flushing && !replaying && settings.strictMode && isStrictGateWorthy(result)
        if gateWorthy {
            if pinnedGateGlobalWordIdx == nil {
                pinnedGateGlobalWordIdx = result.globalWordIndex
                // The word genuinely preceding the one just gated -- see
                // `pinBleedContext`'s own doc.
                pinBleedContext = lastCleanBleedContext
            }
            if result.status == .mismatch {
                // `pinToGate` below is about to wipe the aligner's own
                // in-flight buffer with no replay (see its own doc for why)
                // -- rescue it into `suspectBuffer` first, the same
                // accumulator `rerouteIfBacktrack` searches with, so
                // pinning back onto the same word doesn't cost evidence
                // that would otherwise have kept accumulating as the
                // aligner drifted forward on its own (which is how
                // `rerouteIfBacktrack` found a genuine backtrack before
                // pinning existed). Deliberately scoped to `.mismatch`
                // only, not every gate-worthy result -- widening this to a
                // `.deleted` live-skip's own (unattributed, noisier)
                // leftover was confirmed live to trigger false-positive
                // backtracks during otherwise-ordinary forward recitation
                // (two ayahs sharing an identical opening phrase).
                appendSuspect(aligner.actualBufferText)
            }
        } else if settings.strictMode, result.status == .match, result.globalWordIndex == pinnedGateGlobalWordIdx {
            // The pinned word finally passed -- release the pin so the
            // *next* mismatch (if any) opens a fresh gate at wherever it
            // actually happens, instead of this now-stale position.
            pinnedGateGlobalWordIdx = nil
            pinBleedContext = nil
        }

        if !flushing, !replaying, result.status == .mismatch, rerouteIfBacktrack(result) {
            return
        }

        onWordResult(result)

        // Suppressed while replaying for the same reason as the reroute
        // check above -- `pinToGate` resets the aligner too, which would
        // corrupt `onLocalized`'s own still-in-progress `feedText` loop.
        // `onLocalized` re-establishes the pin itself right after its
        // replay finishes (see its own doc), so this only ever skips a
        // cycle, never drops the halt entirely.
        if gateWorthy, !replaying, let gate = pinnedGateGlobalWordIdx {
            pinToGate(gate)
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
    ///
    /// `preservingBleedContext: pinBleedContext` -- without it, every
    /// re-pin would wipe the cross-word bleed-stripping context (see
    /// `IncrementalWordAligner.localize`'s own doc), permanently disabling
    /// recovery for a word whose correct pronunciation genuinely depends on
    /// a lagging tajweed artifact from the word before it (confirmed live:
    /// a reciter saying the pinned word perfectly correctly still couldn't
    /// pass, since the aligner could no longer explain away that legitimate
    /// leading bleed -- indistinguishable from being stuck).
    private func pinToGate(_ globalWordIdx: Int) {
        aligner.localize(globalWordIdx, preservingBleedContext: pinBleedContext)
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

        // Stricter thresholds while pinned -- see their own doc in
        // `PhonemeSettings` for why the base thresholds aren't safe here.
        let pinned = pinnedGateGlobalWordIdx != nil
        guard let candidate = phonemeSearchWindow(
            corpus: corpus,
            query: query,
            settings: settings,
            minGlobalWordIdx: locator.minGlobalWordIdx,
            maxGlobalWordIdx: maxGlobalWordIdxReached,
            confidenceThreshold: pinned ? settings.pinnedBacktrackConfidenceThreshold : nil,
            marginThreshold: pinned ? settings.pinnedBacktrackMarginThreshold : nil
        ) else { return false }

        // Only a jump to somewhere clearly different counts as a backtrack
        // -- a match right around where we already are is just an ordinary
        // mismatch/ASR noise, not proof the reciter went elsewhere.
        guard abs(candidate.globalWordIdx - result.globalWordIndex) >= settings.backtrackMinWordGap else { return false }

        // While a strict-mode pin is holding, `suspectBuffer` is built from
        // the pinned word's own repeated leftover (see the rescue in
        // `onWordSettled`) -- text that necessarily starts with that same
        // word's audio, so a fuzzy search over it can trivially "find" the
        // pinned word itself (or drift past it) with `backtrackMinWordGap`
        // set to 0 doing nothing to stop it. Confirmed live: a mismatched
        // word's own garbled buffer re-matched onto itself, which released
        // the gate and replayed straight through it -- the reciter's very
        // next, genuinely correct retake of that word then landed on
        // whatever came after it instead, since the gate was already gone.
        // A real backtrack means "the reciter jumped to an earlier point,"
        // so only a candidate strictly before the pin counts; anything at
        // or past it must stay gated.
        if let pin = pinnedGateGlobalWordIdx, candidate.globalWordIdx >= pin {
            return false
        }

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
        // Any genuine relocalization (reroute, ambient, EMA-collapse, or
        // the session's very first localize) moves recognition somewhere
        // else entirely -- a strict-mode gate pinned on the old position no
        // longer applies there. `pinToGate` deliberately does NOT call this
        // method (see its own doc), so this never fires for an ordinary
        // "still stuck, re-pin the same word" cycle -- only for an actual
        // jump.
        pinnedGateGlobalWordIdx = nil
        pinBleedContext = nil
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
            replaying = true
            aligner.feedText(matchedText)
            replaying = false
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
