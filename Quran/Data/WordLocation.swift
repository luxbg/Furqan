import Foundation

/// One SVG-rendering slot for a single real written word -
/// `AyahWordMap.slots[i]` corresponds to `FlatWord` at that position.
/// Usually one glyph; a fused mushaf glyph can make several consecutive
/// slots share the same `svgElementIds` where `reconcileWordSlots` is used
/// to align a second, independently-segmented word source onto these slots
/// (see `PhonemeWordMapping`).
struct WordSlot {
    let svgElementIds: [String]
    /// Waqf/juz-star/sajda-mehrab marker ids bucketed with this slot -
    /// revealed together with it, never independently highlighted.
    let markerSvgElementIds: [String]
}

struct AyahWordMap {
    let page: Int
    let slots: [WordSlot]
}

/// Reconciles one sequence of word skeletons (`leftSkeletons`, e.g. the
/// mushaf SVG's own per-word text) against a second, independently-
/// segmented sequence for the same ayah (`rightSkeletons`, e.g. another
/// source's own word tokenization). The two sources occasionally split
/// words differently - one side sometimes fuses a short prefix onto the
/// following word as one glyph/unit where the other spells them as separate
/// words. Returns, for each `rightSkeletons` index, which `leftSkeletons`
/// index it corresponds to - several consecutive right-hand indices map to
/// the same left-hand index at a fusion point. Returns nil if the two
/// sequences can't be reconciled (bounded concatenation-fusion search, up
/// to 3 consecutive right-hand words) - callers fall back to
/// `proportionalWordSlotMapping` in that case.
func reconcileWordSlots(leftSkeletons: [String], rightSkeletons: [String]) -> [Int]? {
    guard !leftSkeletons.isEmpty, !rightSkeletons.isEmpty else { return nil }
    var mapping: [Int] = []
    mapping.reserveCapacity(rightSkeletons.count)
    var ti = 0
    for si in 0..<leftSkeletons.count {
        guard ti < rightSkeletons.count else { return nil }
        if leftSkeletons[si] == rightSkeletons[ti] {
            mapping.append(si)
            ti += 1
            continue
        }
        var fused = rightSkeletons[ti]
        var count = 1
        var matched = false
        while ti + count < rightSkeletons.count, count < 4 {
            fused += rightSkeletons[ti + count]
            count += 1
            if fused == leftSkeletons[si] {
                matched = true
                break
            }
        }
        guard matched else { return nil }
        for _ in 0..<count { mapping.append(si) }
        ti += count
    }
    guard ti == rightSkeletons.count else { return nil }
    return mapping
}

/// Fallback when `reconcileWordSlots` can't find a clean correspondence:
/// spreads the right-hand word indices proportionally across the available
/// left-hand slots, so every right-hand position still gets *some*
/// reasonable slot rather than the app crashing or a whole ayah going
/// unrenderable. Only used for the rare ayah where the two tokenizations
/// diverge in a way the bounded fusion search doesn't cover - the visible
/// effect is at most a word or two highlighting slightly early/late within
/// that one ayah.
func proportionalWordSlotMapping(leftCount: Int, rightCount: Int) -> [Int] {
    guard leftCount > 0 else { return Array(repeating: 0, count: rightCount) }
    return (0..<rightCount).map { min(leftCount - 1, $0 * leftCount / rightCount) }
}
