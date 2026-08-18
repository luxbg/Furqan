import Foundation

/// Whole-Quran ayah identification and per-tick tracking, built on one
/// shared banded (in effect - callers pass already-small windows), semi-
/// global ("fitting"), streak-bounded word-alignment primitive (`align`).
/// Pure/stateless - no mic/ASR/session dependency, so it's callable
/// identically from the real tick loop and from tests.
enum AyahAligner {

    /// Max run of consecutive non-match operations (substitution / missed /
    /// extra) tolerated before an alignment is rejected outright - the
    /// "tolerate up to 2 wrong/missing/extra words in a row" rule, used
    /// identically for identification and tracking.
    static let maxConsecutiveErrors = 2

    /// How many committed words after a fresh identification (session
    /// start, or post pause/resume) are never scored, regardless of
    /// correctness. Position-based, not content-based: this is what makes a
    /// misheard muqata'at opener non-fatal with zero muqata'at-specific
    /// code anywhere (see the plan) - it also means the first couple of
    /// words of *any* fresh start go unscored, judged an acceptable
    /// tradeoff for the simplicity of not needing to know what a muqata'at
    /// token even is.
    static let verificationLeniencyWordCount = 2

    /// Whether a word at `wordsSinceIdentification` (0-based count of
    /// already-committed words since the position was last freshly
    /// established) should be scored at all.
    static func shouldScore(wordsSinceIdentification: Int) -> Bool {
        wordsSinceIdentification >= verificationLeniencyWordCount
    }

    enum StepKind: Equatable {
        case match
        case substitute
        /// A candidate (expected) word with no corresponding observed word -
        /// the reciter didn't say it.
        case missed
        /// An observed word with no corresponding candidate word - said,
        /// but not part of the expected text at this position.
        case extra
    }

    struct Step: Equatable {
        let kind: StepKind
        /// Index into the `observed` array passed to `align`, if this step
        /// consumed one (everything except `.missed`).
        let observedIndex: Int?
        /// Index into the `candidate` array passed to `align`, if this step
        /// consumed one (everything except `.extra`).
        let candidateIndex: Int?
        /// Set only for a `.match` step that resolved by merging two
        /// consecutive observed tokens whose concatenated skeleton equals
        /// one candidate word's skeleton - the ASR sometimes splits a
        /// single ground-truth word into two transcribed tokens (e.g.
        /// "ان" + "ما" for "انما"). Holds the earlier of the two observed
        /// indices; `observedIndex` remains the later one. Nil for every
        /// ordinary step.
        let mergedObservedIndex: Int?

        init(kind: StepKind, observedIndex: Int?, candidateIndex: Int?, mergedObservedIndex: Int? = nil) {
            self.kind = kind
            self.observedIndex = observedIndex
            self.candidateIndex = candidateIndex
            self.mergedObservedIndex = mergedObservedIndex
        }
    }

    struct Alignment {
        /// First candidate index actually covered by this alignment (after
        /// any free leading skip).
        let candidateStart: Int
        /// One past the last candidate index covered.
        let candidateEnd: Int
        /// In order, covering every observed word and every candidate word
        /// in `candidateStart..<candidateEnd`.
        let steps: [Step]
        let cost: Int
    }

