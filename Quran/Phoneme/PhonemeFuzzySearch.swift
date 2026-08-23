import Foundation

/// Bounded edit-distance approximate substring search: find every region of
/// `text` where `pattern` matches with edit distance <= `maxLDist`. Swift
/// has no equivalent of Python's `fuzzysearch.find_near_matches` (which
/// `qrc`'s locator uses), so this is a from-scratch implementation.
///
/// Two-phase, to avoid ever materializing an O(pattern * corpus) matrix:
/// 1. **Forward pass** over the whole corpus, free-start (row 0 all zero, so
///    a match can begin anywhere) - finds every text end-position whose
///    best-possible alignment distance is <= `maxLDist`. For `pattern.count
///    <= 64` (true for every real caller: `Settings.maxBufferChars` caps the
///    locator's own query at 60, and the backtrack probe's accumulated
///    suspect buffer is realistically always under 64 too) this runs
///    Myers' bit-vector algorithm (Myers 1999 / Hyyrö 2003's exposition of
///    it), which packs an entire DP row into one `UInt64` and processes each
///    text character in O(1) instead of O(pattern.count) - the difference
///    between a locator that keeps up with live audio and one that doesn't.
///    Longer patterns fall back to a plain O(pattern * corpus) two-row DP
///    (kept as `slowForwardPassLastRow`, and as the reference implementation
///    `PhonemeFuzzySearchTests`'s differential tests check the fast path
///    against on hundreds of random cases - a silently wrong bit-vector
///    derivation would mean wrong ayah localizations, which is a far worse
///    failure mode than being slow, so it earned that scrutiny before
///    shipping).
/// 2. **Windowed backtrack**: for each accepted end position, the true
///    start can never be more than `pattern.count + maxLDist` characters
///    before it (provably: every edit op with cost 1 can move the text
///    cursor by at most 1, and cost-0 ops move it by exactly 1, so a path
///    of total cost <= maxLDist spans at most pattern.count + maxLDist text
///    characters) - so re-run a small, *bounded* free-start DP with full
///    backpointers on just that slice to recover the exact start offset.
///    This is what makes phase 2 cheap even though phase 1 only kept
///    distances, not backpointers, for the whole corpus.
enum PhonemeFuzzySearch {
    struct Match {
        let start: Int
        let end: Int
        let dist: Int
    }

    static func findNearMatches(pattern: [Unicode.Scalar], in text: [Unicode.Scalar], maxLDist: Int) -> [Match] {
        guard !pattern.isEmpty, !text.isEmpty, maxLDist >= 0 else { return [] }
        let m = pattern.count
        let n = text.count

        let lastRow = pattern.count <= 64
            ? myersLastRow(pattern: pattern, text: text)
            : slowForwardPassLastRow(pattern: pattern, text: text)

        var rawCandidates: [(end: Int, dist: Int)] = []
        rawCandidates.reserveCapacity(16)
        for j in 0...n where lastRow[j] <= Int32(maxLDist) {
            rawCandidates.append((j, Int(lastRow[j])))
        }
        guard !rawCandidates.isEmpty else { return [] }

        // Cluster adjacent end positions (within one pattern-length of each
        // other -- they're almost certainly the same underlying match,
        // scored at consecutive text positions) and keep only the local
        // best (lowest distance) per cluster, mirroring fuzzysearch's
        // "one match per region" behavior closely enough for this caller's
        // needs (top-1 / top-2 scoring, not an exhaustive match listing).
        var clusters: [(end: Int, dist: Int)] = []
        var clusterBest = rawCandidates[0]
        var lastEnd = rawCandidates[0].end
        for cand in rawCandidates.dropFirst() {
            if cand.end - lastEnd <= m {
                if cand.dist < clusterBest.dist { clusterBest = cand }
            } else {
                clusters.append(clusterBest)
                clusterBest = cand
            }
            lastEnd = cand.end
        }
        clusters.append(clusterBest)

        var results: [Match] = []
        results.reserveCapacity(clusters.count)
        for c in clusters {
            let windowStart = max(0, c.end - m - maxLDist)
            let slice = Array(text[windowStart..<c.end])
            guard let (localStart, dist) = windowedBacktrackStart(pattern: pattern, textSlice: slice) else { continue }
            results.append(Match(start: windowStart + localStart, end: c.end, dist: dist))
        }
        return results
    }

