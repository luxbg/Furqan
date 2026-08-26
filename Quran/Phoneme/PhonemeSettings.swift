import Foundation

/// Tunable thresholds for the phoneme pipeline (locator + aligner + checker)
/// - direct port of `qrc/config.py`'s `Settings` dataclass, same field names
/// (camelCased) and same defaults. See each field's Python counterpart for
/// the reasoning; not re-derived here to avoid the two drifting out of sync
/// in wording.
struct PhonemeSettings {
    var sampleRate: Int = 16_000

    // Localization (character-level: the model has no word-boundary token,
    // so the raw ASR stream can't be pre-segmented into words before a
    // location is known -- see IncrementalAyahLocator).
    var minTriggerChars: Int = 12
    var maxBufferChars: Int = 60
    var confidenceThreshold: Double = 0.72
    var marginThreshold: Double = 0.08
    // max_l_dist for the bounded approximate search, proportional to buffer
    // length but capped -- benchmarked on the real corpus (qrc, via
    // fuzzysearch): capped at 8 keeps worst-case search fast.
    var maxLDistRatio: Double = 0.15
    var maxLDistCap: Int = 8

    // Alignment (Option B: character-level DP, no ASR word boundaries). A
    // match requires exact phoneme equality after tajweed normalization,
    // not a fuzzy similarity threshold -- see PhonemeNormalize.
    var settleLookaheadChars: Int = 0

    // Relocalization: recent-character window used to reseed the locator
    // when the aligner's rolling confidence collapses.
    var relocalizeSeedChars: Int = 30
    var relocalizeEmaAlpha: Double = 0.3
    var relocalizeEmaThreshold: Double = 0.5

    // Backtracking: a reciter may restart from anywhere within the last N
    // pages of the furthest ayah actually reached, never earlier (and
    // never before the session's true start). "Pages" are estimated from
    // the corpus's average words/page (real Mushaf pagination isn't in the
    // corpus data), not exact boundaries.
    var backtrackWindowPages: Int = 2
    var mushafTotalPages: Int = 604
    // How many words apart a candidate match must be from where the
    // aligner currently is before `rerouteIfBacktrack` treats it as a
    // genuine backtrack rather than an ordinary mismatch/ASR noise near the
    // same spot. Kept at 0 (any distance counts) deliberately, by product
    // choice: this path only ever runs *after* real mismatch evidence has
    // accumulated (`suspectBuffer`), so it stays maximally responsive to a
    // close, genuine backtrack (a reciter redoing the last word or short
    // phrase) even though that does mean a rare false positive is possible
    // here too -- confirmed reproducible (not just theoretical): a word
    // settling via its droppable-trailing fast path can leave a few
    // leftover characters that transiently bleed into the next word's own
    // mismatch before self-correcting, and if that transient blob happens
    // to reach `minTriggerChars` it can trigger a spurious nearby reroute.
    // Accepted as the cost of staying responsive at close range, rather
    // than raised the way `ambientBacktrackMinWordGap` below was.
    var backtrackMinWordGap: Int = 0
    /// Same idea, but for `considerAmbientBacktrack`: unlike the reroute
    /// path above, this runs continuously on *every* audio chunk with zero
    /// corroborating mismatch evidence at all, so a coincidental nearby
    /// fuzzy match can commit as a "backtrack" during completely ordinary,
    /// mistake-free forward recitation -- confirmed via a live capture
    /// (2:14, reciting straight through words 9-12) where this happened at
    /// gap 0, re-processing word 9 a second time (and getting it wrong the
    /// second time, since the replay was never actually a repeat). Unlike
    /// `backtrackMinWordGap`, there's no evidence-based case for staying
    /// responsive here, so this stays at a safe floor -- a genuine close
    /// backtrack the ambient path misses this way still gets caught a beat
    /// later by `rerouteIfBacktrack` once the resulting mismatch(es)
    /// accumulate (see that field's own doc for its own responsiveness
    /// choice).
    var ambientBacktrackMinWordGap: Int = 0
    /// `rerouteIfBacktrack`'s own thresholds while a strict-mode pin is
    /// holding -- much stricter than the base `confidenceThreshold`/
    /// `marginThreshold` above (even stricter than the ambient search's own
    /// 0.80/0.12). While pinned, `suspectBuffer` keeps absorbing whatever the
    /// reciter says next (still re-attributed to the pinned word every
    /// cycle, not fresh evidence about it -- see the rescue in
    /// `onWordSettled`), and the search window is full of already-*passed*,
    /// already-correct recitation from earlier this same session -- prime
    /// conditions for a coincidental, low-margin match under the base
    /// thresholds. Confirmed live: with the base thresholds, a post-mismatch
    /// buffer chained through *three* separate spurious relocalizations back
    /// into an already-fully-recited earlier ayah within one replay, each
    /// jump's own evidence just barely clearing 0.72/0.08. A genuine
    /// backtrack while pinned is still just as detectable here -- a reciter
    /// deliberately restarting from an earlier point, or a correct retake
    /// that got DP-merged with noise right in front of it, both produce
    /// audio that matches their true source at very high confidence, not a
    /// borderline one -- so raising the bar costs essentially nothing but
    /// false positives.
    var pinnedBacktrackConfidenceThreshold: Double = 0.92
    var pinnedBacktrackMarginThreshold: Double = 0.2