    /// Core primitive: given `observed` (a slice of the live transcript) and
    /// `candidate` (a slice of the Quran's flattened word stream), finds the
    /// lowest-cost alignment where every observed word is accounted for,
    /// candidate words outside the aligned region are free on both ends (so
    /// `observed` can be a fragment of a longer `candidate`), and no run of
    /// `maxConsecutiveErrors + 1` consecutive non-match operations occurs
    /// anywhere in the interior. Returns nil if no such alignment exists.
    ///
    /// `freeLeadingCandidate`: when true, the alignment may start anywhere
    /// within `candidate` at zero cost (used for identification - the
    /// observed tail can be a mid-ayah fragment, which is also what makes a
    /// garbled/dropped/glued muqata'at opener resolve for free with no
    /// special-casing - and for backtrack search, where the whole point is
    /// finding *where* in the window a repeat starts). When false, the
    /// alignment is forced to start at `candidate[0]` (used for forward
    /// tracking, where we specifically do not want to silently skip ahead).
    /// Trailing skip is always free either way.
    static func align(observed: [String], candidate: [String], freeLeadingCandidate: Bool) -> Alignment? {
        let n = observed.count
        let m = candidate.count
        guard n > 0 else { return nil }

        let streakCap = maxConsecutiveErrors
        let inf = Int.max / 4

        struct Parent {
            var pi = -1, pj = -1, ps = -1
            var kind: StepKind = .match
            var valid = false
            /// See `Step.mergedObservedIndex` - set when this transition
            /// resolved by merging 2 observed tokens into 1 candidate word.
            var isMerge = false
        }

        var dp = Array(repeating: Array(repeating: Array(repeating: inf, count: streakCap + 1), count: m + 1), count: n + 1)
        var parent = Array(
            repeating: Array(repeating: Array(repeating: Parent(), count: streakCap + 1), count: m + 1), count: n + 1
        )

        dp[0][0][0] = 0
        if freeLeadingCandidate {
            for j in 1...m { dp[0][j][0] = 0 }
        }

        for i in 0...n {
            for j in 0...m {
                // Match / substitute, from (i-1, j-1).
                if i >= 1, j >= 1 {
                    let isMatch = observed[i - 1] == candidate[j - 1]
                    for ps in 0...streakCap {
                        let prev = dp[i - 1][j - 1][ps]
                        guard prev < inf else { continue }
                        if isMatch {
                            if prev < dp[i][j][0] {
                                dp[i][j][0] = prev
                                parent[i][j][0] = Parent(pi: i - 1, pj: j - 1, ps: ps, kind: .match, valid: true)
                            }
                        } else if ps < streakCap {
                            let ns = ps + 1
                            let cost = prev + 1
                            if cost < dp[i][j][ns] {
                                dp[i][j][ns] = cost
                                parent[i][j][ns] = Parent(pi: i - 1, pj: j - 1, ps: ps, kind: .substitute, valid: true)
                            }
                        }
                    }
                }
                // Merge match: 2 consecutive observed tokens concatenate to
                // exactly equal 1 candidate word's skeleton - the ASR
                // sometimes splits a single ground-truth word into two
                // transcribed tokens (e.g. "ان" + "ما" for "انما"). Treated
                // like an ordinary match: free, doesn't consume the error
                // streak, since it's a correctly-recited word that just got
                // re-tokenized, not an actual mistake.
                if i >= 2, j >= 1, observed[i - 2] + observed[i - 1] == candidate[j - 1] {
                    for ps in 0...streakCap {
                        let prev = dp[i - 2][j - 1][ps]
                        guard prev < inf else { continue }
                        if prev < dp[i][j][0] {
                            dp[i][j][0] = prev
                            parent[i][j][0] = Parent(pi: i - 2, pj: j - 1, ps: ps, kind: .match, valid: true, isMerge: true)
                        }
                    }
                }
                // Extra observed word (insertion), from (i-1, j).
                if i >= 1 {
                    for ps in 0..<streakCap {
                        let prev = dp[i - 1][j][ps]
                        guard prev < inf else { continue }
                        let ns = ps + 1
                        let cost = prev + 1
                        if cost < dp[i][j][ns] {
                            dp[i][j][ns] = cost
                            parent[i][j][ns] = Parent(pi: i - 1, pj: j, ps: ps, kind: .extra, valid: true)
                        }
                    }
                }
                // Missed candidate word (deletion), from (i, j-1).
                if j >= 1 {
                    for ps in 0..<streakCap {
                        let prev = dp[i][j - 1][ps]
                        guard prev < inf else { continue }
                        let ns = ps + 1
                        let cost = prev + 1
                        if cost < dp[i][j][ns] {
                            dp[i][j][ns] = cost
                            parent[i][j][ns] = Parent(pi: i, pj: j - 1, ps: ps, kind: .missed, valid: true)
                        }
                    }
                }
            }
        }

        var bestJ = -1, bestS = -1, bestCost = inf
        for j in 0...m {
            for s in 0...streakCap where dp[n][j][s] < bestCost {
                bestCost = dp[n][j][s]
                bestJ = j
                bestS = s
            }
        }
        guard bestJ >= 0 else { return nil }

        var steps: [Step] = []
        var ci = n, cj = bestJ, cs = bestS
        while ci > 0 || cj > 0 {
            let p = parent[ci][cj][cs]
            guard p.valid else { break } // reached a free-start seed point
            switch p.kind {
            case .match, .substitute:
                steps.append(Step(
                    kind: p.kind, observedIndex: ci - 1, candidateIndex: cj - 1,
                    mergedObservedIndex: p.isMerge ? ci - 2 : nil
                ))
            case .extra:
                steps.append(Step(kind: .extra, observedIndex: ci - 1, candidateIndex: nil))
            case .missed:
                steps.append(Step(kind: .missed, observedIndex: nil, candidateIndex: cj - 1))
            }
            (ci, cj, cs) = (p.pi, p.pj, p.ps)
        }
        steps.reverse()

        return Alignment(candidateStart: cj, candidateEnd: bestJ, steps: steps, cost: bestCost)
    }

