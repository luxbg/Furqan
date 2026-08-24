import Foundation

/// Port of `qrc/align/normalize.py` -- what "the same phoneme content"
/// means, deliberately narrower than a fuzzy-similarity threshold. Operates
/// on `Unicode.Scalar` (codepoint) sequences, not `Character` -- see
/// `PhonemeScalars.swift`.
enum PhonemeNormalize {
    /// Short-vowel diacritics dropped at a pause (waqf) -- fatha, damma, kasra.
    private static let shortVowels: Set<Unicode.Scalar> = ["\u{064E}", "\u{064F}", "\u{0650}"]

    /// Hamza-the-phoneme, as this corpus renders it -- U+0621, the bare
    /// hamza letter (not the alif-with-hamza glyphs used in *written*
    /// text).
    private static let hamzaPhoneme: Unicode.Scalar = "\u{0621}"

    /// Hamzat al-wasl -- the "connecting hamza" written as a plain alif
    /// with a wasl sign (ٱ, U+0671) atop it, e.g. the alif of the
    /// definite article "ال" or of an imperative verb like "ٱهْدِنَا".
    /// Pronounced (as hamza + a short vowel) only when a reciter starts
    /// fresh on that word; silent when continuing straight out of
    /// whatever precedes it -- the preceding sound just flows directly
    /// into the word's *second* letter.
    private static let alifWasl: Unicode.Scalar = "\u{0671}"

    /// This word's phoneme rendering(s) with a leading hamzat-wasl elided,
    /// broadest first -- empty if `wordText` doesn't actually begin with
    /// one (or `phonemeText` doesn't have the hamza+vowel prefix that
    /// implies -- guards against acting on a real hamzat *qat'* word,
    /// which must always be pronounced).
    ///
    /// This corpus phonetizes each ayah's text standalone, so an
    /// ayah-initial word carrying a hamzat wasl always gets rendered as
    /// if freshly started (hamza pronounced) -- correct only when a
    /// reciter actually pauses before it. A reciter who instead continues
    /// straight out of the previous ayah produces audio with no hamza at
    /// all, wrongly flagged as a mismatch without this fallback. (Every
    /// *other* occurrence of hamzat wasl -- mid-ayah -- already comes out
    /// elided in `phonemeText` for free, since the ayah's own text is
    /// phonetized as one continuous utterance; this only matters at an
    /// ayah's own first word.)
    ///
    /// Two candidates, not one: linguistically the hamza's own inherent
    /// vowel is silent right along with it (nothing to support pronouncing
    /// a consonant that's never voiced), but a live ASR capture showed the
    /// model sometimes still emits a residual leading vowel marker where
    /// the hamza itself was clearly dropped -- a coarticulation/model
    /// artifact, not a second valid pronunciation. Both are accepted as
    /// "hamza not pronounced", never as license to accept a genuinely
    /// wrong leading vowel (only these two specific derivations of the
    /// word's own expected phonemes qualify, nothing else).
    static func waslElidedForms(phonemeText: String, wordText: String?) -> [String] {
        guard let wordText, wordText.unicodeScalars.first == alifWasl else { return [] }
        let scalars = phonemeText.phonemeScalars
        guard scalars.count > 2, scalars[0] == hamzaPhoneme, shortVowels.contains(scalars[1]) else { return [] }
        return [Array(scalars.dropFirst(2)).scalarString, Array(scalars.dropFirst(1)).scalarString]
    }

    /// A trailing alif-madd (ا) is forgiven the same way a trailing short
    /// vowel is: the elongation it represents (e.g. tanween fatha rendered
    /// as "...aa" at a pause -- "قَلِۦۦلَاا" for قليلا) is exactly the part
    /// an ASR model most often clips at a word boundary, and forgiving it
    /// only when it's the sole trailing difference (see `normalizePair`)
    /// can't mask a genuine wrong-phoneme mistake elsewhere in the word.
    ///
    /// Same reasoning extends to the small-waw/yaa elongation markers
    /// (ۥ/ۦ, U+06E5/U+06E6) this corpus uses to render a word-final natural
    /// madd (e.g. "ذُۥۥ" for ذُو) -- collapseRuns first reduces the
    /// corpus's own doubled rendering to one instance, so a word ending in
    /// exactly one of these markers is treated the same as any other
    /// forgivable trailing character. Real-world report: "عَزِيزٌ ذُو
    /// ٱنتِقَامٍ" (3:4) recited normally came back as "ذُ" against the
    /// corpus's "ذُۥۥ" -- a genuinely natural (2-count) madd whose short
    /// elongation an ASR model clips just as readily as a trailing vowel.
    private static let droppableWordFinal: Set<Unicode.Scalar> = shortVowels.union(["\u{0627}", "\u{06E5}", "\u{06E6}"])