    // Ambient backtrack: unlike `rerouteIfBacktrack` (which only searches
    // after several mismatched words have already accumulated), this runs
    // continuously against the raw recognized-character stream, windowed to
    // the same backtrack range, so a genuine backtrack is reflected
    // instantly rather than after a lag. Thresholds are stricter than the
    // base `confidenceThreshold`/`marginThreshold` since this runs with no
    // prior mismatch evidence at all.
    var ambientBacktrackEnabled: Bool = true
    /// Skips the ambient search entirely whenever the aligner's own rolling
    /// confidence is already this high -- i.e. forward tracking is plainly
    /// succeeding, so there's nothing to second-guess. Without this, the
    /// search runs unconditionally on every chunk and can find a
    /// perfectly-confident match *somewhere else* in the backtrack window
    /// even when the current position already explains the audio just
    /// fine -- confirmed via a live capture in Al-Ma'idah: ayah 1 and ayah 2
    /// both open with the identical phrase "يَـٰٓأَيُّهَا ٱلَّذِينَ
    /// ءَامَنُوا۟", so moving from 5:1 straight into 5:2 recites that
    /// phrase again, matching 5:2's own expected opening perfectly (no
    /// mismatch, no confidence collapse) -- yet the ambient search still
    /// found 5:1's *own* identical opening, far outside
    /// `ambientBacktrackMinWordGap`'s reach (5:1 is 22 words long), and
    /// jumped backward to it. High on purpose (0.95, not e.g. 0.8): this
    /// only needs to rule out "everything's fine," not attempt any real
    /// confidence judgment of its own -- `aligner.rollingSimilarityEma`
    /// dips well below this after even one imperfect word (see its own
    /// EMA formula), so a genuine backtrack's mismatched audio still opens
    /// the search back up within a word or two, not noticeably slower than
    /// today.
    var ambientSkipWhenConfidenceAtLeast: Double = 0.95
    var ambientSearchChars: Int = 8
    var ambientMinChars: Int = 8
    var ambientConfidenceThreshold: Double = 0.80
    var ambientMarginThreshold: Double = 0.12
    /// How close two candidates' similarity scores need to be to count as
    /// "similarly good" for the closest/latest tie-break.
    var ambientTieBreakSimilarityDelta: Double = 0.05
    /// Words of grace right after an ambient jump commits during which
    /// `considerAmbientBacktrack` doesn't re-search at all -- the aligner is
    /// already tracking forward off a full DP alignment of everything
    /// recited since the jump, which is far stronger evidence than another
    /// raw tail-window fuzzy search could offer. (Used to also allow a
    /// "refinement" to a farther candidate within this window -- removed
    /// after it was confirmed to occasionally mis-fire a spurious second
    /// jump moments after a perfectly good first one, off a tail window
    /// that had already drifted onto unrelated, currently-being-recited
    /// content.)
    var ambientRefineMaxWords: Int = 5

    // Strict mode: when on, both the mushaf display and the ASR pipeline
    // itself hold at a mismatched (or live-skipped) word until it's said
    // correctly - the pipeline stops recognizing anything past it, only
    // re-expecting that same word, though a genuine backtrack to an earlier
    // point still releases it (see RecitationChecker.pinToGate/
    // RecitationProgressTracker). Not yet user-facing - a code-level toggle
    // for now.
    var strictMode: Bool = true

    static let `default` = PhonemeSettings()
}
