import Foundation

/// One SVG-rendering slot for a single Tanzil ground-truth word position -
/// `AyahWordMap.slots[i]` corresponds to `Ayah.groundTruthWords[i]` (and to
/// `FlatWord` at that position). Usually one glyph; a fused mushaf glyph
/// (e.g. "يٰٓأَيُّهَا" drawn as one connected shape for what Tanzil's plain
/// script spells as two words, "يَا" + "أَيُّهَا") makes several consecutive
/// slots share the same `svgElementIds` - see `reconcileWordSlots`.
struct WordSlot {
    let svgElementIds: [String]
    /// Waqf/juz-star/sajda-mehrab marker ids bucketed with this slot -
    /// revealed together with it, never independently highlighted.
    let markerSvgElementIds: [String]
}

struct AyahWordMap {
    let page: Int
    /// slots.count == ayah.groundTruthWords.count, always.
    let slots: [WordSlot]
}

/// Reconciles SVG word-glyph slots (built from the `words` table, already
/// merged for waw-al-atf) against Tanzil's ground-truth word tokenization
/// for one ayah. The two sources occasionally split words differently - the
/// mushaf rasm sometimes fuses a short prefix (vocative "يَا", demonstrative
/// "هَا", ...) onto the following word as one connected glyph, where Tanzil's
/// plain script spells them as separate words. Returns, for each Tanzil
/// word index, which svg slot index renders it - several consecutive Tanzil
/// indices map to the same svg slot at a fusion point. Returns nil if the
/// two sequences can't be reconciled (bounded concatenation-fusion search,
/// up to 3 consecutive Tanzil words) - callers fall back to
/// `proportionalWordSlotMapping` in that case.
func reconcileWordSlots(svgSkeletons: [String], tanzilSkeletons: [String]) -> [Int]? {
    guard !svgSkeletons.isEmpty, !tanzilSkeletons.isEmpty else { return nil }
    var mapping: [Int] = []
    mapping.reserveCapacity(tanzilSkeletons.count)
    var ti = 0
    for si in 0..<svgSkeletons.count {
        guard ti < tanzilSkeletons.count else { return nil }
        if svgSkeletons[si] == tanzilSkeletons[ti] {
            mapping.append(si)
            ti += 1
            continue
        }
        var fused = tanzilSkeletons[ti]
        var count = 1
        var matched = false
        while ti + count < tanzilSkeletons.count, count < 4 {
            fused += tanzilSkeletons[ti + count]
            count += 1
            if fused == svgSkeletons[si] {
                matched = true
                break
            }
        }
        guard matched else { return nil }
        for _ in 0..<count { mapping.append(si) }
        ti += count
    }
    guard ti == tanzilSkeletons.count else { return nil }
    return mapping
}

/// Fallback when `reconcileWordSlots` can't find a clean correspondence:
/// spreads Tanzil word indices proportionally across the available svg
/// slots, so every Tanzil position still gets *some* reasonable slot rather
/// than the app crashing or a whole ayah going unrenderable. Only used for
/// the rare ayah where the two tokenizations diverge in a way the bounded
/// fusion search doesn't cover - the visible effect is at most a word or
/// two highlighting slightly early/late within that one ayah.
func proportionalWordSlotMapping(svgCount: Int, tanzilCount: Int) -> [Int] {
    guard svgCount > 0 else { return Array(repeating: 0, count: tanzilCount) }
    return (0..<tanzilCount).map { min(svgCount - 1, $0 * svgCount / tanzilCount) }
}