    /// Whether `scalar` is the kind of character `normalizePair` forgives
    /// as a word's sole trailing difference -- exposed so the aligner can
    /// also use it to decide when a word's *settle timing* (not just its
    /// eventual match verdict) shouldn't wait on that character's arrival.
    static func isDroppableWordFinal(_ scalar: Unicode.Scalar) -> Bool {
        droppableWordFinal.contains(scalar)
    }

    /// Collapse tajweed-length rendering variation: any run of the same
    /// repeated symbol (madd length, gemination, ghunna) becomes a single
    /// instance. Safe to apply independently to each string: a run of one
    /// symbol can never collapse to look like a run of a *different*
    /// symbol.
    static func collapseRuns(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        guard !s.isEmpty else { return s }
        var result: [Unicode.Scalar] = [s[0]]
        for scalar in s.dropFirst() where scalar != result[result.count - 1] {
            result.append(scalar)
        }
        return result
    }

    /// Collapse tajweed-only rendering variation, judged pairwise (never
    /// independently -- see `phonemesMatch`).
    private static func normalizePair(_ expected: [Unicode.Scalar], _ actual: [Unicode.Scalar]) -> ([Unicode.Scalar], [Unicode.Scalar]) {
        let e = collapseRuns(expected)
        let a = collapseRuns(actual)

        // Deliberately asymmetric -- only forgives `expected`'s OWN trailing
        // vowel being dropped (a pause/waqf), never the reverse. Bug
        // regression: this used to pick `longer`/`shorter` by length alone,
        // so a genuinely WRONG trailing vowel tacked onto `actual` -- as
        // long as it happened to also be a member of `droppableWordFinal`
        // (fatha/damma/kasra/alif all qualify) -- got silently treated as
        // "the reciter paused and dropped it", passing as a match even
        // though a real harakah mistake was recited (confirmed live: "أَلْفَ"
        // recited with the wrong final vowel matched anyway, via the
        // isolated/paused-form fallback in `PhonemeWordAligner`, whose own
        // no-vowel form made ANY appended vowel look "droppable"). Only
        // `expected` ending up one droppable char longer than `actual`
        // (and `actual` being its prefix) is forgiven now.
        if e.count == a.count + 1,
           let last = e.last, droppableWordFinal.contains(last),
           e.starts(with: a) {
            return (a, a)
        }
        return (e, a)
    }

    /// Whether two phoneme strings are the same phoneme content, ignoring
    /// tajweed-only rendering variation. Requires exact equality after
    /// normalization, not a fuzzy similarity threshold -- a length-
    /// proportional similarity cutoff systematically under-penalizes a
    /// single wrong character in a long word.
    static func phonemesMatch(_ expected: String, _ actual: String) -> Bool {
        let (e, a) = normalizePair(expected.phonemeScalars, actual.phonemeScalars)
        return e == a
    }

    /// Diagnostic similarity score (not the match/mismatch gate -- see
    /// `phonemesMatch`) after the same tajweed normalization. Normalized
    /// Levenshtein similarity: 1 - distance / max(len(e), len(a)).
    static func phonemeSimilarity(_ expected: String, _ actual: String) -> Double {
        let (e, a) = normalizePair(expected.phonemeScalars, actual.phonemeScalars)
        let maxLen = max(e.count, a.count)
        guard maxLen > 0 else { return 1.0 }
        let dist = levenshteinDistance(e, a)
        return 1.0 - Double(dist) / Double(maxLen)
    }

    private static func levenshteinDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