    // MARK: - Identification

    /// The `currentPages` hint is only considered once at least this many
    /// words have been observed - below this, a tie is left unresolved
    /// rather than guessed via page context.
    static let minWordsForPageAssistedResolve = 5
    /// A tie at the best alignment cost wider than this is refused even if
    /// `currentPages` would technically narrow it to one - narrowing a
    /// dozen-plus equally-good candidates down to "exactly one is on this
    /// page" is closer to a coin flip than real disambiguation.
    static let maxPageAssistedTieSize = 5
    /// Resolutions reached with fewer than this many observed words are
    /// reported as provisional (see `IdentificationResult.isProvisional`),
    /// regardless of whether they needed the page hint - short of this,
    /// even a textually unique match is treated as needing verification.
    static let solidEvidenceWordCount = 8

    struct IdentificationResult {
        let ayahIndex: Int
        /// Flat-word index this resolves to - the new `confirmedPosition`.
        let flatPosition: Int
        /// True when this resolution was reached off fewer than
        /// `solidEvidenceWordCount` observed words - callers should treat it
        /// as tentative until a few more words track cleanly (see
        /// `provisionalUpdate`), rather than fully trusting it outright.
        let isProvisional: Bool
    }

    /// Whole-Quran identification: a cheap per-ayah word-overlap prefilter,
    /// then precise alignment against each surviving candidate's word
    /// window (widened a few words into the next ayah so a tail straddling
    /// an ayah boundary before anything resolves still works), ranked by
    /// alignment cost (edit distance) rather than treating every candidate
    /// that merely passes as equally valid. Resolves outright on a uniquely
    /// best-cost candidate - even off a single, sufficiently distinctive
    /// word (e.g. a word that appears exactly once in the whole Quran):
    /// a cost-0 match with every other candidate strictly worse is real
    /// evidence regardless of tail length, so there's no separate minimum-
    /// word gate on this path. On a genuine tie at the best cost (a shared
    /// opening, not a uniquely distinctive word), narrows using
    /// `currentPages` only once enough words have been heard and the tie
    /// isn't too wide (see `minWordsForPageAssistedResolve`/
    /// `maxPageAssistedTieSize`) - ties are where premature commitment is
    /// actually risky. Otherwise returns nil ("still searching" - deliberate
    /// on genuine ambiguity, e.g. a bare repeated refrain, rather than
    /// guessing). `excluding` skips ayahs already rejected by a prior
    /// identification attempt this session (see `RecitationSession`), so a
    /// single mis-transcribed word can't cause the same wrong ayah to be
    /// re-picked immediately after being reopened.
    static func identifyAyah(
        tailWords: [String], database: QuranDatabase, currentPages: ClosedRange<Int>?, excluding: Set<Int> = []
    ) -> IdentificationResult? {
        guard !tailWords.isEmpty else { return nil }

        let tailSet = Set(tailWords)
        let minOverlap = max(0, tailWords.count - maxConsecutiveErrors)

        struct Candidate { let ayahIndex: Int; let flatPosition: Int; let cost: Int }
        var candidates: [Candidate] = []
        for (ayahIndex, ayah) in database.ayahs.enumerated() {
            guard !ayah.groundTruthSkeletonWords.isEmpty, !excluding.contains(ayahIndex) else { continue }
            let start = database.flatStart(ofAyahIndex: ayahIndex)
            // Widened a few words into the next ayah so a tail straddling an
            // ayah boundary (or a single-word ayah, e.g. a muqata'at opener
            // on its own, where the ayah's own words alone would almost
            // never pass the overlap prefilter below) still has enough
            // window to match against. The prefilter itself must use this
            // same widened window, not just the ayah's own words, for
            // exactly that reason.
            let windowEnd = min(database.flatWords.count, start + ayah.groundTruthSkeletonWords.count + 6)
            let window = database.flatWords[start..<windowEnd].map(\.skeleton)

            let overlap = window.reduce(into: 0) { count, w in if tailSet.contains(w) { count += 1 } }
            guard overlap >= min(minOverlap, window.count) else { continue }

            guard let alignment = align(observed: tailWords, candidate: window, freeLeadingCandidate: true) else { continue }
            let flatPosition = start + alignment.candidateStart
            // A match can land inside the widened tail - i.e. actually in
            // the *next* ayah's own words, not this loop's ayah - so the
            // resolved ayah must come from where the match landed, not from
            // which ayah's window we happened to search. Without this, a
            // word within the first few words of an ayah (e.g. its very
            // first word) looks like it independently "matches" both that
            // ayah and its widened-into predecessor, creating a false tie
            // out of what both really identify as the same position.
            let resolvedAyahIndex = database.flatWords[min(flatPosition, database.flatWords.count - 1)].ayahIndex
            guard !excluding.contains(resolvedAyahIndex) else { continue }
            candidates.append(Candidate(ayahIndex: resolvedAyahIndex, flatPosition: flatPosition, cost: alignment.cost))
        }

        // Collapse duplicates: different loop iterations resolving to the
        // same real position (see above) must count as one candidate, not a
        // tie with itself - keeping the lowest cost seen for each ayah.
        var bestByAyah: [Int: Candidate] = [:]
        for c in candidates where bestByAyah[c.ayahIndex].map({ c.cost < $0.cost }) ?? true {
            bestByAyah[c.ayahIndex] = c
        }
        candidates = Array(bestByAyah.values)

        guard !candidates.isEmpty else { return nil }
        let isProvisional = tailWords.count < solidEvidenceWordCount

        let minCost = candidates.map(\.cost).min()!
        let bestTier = candidates.filter { $0.cost == minCost }
        if bestTier.count == 1 {
            return IdentificationResult(ayahIndex: bestTier[0].ayahIndex, flatPosition: bestTier[0].flatPosition, isProvisional: isProvisional)
        }

        guard tailWords.count >= minWordsForPageAssistedResolve, bestTier.count <= maxPageAssistedTieSize,
              let pages = currentPages
        else { return nil }
        let onPage = bestTier.filter { c in
            let a = database.ayahs[c.ayahIndex]
            return a.startPage <= pages.upperBound && a.endPage >= pages.lowerBound
        }
        guard onPage.count == 1 else { return nil }
        return IdentificationResult(ayahIndex: onPage[0].ayahIndex, flatPosition: onPage[0].flatPosition, isProvisional: isProvisional)
    }

