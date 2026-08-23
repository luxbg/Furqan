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
    /// Accumulates actualPhonemes from consecutive mismatches only, for the
    /// backtrack-vs-mistake check -- see `rerouteIfBacktrack`.
    private var suspectBuffer = ""

    init(
        corpus: PhonemeCorpus,
        settings: PhonemeSettings,
        onWordResult: @escaping (PhonemeWordCheckResult) -> Void,
        onStatus: @escaping (String) -> Void = { _ in }
    ) {
        self.corpus = corpus
        self.settings = settings
        self.onWordResult = onWordResult
        self.onStatus = onStatus

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
            aligner.feedTokens(tokens)
            if aligner.confidenceCollapsed() {
                beginRelocalize()
            }
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
        locator.seedForRelocalize(recentText: recentText)
    }

    private func onWordSettled(_ result: PhonemeWordCheckResult) {
        if result.status != .deleted {
            advanceProgress(result.globalWordIndex)
        }

        // A mismatch might not be a mistake at all -- the reciter may have
        // jumped to an earlier ayah within the backtrack window rather than
        // mispronounced this one. Deliberately restricted to "mismatch"
        // (never "deleted") -- and never while flush() is running: calling
        // locator/aligner localize() here would reset aligner state out
        // from under flush()'s own in-progress loop.
        if result.status == .match {
            suspectBuffer = ""
        } else if result.status == .mismatch {
            if let actual = result.actualPhonemes {
                suspectBuffer += actual
            }
            if !flushing, rerouteIfBacktrack(result) {
                return
            }
        }

        onWordResult(result)
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
        onLocalized(globalWordIdx: candidate.globalWordIdx, matchedText: candidate.matchedText + leftover)
        return true
    }

    private func onLocalized(globalWordIdx: Int, matchedText: String) {
        let entry = corpus.wordAt(globalWordIdx)

        if sessionStartGlobalWordIdx == nil {
            sessionStartGlobalWordIdx = globalWordIdx
        }

        advanceProgress(globalWordIdx)

        aligner.localize(globalWordIdx)
        // The text that led to a successful localization was actually
        // recited -- replay it into the aligner rather than discarding it.
        if !matchedText.isEmpty {
            aligner.feedText(matchedText)
        }
        if let entry {
            onStatus("localized: surah \(entry.surah) ayah \(entry.ayah), word \(entry.localWordIdx)")
        }
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
