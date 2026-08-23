import Foundation

/// Port of `qrc/align/normalize.py` -- what "the same phoneme content"
/// means, deliberately narrower than a fuzzy-similarity threshold. Operates
/// on `Unicode.Scalar` (codepoint) sequences, not `Character` -- see
/// `PhonemeScalars.swift`.
enum PhonemeNormalize {
    /// Short-vowel diacritics dropped at a pause (waqf) -- fatha, damma, kasra.
    private static let shortVowels: Set<Unicode.Scalar> = ["\u{064E}", "\u{064F}", "\u{0650}"]

    /// A trailing alif-madd (ا) is forgiven the same way a trailing short
    /// vowel is: the elongation it represents (e.g. tanween fatha rendered
    /// as "...aa" at a pause -- "قَلِۦۦلَاا" for قليلا) is exactly the part
    /// an ASR model most often clips at a word boundary, and forgiving it
    /// only when it's the sole trailing difference (see `normalizePair`)
    /// can't mask a genuine wrong-phoneme mistake elsewhere in the word.
    private static let droppableWordFinal: Set<Unicode.Scalar> = shortVowels.union(["\u{0627}"])

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

        let (longer, shorter) = e.count >= a.count ? (e, a) : (a, e)
        if longer.count == shorter.count + 1,
           let last = longer.last, droppableWordFinal.contains(last),
           longer.starts(with: shorter) {
            return (shorter, shorter)
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