    // MARK: - Provisional-state bookkeeping

    /// How many further words (matches or tolerated substitutions - both
    /// mean forward alignment held, which is the actual signal a provisional
    /// identification is correct) must track cleanly before a provisional
    /// result is promoted to confirmed.
    static let provisionalVerificationWordCount = 4

    /// Given the previous provisional state and this tick's `advance`
    /// outcome, returns the next state. A freeze while still provisional
    /// signals "this early guess looks wrong" - the caller reopens
    /// identification from scratch (excluding the rejected ayah) rather
    /// than sitting frozen indefinitely. Enough successfully-tracked words
    /// instead promotes provisional -> confirmed.
    static func provisionalUpdate(
        isProvisional: Bool, wordsRemaining: Int, outcome: AdvanceOutcome, commitSteps: [(flatIndex: Int, step: Step, tashkeelOK: Bool?)]
    ) -> (isProvisional: Bool, wordsRemaining: Int, shouldReopen: Bool) {
        guard isProvisional else { return (false, 0, false) }
        if outcome == .frozen {
            return (true, wordsRemaining, true)
        }
        let tracked = commitSteps.filter { $0.step.kind == .match || $0.step.kind == .substitute }.count
        let remaining = max(0, wordsRemaining - tracked)
        return (remaining > 0, remaining, false)
    }