    /// Myers' bit-vector algorithm (Myers 1999) for the free-start
    /// ("approximate string matching" / search) problem: computes row
    /// `pattern.count` of the same DP `slowForwardPassLastRow` computes,
    /// but each text character costs O(1) bitwise ops on one `UInt64`
    /// instead of O(pattern.count) integer cells - only valid for
    /// `pattern.count <= 64` (one word).
    ///
    /// The delta-encoding: `Pv`/`Mv` hold, for the *current* column, the
    /// vertical deltas `dp[i][j] - dp[i-1][j]` for rows `i = 1...m` (bit
    /// `i-1` set in `Pv` means delta +1, in `Mv` means delta -1, both clear
    /// means delta 0 - the standard bit-parallel encoding since unit-cost
    /// edit distance deltas are always in {-1, 0, +1}). Each column step
    /// derives the *horizontal* deltas (`Ph`/`Mh`, `dp[i][j] - dp[i][j-1]`)
    /// for every row from the previous column's vertical deltas plus which
    /// pattern positions equal the new text character (`Eq`), via the
    /// arithmetic-carry trick in the `Xh` line (a carry into higher bits is
    /// exactly how "a run of matching characters" propagates a doubled
    /// vertical-delta pattern one row-block at a time, in O(1) regardless of
    /// how long the run is). `dp[i][0] = i` (matching `dp[i][0] = i` in the
    /// row-0-free-start DP - unaffected by free-start, which only changes
    /// row 0 itself) is why `Pv` starts all-ones and `Score` starts at `m`.
    ///
    /// Free-start (row 0 always 0, so a match can begin at any text
    /// position) falls out of this recurrence for free, with *no* per-column
    /// modification: row 0 never appears in `Pv`/`Mv` at all (they only
    /// encode rows `1...m`), so the chain implicitly treats "row 0" as an
    /// unchanging 0 reference at every column - which is exactly free-start
    /// semantics. (Confirmed by differential-testing against
    /// `slowForwardPassLastRow` across hundreds of random cases - a plausible
    /// first guess at this point was that free-start needs an *extra*
    /// per-column tweak, e.g. forcing bit 0 of `Ph` to 1; empirically that
    /// instead produces *fixed*-start distance, `dp[0][j] = j` - the
    /// opposite of what's needed here.)
    static func myersLastRow(pattern: [Unicode.Scalar], text: [Unicode.Scalar]) -> [Int32] {
        let m = pattern.count
        let n = text.count
        precondition(m > 0 && m <= 64, "myersLastRow requires 1...64 pattern scalars; findNearMatches routes longer patterns to slowForwardPassLastRow")
        let mask: UInt64 = m == 64 ? .max : (UInt64(1) << m) - 1

        var peq: [Unicode.Scalar: UInt64] = [:]
        peq.reserveCapacity(m)
        for (i, scalar) in pattern.enumerated() {
            peq[scalar, default: 0] |= (UInt64(1) << i)
        }

        var pv: UInt64 = mask
        var mv: UInt64 = 0
        var score = Int32(m)
        let topBit: UInt64 = UInt64(1) << (m - 1)

        var result = [Int32](repeating: 0, count: n + 1)
        result[0] = score

        text.withUnsafeBufferPointer { txt in
            result.withUnsafeMutableBufferPointer { out in
                for j in 0..<n {
                    let eq = peq[txt[j]] ?? 0
                    let xv = eq | mv
                    let xh = (((eq & pv) &+ pv) ^ pv) | eq
                    let ph = mv | ~(xh | pv)
                    let mh = pv & xh

                    if ph & topBit != 0 {
                        score += 1
                    } else if mh & topBit != 0 {
                        score -= 1
                    }

                    let phShifted = ph << 1
                    let mhShifted = mh << 1

                    pv = (mhShifted | ~(xv | phShifted)) & mask
                    mv = (phShifted & xv) & mask

                    out[j + 1] = score
                }
            }
        }
        return result
    }

