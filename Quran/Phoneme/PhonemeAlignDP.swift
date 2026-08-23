import Foundation

/// Edit-distance alignment with backpointers, small-buffer O(n*m) DP - port
/// of `qrc/align/dp.py`. Buffers passed in here are kept small by the
/// caller (a handful of words at a time, trimmed after each settled word),
/// so a plain full DP is fast enough - no banding needed at this scale.
enum PhonemeDPOp: Int8, Equatable {
    case match = 0
    case insertA = 1  // a[i-1] is extra, not present in b (recited something extra / ASR noise)
    case deleteA = 2  // b[j-1] has no counterpart in a (skipped / not recited)
}

struct PhonemeDPResult {
    /// dp[i][j] = min edit distance between a[..<i] and b[..<j].
    let dp: [[Int32]]
    let bp: [[PhonemeDPOp?]]
}

enum PhonemeAlignDP {
    /// Inserting/deleting a character that's a literal repeat of the one
    /// immediately before it in the *same* string is free, not a real
    /// edit -- this is `PhonemeNormalize.collapseRuns`'s tajweed-length
    /// tolerance (madd elongation, gemination, ghunna) applied directly to
    /// the alignment cost, rather than only checked after the fact on an
    /// already-settled word. Without this, a live recitation whose madd
    /// marks happen to be a couple of repeats short/long of the corpus's
    /// exact count (extremely common -- elongation duration isn't fixed)
    /// makes the plain DP's global-minimum boundary land a few characters
    /// *before* the word's true end, which then never resolves until
    /// enough trailing audio piles up to tip the arithmetic back the other
    /// way -- in practice, for an ayah-final word followed by a natural
    /// pause, that means waiting for the *next* ayah's first word before
    /// this word ever settles. Confirmed via a live capture: "ٱلْعَـٰلَمِينَ"
    /// (32:2's last word) sat unsettled from the moment its audio finished
    /// (all tokens in hand, madd run just 2 short of the corpus's 4) until
    /// 32:3's opening tokens arrived nearly four seconds later.
    private static func isRunContinuation(_ s: [Unicode.Scalar], at index: Int) -> Bool {
        index >= 1 && s[index] == s[index - 1]
    }

    static func editDistanceWithBackpointers(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> PhonemeDPResult {
        let n = a.count, m = b.count
        var dp = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        var bp = [[PhonemeDPOp?]](repeating: [PhonemeDPOp?](repeating: nil, count: m + 1), count: n + 1)

        for i in 1...max(n, 1) where n > 0 {
            let insertCost: Int32 = isRunContinuation(a, at: i - 1) ? 0 : 1
            dp[i][0] = dp[i - 1][0] + insertCost
            bp[i][0] = .insertA
        }
        for j in 1...max(m, 1) where m > 0 {
            let deleteCost: Int32 = isRunContinuation(b, at: j - 1) ? 0 : 1
            dp[0][j] = dp[0][j - 1] + deleteCost
            bp[0][j] = .deleteA
        }

        guard n > 0, m > 0 else { return PhonemeDPResult(dp: dp, bp: bp) }

        for i in 1...n {
            let ai = a[i - 1]
            let insertCost: Int32 = isRunContinuation(a, at: i - 1) ? 0 : 1
            for j in 1...m {
                let subCost: Int32 = ai == b[j - 1] ? 0 : 1
                let deleteCost: Int32 = isRunContinuation(b, at: j - 1) ? 0 : 1
                let diag = dp[i - 1][j - 1] + subCost
                let up = dp[i - 1][j] + insertCost
                let left = dp[i][j - 1] + deleteCost

                var best = diag
                var op = PhonemeDPOp.match
                if up < best { best = up; op = .insertA }
                if left < best { best = left; op = .deleteA }

                dp[i][j] = best
                bp[i][j] = op
            }
        }
        return PhonemeDPResult(dp: dp, bp: bp)
    }

    /// One traceback step: (i-1, nil, op) for insertA, (nil, j-1, op) for
    /// deleteA, (i-1, j-1, op) for match. `nil` mirrors Python's `None`.
    struct Step {
        let i: Int?
        let j: Int?
        let op: PhonemeDPOp
    }

    static func traceback(_ bp: [[PhonemeDPOp?]], _ startI: Int, _ startJ: Int) -> [Step] {
        var path: [Step] = []
        var i = startI, j = startJ
        while i > 0 || j > 0 {
            guard let op = bp[i][j] else { break }
            switch op {
            case .match:
                path.append(Step(i: i - 1, j: j - 1, op: .match))
                i -= 1; j -= 1
            case .insertA:
                path.append(Step(i: i - 1, j: nil, op: .insertA))
                i -= 1
            case .deleteA:
                path.append(Step(i: nil, j: j - 1, op: .deleteA))
                j -= 1
            }
        }
        path.reverse()
        return path
    }

    /// Index of the minimum value in `row` (first occurrence, ties broken
    /// toward the smallest index -- matches numpy's `argmin`).
    static func argmin(_ row: [Int32]) -> Int {
        var bestIdx = 0
        var bestVal = row[0]
        for i in 1..<row.count where row[i] < bestVal {
            bestVal = row[i]
            bestIdx = i
        }
        return bestIdx
    }

    /// `argmin`, but promoted to `boundary` when `boundary` itself ties the
    /// row's true minimum -- the settle-boundary decision's own variant,
    /// kept separate so `argmin` itself stays numpy-faithful for anything
    /// else that wants it.
    ///
    /// The free-repeat costs above mean a word whose expected text ends in
    /// a repeated character (a doubled letter, an "اا" alif-madd, any
    /// tajweed-length run) legitimately ties the true boundary's cost with
    /// stopping *one character short of it* -- explaining actual's own
    /// trailing repeat as a free insertion against a truncated expected
    /// prefix costs exactly the same as consuming that whole final repeat
    /// from expected. Plain `argmin`'s first-occurrence tie-breaking always
    /// picks the short one, which never fully closes the gap to `boundary`
    /// no matter how exactly the word was recited -- confirmed via a live
    /// capture: "حَكِۦۦمَاا" recited as an exact literal match to its own
    /// expected phonemes still sat unsettled until the *next* ayah's audio
    /// arrived.
    ///
    /// Deliberately narrow, not "prefer the largest tied index" over the
    /// whole row: that was tried first and broke real recitation-check
    /// runs -- once a word's actual content is *genuinely* unrelated to
    /// what's expected (a backtrack to an earlier ayah, not just a normal
    /// mismatch), free deletions can chain through unrelated repeat runs
    /// scattered anywhere in the multi-word lookahead buffer, so "largest
    /// tied index" drifted arbitrarily far across several words instead of
    /// stopping at the one specific position this is actually meant to
    /// rescue. Checking only the word's own known `boundary` bounds the
    /// fix to exactly the case it's for.
    static func argmin(_ row: [Int32], preferringBoundary boundary: Int) -> Int {
        let plain = argmin(row)
        guard boundary >= 0, boundary < row.count else { return plain }
        return row[boundary] == row[plain] ? boundary : plain
    }
}
