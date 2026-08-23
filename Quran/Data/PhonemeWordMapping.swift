import Foundation

/// Bridges the phoneme corpus's own per-word indexing (`PhonemeCorpus`,
/// segmented by `word_text_map.json` from `quran-transcript`'s Uthmani
/// output) onto `QuranDatabase.flatWords`' indexing (segmented from the
/// mushaf SVG's own Uthmani word rows). Both are independently-derived real-
/// written-word sequences in the *same* script convention, so this
/// reconciles them with the existing `reconcileWordSlots`/
/// `proportionalWordSlotMapping` machinery (`WordLocation.swift`) rather
/// than inventing a second algorithm.
final class PhonemeWordMapping {
    /// Ayah refs where `reconcileWordSlots` couldn't find a clean
    /// correspondence and the proportional fallback was used instead.
    private(set) var fallbackAyahRefs: Set<PhonemeAyahRef> = []

    /// Per ayah: corpus local word index (as it appears on
    /// `PhonemeGlobalWordEntry.localWordIdx`/`PhonemeWordCheckResult.wordIndex`)
    /// -> flat-word index within that same ayah (matches
    /// `FlatWord.wordIndexInAyah` / `AyahWordMap.slots` index).
    private var perAyah: [PhonemeAyahRef: [Int: Int]] = [:]
    private var ayahIndexByRef: [PhonemeAyahRef: Int] = [:]

    init(corpus: PhonemeCorpus, database: QuranDatabase) {
        for (index, ayah) in database.ayahs.enumerated() {
            ayahIndexByRef[PhonemeAyahRef(surah: ayah.surah, ayah: ayah.ayahNumber)] = index
        }

        // Group the corpus's per-ayah words into "real word" runs, collapsing
        // any `wordTextContinuesPrevious` continuation (a muqatta'at split,
        // e.g. "الٓمٓ" spanning two corpus phoneme-word units) into the
        // group its text actually belongs to - reconciliation must compare
        // real words, not raw corpus phoneme-word units.
        var wordsByAyah: [PhonemeAyahRef: [PhonemeGlobalWordEntry]] = [:]
        for word in corpus.globalWords {
            wordsByAyah[PhonemeAyahRef(surah: word.surah, ayah: word.ayah), default: []].append(word)
        }

        for (ref, words) in wordsByAyah {
            guard let ayahIndex = ayahIndexByRef[ref] else { continue }
            let svgWords = database.flatWords(inAyahIndex: ayahIndex)
            let svgSkeletons = svgWords.map { normalizeArabicSkeleton($0.textUthmani) }

            var groups: [(localIndices: [Int], text: String)] = []
            for word in words.sorted(by: { $0.localWordIdx < $1.localWordIdx }) {
                if word.wordTextContinuesPrevious, !groups.isEmpty {
                    groups[groups.count - 1].localIndices.append(word.localWordIdx)
                    if let text = word.wordText { groups[groups.count - 1].text += text }
                } else {
                    groups.append((localIndices: [word.localWordIdx], text: word.wordText ?? ""))
                }
            }
            let corpusSkeletons = groups.map { normalizeArabicSkeleton($0.text) }

            let resolved: [Int]
            if let mapping = reconcileWordSlots(leftSkeletons: svgSkeletons, rightSkeletons: corpusSkeletons) {
                resolved = mapping
            } else {
                fallbackAyahRefs.insert(ref)
                resolved = proportionalWordSlotMapping(leftCount: svgWords.count, rightCount: corpusSkeletons.count)
            }

            var localIdxToSlot: [Int: Int] = [:]
            for (groupIndex, group) in groups.enumerated() {
                guard resolved.indices.contains(groupIndex) else { continue }
                let slot = resolved[groupIndex]
                for localIdx in group.localIndices {
                    localIdxToSlot[localIdx] = slot
                }
            }
            perAyah[ref] = localIdxToSlot
        }
    }

    /// The `QuranDatabase.flatWords` index a settled phoneme word result
    /// corresponds to, or nil if this ayah/word couldn't be mapped (no
    /// SVG data for it, or an unresolvable corpus local index).
    func flatIndex(for result: PhonemeWordCheckResult, database: QuranDatabase) -> Int? {
        let ref = PhonemeAyahRef(surah: result.surah, ayah: result.ayah)
        guard let ayahIndex = ayahIndexByRef[ref], let slot = perAyah[ref]?[result.wordIndex] else { return nil }
        return database.flatStart(ofAyahIndex: ayahIndex) + slot
    }
}