    /// Row `pattern.count` of the free-start edit-distance DP against the
    /// whole `text`, keeping only two rows in memory. Fallback for
    /// `pattern.count > 64` (see `myersLastRow`), and the reference
    /// implementation the differential tests check `myersLastRow` against.
    /// `withUnsafeMutableBufferPointer` throughout: this runs on every
    /// locator attempt while not yet localized, so it needs to stay fast
    /// even in a Debug build (no array bounds-check overhead in the inner
    /// loop).
    static func slowForwardPassLastRow(pattern: [Unicode.Scalar], text: [Unicode.Scalar]) -> [Int32] {
        let m = pattern.count
        let n = text.count
        // `1...0` (empty text) or `1...0` (empty pattern) are invalid
        // `ClosedRange`s in Swift -- guard both before the loops below,
        // which assume at least one row/column to iterate.
        guard m > 0 else { return [Int32](repeating: 0, count: n + 1) }
        guard n > 0 else { return [Int32(m)] }

        var prev = [Int32](repeating: 0, count: n + 1)
        var curr = [Int32](repeating: 0, count: n + 1)

        pattern.withUnsafeBufferPointer { pat in
            text.withUnsafeBufferPointer { txt in
                for i in 1...m {
                    let pi = pat[i - 1]
                    prev.withUnsafeMutableBufferPointer { prevBuf in
                        curr.withUnsafeMutableBufferPointer { currBuf in
                            currBuf[0] = Int32(i)
                            for j in 1...n {
                                let subCost: Int32 = pi == txt[j - 1] ? 0 : 1
                                let diag = prevBuf[j - 1] + subCost
                                let up = prevBuf[j] + 1
                                let left = currBuf[j - 1] + 1
                                currBuf[j] = min(diag, up, left)
                            }
                        }
                    }
                    swap(&prev, &curr)
                }
            }
        }
        return prev
    }

    /// Free-start DP with full backpointers, restricted to a small slice
    /// already known to contain the true match start (see the type doc).
    /// Returns (start offset within the slice, distance).
    private static func windowedBacktrackStart(pattern: [Unicode.Scalar], textSlice: [Unicode.Scalar]) -> (start: Int, dist: Int)? {
        let m = pattern.count
        let n = textSlice.count
        guard m > 0, n > 0 else { return nil }

        var dp = [[Int32]](repeating: [Int32](repeating: 0, count: n + 1), count: m + 1)
        var bp = [[PhonemeDPOp?]](repeating: [PhonemeDPOp?](repeating: nil, count: n + 1), count: m + 1)
        for i in 1...m {
            dp[i][0] = Int32(i)
            bp[i][0] = .insertA
        }
        for i in 1...m {
            let pi = pattern[i - 1]
            for j in 1...n {
                let subCost: Int32 = pi == textSlice[j - 1] ? 0 : 1
                let diag = dp[i - 1][j - 1] + subCost
                let up = dp[i - 1][j] + 1
                let left = dp[i][j - 1] + 1
                var best = diag
                var op = PhonemeDPOp.match
                if up < best { best = up; op = .insertA }
                if left < best { best = left; op = .deleteA }
                dp[i][j] = best
                bp[i][j] = op
            }
        }

        let dist = Int(dp[m][n])
        var i = m, j = n
        while i > 0 {
            guard let op = bp[i][j] else { break }
            switch op {
            case .match:
                i -= 1; j -= 1
            case .insertA:
                i -= 1
            case .deleteA:
                j -= 1
            }
        }
        return (j, dist)
    }
}
