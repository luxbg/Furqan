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
    // aligner currently is before it's treated as a genuine backtrack
    // rather than an ordinary mismatch/ASR noise near the same spot.
    var backtrackMinWordGap: Int = 5

    static let `default` = PhonemeSettings()
}
