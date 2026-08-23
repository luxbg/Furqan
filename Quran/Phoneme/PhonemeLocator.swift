import Foundation

/// Port of `qrc/localize/ayah_locator.py`.
enum PhonemeLocatorState: Equatable {
    case localizing
    case localized
    case relocalizing
}

enum PhonemeRejectionReason: Equatable {
    case beforeFloor    // would skip backward before the session's start
    case beyondCeiling  // would skip ahead past the furthest ayah reached
}

struct PhonemeLocalizeResult {
    let globalWordIdx: Int
    let similarity: Double
    /// The raw buffered text that produced this match -- it was actually
    /// recited, so the caller should replay it into the aligner instead of
    /// discarding it.
    let matchedText: String
}

private struct ScoredCandidate {
    let charOffset: Int
    let similarity: Double
}

/// Fuzzy-substring-search `query` against the whole corpus, returning
/// (char_offset, similarity) pairs sorted best-first. Shared by both the
/// incremental locator and one-shot `searchWindow`.
private func scoreCandidates(corpus: PhonemeCorpus, query: [Unicode.Scalar], settings: PhonemeSettings) -> [ScoredCandidate] {
    guard !query.isEmpty else { return [] }
    let maxLDist = min(max(1, Int((Double(query.count) * settings.maxLDistRatio).rounded(.towardZero))), settings.maxLDistCap)
    let matches = PhonemeFuzzySearch.findNearMatches(pattern: query, in: corpus.corpusScalars, maxLDist: maxLDist)
    var scored = matches.map { m -> ScoredCandidate in
        let denom = max(query.count, m.end - m.start)
        let sim = 1.0 - Double(m.dist) / Double(denom)
        return ScoredCandidate(charOffset: m.start, similarity: sim)
    }
    scored.sort { $0.similarity > $1.similarity }
    return scored
}

private func passesConfidenceGate(_ scored: [ScoredCandidate], settings: PhonemeSettings) -> Bool {
    guard let top = scored.first else { return false }
    let second = scored.count > 1 ? scored[1].similarity : 0.0
    return top.similarity >= settings.confidenceThreshold && (top.similarity - second) >= settings.marginThreshold
}

/// One-shot confident match of a complete (not growing) query string within
/// `[minGlobalWordIdx, maxGlobalWordIdx]`. Unlike `IncrementalAyahLocator`,
/// there's no buffering -- the caller already has the full text to search
/// for. Used to check whether a word that just failed to match the current
/// forward position is actually a backtrack to somewhere else nearby,
/// rather than a genuine mistake.
func phonemeSearchWindow(
    corpus: PhonemeCorpus,
    query: String,
    settings: PhonemeSettings,
    minGlobalWordIdx: Int,
    maxGlobalWordIdx: Int?
) -> PhonemeLocalizeResult? {
    let queryScalars = query.phonemeScalars
    let scored = scoreCandidates(corpus: corpus, query: queryScalars, settings: settings)
    let inRange = scored.filter { c in
        let idx = corpus.globalWordIdx(forCharOffset: c.charOffset)
        return idx >= minGlobalWordIdx && (maxGlobalWordIdx == nil || idx <= maxGlobalWordIdx!)
    }
    guard passesConfidenceGate(inRange, settings: settings) else { return nil }
    let globalWordIdx = corpus.globalWordIdx(forCharOffset: inRange[0].charOffset)
    return PhonemeLocalizeResult(globalWordIdx: globalWordIdx, similarity: inRange[0].similarity, matchedText: query)
}

/// Localizes a recitation from a raw, growing phoneme character stream. The
/// ASR alphabet has no word-boundary token, so there's no way to
/// pre-segment the buffered audio into words before a location is known --
/// instead this does fuzzy substring search of the raw character buffer
/// directly against the flat corpus text (`PhonemeFuzzySearch`).
final class IncrementalAyahLocator {
    let corpus: PhonemeCorpus
    let settings: PhonemeSettings

    private(set) var state: PhonemeLocatorState = .localizing
    private(set) var buffer: String = ""

    /// Backtracking floor -- see `RecitationChecker` for how this is kept
    /// dynamic. 0 (the default) means unrestricted, correct before the
    /// session has localized for the first time.
    var minGlobalWordIdx: Int = 0
    /// Ceiling: no match past the furthest position actually reached this
    /// session is ever accepted either. `nil` means unrestricted.
    var maxGlobalWordIdx: Int?
    /// Set when the top candidate would otherwise have been accepted but
    /// fell outside `[minGlobalWordIdx, maxGlobalWordIdx]` -- lets the
    /// caller distinguish "no match at all" from "found it, but out of
    /// range". Cleared at the start of every `addChars` call.
    private(set) var lastRejection: PhonemeRejectionReason?

    init(corpus: PhonemeCorpus, settings: PhonemeSettings) {
        self.corpus = corpus
        self.settings = settings
    }

    func reset() {
        state = .localizing
        buffer = ""
    }

    func seedForRelocalize(recentText: String) {
        state = .relocalizing
        let scalars = recentText.phonemeScalars
        let tail = scalars.suffix(settings.relocalizeSeedChars)
        buffer = tail.scalarString
    }

    /// Feed more recognized phoneme characters. Returns a result once
    /// localized. On `maxBufferChars` with no confident match, discards the
    /// stale buffer and starts fresh (avoids garbled early audio
    /// permanently poisoning later attempts).
    @discardableResult
    func addChars(_ newText: String) -> PhonemeLocalizeResult? {
        lastRejection = nil
        buffer += newText

        let bufferScalarCount = buffer.phonemeScalars.count
        if bufferScalarCount < settings.minTriggerChars { return nil }

        if let result = attemptMatch() {
            state = .localized
            buffer = ""
            return result
        }

        if bufferScalarCount >= settings.maxBufferChars {
            buffer = ""
        }
        return nil
    }

    private func inRange(_ globalWordIdx: Int) -> Bool {
        if globalWordIdx < minGlobalWordIdx { return false }
        if let ceiling = maxGlobalWordIdx, globalWordIdx > ceiling { return false }
        return true
    }

    private func attemptMatch() -> PhonemeLocalizeResult? {
        let scored = scoreCandidates(corpus: corpus, query: buffer.phonemeScalars, settings: settings)
        guard !scored.isEmpty else { return nil }

        let inRangeCandidates = scored.filter { inRange(corpus.globalWordIdx(forCharOffset: $0.charOffset)) }

        guard !inRangeCandidates.isEmpty else {
            if passesConfidenceGate(scored, settings: settings) {
                let topIdx = corpus.globalWordIdx(forCharOffset: scored[0].charOffset)
                lastRejection = topIdx < minGlobalWordIdx ? .beforeFloor : .beyondCeiling
            }
            return nil
        }

        guard passesConfidenceGate(inRangeCandidates, settings: settings) else { return nil }
        let globalWordIdx = corpus.globalWordIdx(forCharOffset: inRangeCandidates[0].charOffset)
        return PhonemeLocalizeResult(globalWordIdx: globalWordIdx, similarity: inRangeCandidates[0].similarity, matchedText: buffer)
    }
}