    // MARK: - Tracking

    enum AdvanceOutcome: Equatable {
        case forward
        case backtrack
        case frozen
    }

    struct AdvanceResult {
        let outcome: AdvanceOutcome
        /// New confirmed position - meaningful for `.forward`/`.backtrack`.
        let newPosition: Int
        /// Steps to commit (score/print), each paired with its absolute
        /// flat-word index (or, for `.extra` steps, the flat index they
        /// immediately precede) - only the finalized portion (see
        /// `finalizeGrace`), in order. Empty for `.frozen`. `tashkeelOK` is
        /// only meaningful for `.match` steps (nil otherwise): whether the
        /// heard word's tashkeel matched either ground-truth variant (see
        /// `Ayah.groundTruthWordsAlt`) - already gated by the same grace
        /// rule as a wrong word (see `buildResult`), so callers can print it
        /// directly without re-deriving or further delay.
        let commitSteps: [(flatIndex: Int, step: Step, tashkeelOK: Bool?)]
    }

    static let defaultForwardWindow = 30
    static let defaultBacktrackPages = 2
    /// How many further steps must exist after a *non-match* step
    /// (substitute/missed/extra) before it's committed (scored/printed) -
    /// asymmetric on purpose (see `buildResult`): a `.match` commits
    /// immediately regardless of this value, since there's no benefit to
    /// delaying good news, but a step that looks wrong waits for this much
    /// trailing context first, since the ASR's periodic re-decode can still
    /// revise it and concluding "wrong" too hastily is the worse failure
    /// mode for that case.
    static let finalizeGrace = 3

    /// One tracking tick: tries forward-only first (fixed start at
    /// `confirmedPosition`, tolerant of up to `maxConsecutiveErrors`
    /// consecutive issues), then a local backtrack search (free start,
    /// widened back to `floor`) if forward fails, accepting it only if the
    /// resolved start is genuinely behind `confirmedPosition` (a forward
    /// skip is never resolved this way - the reciter must pause/resume to
    /// jump ahead past un-recited material, same as any other unrelated
    /// jump). Returns `.frozen` if neither succeeds - the caller resolves
    /// nothing and simply retries next tick.
    static func advance(
        observed: [String], observedTashkeel: [String], confirmedPosition: Int, floor: Int, database: QuranDatabase,
        forwardWindow: Int = defaultForwardWindow, backtrackPages: Int = defaultBacktrackPages
    ) -> AdvanceResult {
        guard !observed.isEmpty, !database.flatWords.isEmpty else {
            return AdvanceResult(outcome: .frozen, newPosition: confirmedPosition, commitSteps: [])
        }
        let flat = database.flatWords

        let forwardEnd = min(flat.count, confirmedPosition + forwardWindow)
        if forwardEnd > confirmedPosition {
            let window = flat[confirmedPosition..<forwardEnd].map(\.skeleton)
            if let alignment = align(observed: observed, candidate: window, freeLeadingCandidate: false) {
                return buildResult(.forward, alignment: alignment, base: confirmedPosition, observed: observed, observedTashkeel: observedTashkeel, flat: flat)
            }
        }

        let ayahIndex = flat[min(confirmedPosition, flat.count - 1)].ayahIndex
        let currentPage = database.ayahs[ayahIndex].startPage
        let backtrackStart = max(floor, database.flatWordIndex(pagesBack: backtrackPages, fromPage: currentPage))
        if backtrackStart < confirmedPosition {
            let window = flat[backtrackStart..<forwardEnd].map(\.skeleton)
            if let alignment = align(observed: observed, candidate: window, freeLeadingCandidate: true) {
                let newStart = backtrackStart + alignment.candidateStart
                // Never resolve a *forward* skip via this tier - only
                // genuine backtracks (see the doc comment above).
                if newStart < confirmedPosition {
                    return buildResult(.backtrack, alignment: alignment, base: backtrackStart, observed: observed, observedTashkeel: observedTashkeel, flat: flat)
                }
            }
        }

        return AdvanceResult(outcome: .frozen, newPosition: confirmedPosition, commitSteps: [])
    }

