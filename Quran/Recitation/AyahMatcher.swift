import Foundation

/// Result of one matching attempt against the current word-indexed cursor
/// state (§7 of the transcription plan). Pure/stateless so it's callable
/// identically from the real per-0.5s tick loop and from offline tests.
struct AyahMatchAttempt {
    let ayah: Ayah?
    let newCursor: Int
}

/// A tail that keeps failing to match is normally left alone (see below),
/// but an unmatchable *first* word (e.g. the ASR glued two ayahs together
/// with no space, corrupting the earliest token) would otherwise block
/// progress forever, since a substring search can never skip past a
/// leading token it can't place. Past this many words with zero
/// candidates, give up on just the oldest word and retry from the next
/// one - bounds the stall without giving up as aggressively as discarding
/// the whole tail.
private let stuckTailWordLimit = 20

/// One matching attempt: given the full (harakat-aware) word list of the
/// transcript so far and how much of it is already resolved, tries the
/// current tail against the database using the harakat-stripped skeleton
/// (forgiving of ASR/database representation differences - a single wrong
/// diacritic must never block recognizing the ayah), then runs a
/// non-blocking per-word tashkeel-correctness check once the ayah is known
/// (flags mismatches via `print`, doesn't stall progress on them - a
/// foundation for future accuracy/mistake scoring, not implemented yet).
func attemptAyahMatch(
    words: [String], cursor: Int, database: QuranDatabase, currentPages: ClosedRange<Int>
) -> AyahMatchAttempt {
    guard cursor <= words.count else {
        return AyahMatchAttempt(ayah: nil, newCursor: words.count)
    }
    let tailWords = Array(words[cursor...])
    guard !tailWords.isEmpty else {
        return AyahMatchAttempt(ayah: nil, newCursor: cursor)
    }

    let skeletonTail = normalizeArabicSkeleton(tailWords.joined(separator: " "))
    func isOnPage(_ ayah: Ayah) -> Bool {
        ayah.startPage <= currentPages.upperBound && ayah.endPage >= currentPages.lowerBound
    }

    // Fix 3: the page currently on screen already narrows candidates to a
    // handful of ayahs, so a single unique word is enough to resolve
    // immediately - don't make the reciter wait for 3 words in that case.
    let onPageAny = database.ayahs.filter { isOnPage($0) && $0.skeletonText.contains(skeletonTail) }
    if onPageAny.count == 1 {
        return resolveMatch(ayah: onPageAny[0], tailWords: tailWords, cursor: cursor)
    }

    // Fix 2: targeted muqatta'at fallback, tried at any tail length since a
    // glued muqatta'at+next-word token (e.g. "المذلك") can be as short as
    // 1-2 words. Matched space-insensitively against the small hardcoded
    // table only, so this can't accidentally fire off any short word
    // elsewhere in the Quran - see QuranDatabase.muqattaatEntries.
    let strippedTail = skeletonTail.replacingOccurrences(of: " ", with: "")
    if !strippedTail.isEmpty {
        let muqattaatMatches = database.muqattaatCandidates(forStrippedSubstring: strippedTail)
        let onPageMuqattaat = muqattaatMatches.filter { isOnPage($0.resolvesTo) }
        if onPageMuqattaat.count == 1 {
            return resolveMatch(ayah: onPageMuqattaat[0].resolvesTo, tailWords: tailWords, cursor: cursor)
        }
        if onPageMuqattaat.isEmpty && muqattaatMatches.count == 1 {
            return resolveMatch(ayah: muqattaatMatches[0].resolvesTo, tailWords: tailWords, cursor: cursor)
        }
    }

    guard tailWords.count >= 3 else {
        return AyahMatchAttempt(ayah: nil, newCursor: cursor)
    }

    let candidates = database.candidates(forSkeletonSubstring: skeletonTail)
    if !candidates.isEmpty {
        let onPage = candidates.filter(isOnPage)
        if onPage.count == 1 {
            return resolveMatch(ayah: onPage[0], tailWords: tailWords, cursor: cursor)
        }
        if candidates.count == 1 {
            return resolveMatch(ayah: candidates[0], tailWords: tailWords, cursor: cursor)
        }
        return AyahMatchAttempt(ayah: nil, newCursor: cursor)
    }

    // Fix 1: nothing matched a single ayah - the tail may straddle an ayah
    // boundary (e.g. the reciter started mid-way through one ayah and
    // continued into the next before anything resolved). Try consecutive
    // ayah pairs; on a unique hit, resolve to the earlier ayah only, so the
    // still-unconsumed start of the next ayah stays in the tail for the
    // following tick.
    let pairCandidates = database.pairCandidates(forSkeletonSubstring: skeletonTail)
    if !pairCandidates.isEmpty {
        let onPagePairs = pairCandidates.filter { isOnPage($0.first) }
        if onPagePairs.count == 1 {
            return resolveMatch(ayah: onPagePairs[0].first, tailWords: tailWords, cursor: cursor)
        }
        if onPagePairs.isEmpty && pairCandidates.count == 1 {
            return resolveMatch(ayah: pairCandidates[0].first, tailWords: tailWords, cursor: cursor)
        }
        return AyahMatchAttempt(ayah: nil, newCursor: cursor)
    }

    if tailWords.count > stuckTailWordLimit {
        return AyahMatchAttempt(ayah: nil, newCursor: cursor + 1)
    }
    return AyahMatchAttempt(ayah: nil, newCursor: cursor)
}

/// Runs the non-blocking Tier-2 tashkeel check and builds the resolved
/// attempt - shared by every resolution path above (single-ayah, on-page
/// single-word, cross-ayah-boundary pair, muqatta'at fallback) so the
/// cursor-advancement rule stays in exactly one place.
private func resolveMatch(ayah: Ayah, tailWords: [String], cursor: Int) -> AyahMatchAttempt {
    let checkedWordCount = min(tailWords.count, ayah.tashkeelWords.count)
    for i in 0..<checkedWordCount where tailWords[i] != ayah.tashkeelWords[i] {
        print("  tashkeel mismatch word \(i + 1): expected \"\(ayah.tashkeelWords[i])\" got \"\(tailWords[i])\"")
    }
    return AyahMatchAttempt(ayah: ayah, newCursor: cursor + ayah.tashkeelWords.count)
}