    /// Commits steps in order, asymmetrically: a step only commits
    /// immediately if it's a `.match` *and* its tashkeel also checks out -
    /// there's no benefit to delaying good news. Anything short of that
    /// (a genuinely wrong/missed/extra word, or a right word whose tashkeel
    /// doesn't match either ground-truth variant) only commits once at
    /// least `finalizeGrace` further steps exist after it, giving the ASR's
    /// periodic re-decode a chance to revise it first rather than
    /// concluding "wrong" (at either granularity) too hastily. The loop
    /// *stops* at the first such step that doesn't yet have enough trailing
    /// context - not just skips it - so later matches don't get committed
    /// ahead of a still-unresolved earlier problem (which would desync
    /// `newPosition` from what's actually been judged); a future tick, with
    /// more transcript, revisits it fresh.
    /// Reconstructs the transcribed tashkeel text a `.match` step actually
    /// heard - just `observedTashkeel[step.observedIndex]`, unless the step
    /// resolved via a merge match (see `Step.mergedObservedIndex`), in which
    /// case the merged word is prepended so e.g. "ان" + "ما" reads as
    /// "انما" for comparison against the single-word ground truth. Nil if
    /// either index is out of bounds.
    static func heardTashkeel(for step: Step, observedTashkeel: [String]) -> String? {
        guard let oi = step.observedIndex, oi < observedTashkeel.count else { return nil }
        guard let mi = step.mergedObservedIndex else { return observedTashkeel[oi] }
        guard mi < observedTashkeel.count else { return nil }
        return observedTashkeel[mi] + observedTashkeel[oi]
    }

    private static func buildResult(
        _ outcome: AdvanceOutcome, alignment: Alignment, base: Int, observed: [String], observedTashkeel: [String], flat: [FlatWord]
    ) -> AdvanceResult {
        var commit: [(flatIndex: Int, step: Step, tashkeelOK: Bool?)] = []
        var nextCandidateIndex = alignment.candidateStart
        let steps = alignment.steps
        for (index, step) in steps.enumerated() {
            var tashkeelOK: Bool?
            if step.kind == .match, let ci = step.candidateIndex {
                let expected = flat[base + ci]
                if let heard = heardTashkeel(for: step, observedTashkeel: observedTashkeel) {
                    let heardFolded = foldTaMarbutaForComparison(heard)
                    tashkeelOK = heardFolded == foldTaMarbutaForComparison(expected.groundTruth)
                        || heardFolded == foldTaMarbutaForComparison(expected.groundTruthAlt)
                } else {
                    tashkeelOK = false
                }
            }
            let needsGrace = step.kind != .match || tashkeelOK == false
            if needsGrace, steps.count - 1 - index < finalizeGrace {
                break
            }
            switch step.kind {
            case .match, .substitute, .missed:
                let ci = step.candidateIndex!
                commit.append((base + ci, step, tashkeelOK))
                nextCandidateIndex = ci + 1
            case .extra:
                commit.append((base + nextCandidateIndex, step, tashkeelOK))
            }
        }
        return AdvanceResult(outcome: outcome, newPosition: base + nextCandidateIndex, commitSteps: commit)
    }

    // MARK: - Observed-tail resolution

    /// The live transcript is a full re-decode of a *rolling* window of
    /// audio (not append-only growth), so a persisted numeric cursor into
    /// it isn't reliable long-term - once old words age out of the rolling
    /// window, any index-based position becomes meaningless as the array's
    /// content shifts. Instead, find where the most recently committed
    /// words last occur (as a short exact-match anchor) and take everything
    /// after that as "new since last commit". Falls back to a generous
    /// trailing suffix if the anchor isn't found (e.g. it aged out of the
    /// window already, or nothing has been committed yet).
    static func observedTail(transcript: [String], anchor: [String], fallbackSuffix: Int = 40) -> [String] {
        guard !anchor.isEmpty, transcript.count >= anchor.count else {
            return Array(transcript.suffix(fallbackSuffix))
        }
        var lastEnd: Int?
        var i = 0
        while i + anchor.count <= transcript.count {
            if Array(transcript[i..<(i + anchor.count)]) == anchor {
                lastEnd = i + anchor.count
            }
            i += 1
        }
        guard let end = lastEnd else {
            return Array(transcript.suffix(fallbackSuffix))
        }
        return Array(transcript[end...])
    }
}
