import Foundation

/// Harakat-stripped skeleton form, tolerant of representation differences
/// between two Arabic-script sources that spell the same word slightly
/// differently (e.g. sukun glyph choice, hamza seat, madd-sign spelling).
/// Used to reconcile the mushaf SVG's own per-word Uthmani text against the
/// phoneme corpus's independently-segmented Uthmani text
/// (`PhonemeWordMapping`, via `reconcileWordSlots`/
/// `proportionalWordSlotMapping` in `WordLocation.swift`) - forgiving by
/// design, since the two sources agreeing on the *word* is what matters
/// here, not agreeing on which sukun glyph or diacritic-order convention was
/// used. Strips all diacritics/tatweel and folds every hamza seat
/// (standalone ء and all four alif/waw/ya-carried forms) to bare alif -
/// they're the same phoneme, and the two sources frequently pick different
/// seats for it.
func normalizeArabicSkeleton(_ s: String) -> String {
    var result = String.UnicodeScalarView()
    for scalar in s.unicodeScalars {
        switch scalar.value {
        case 0x0610...0x061A, 0x064B...0x065F, 0x0670, 0x06D6...0x06ED, 0x0640:
            continue
        case 0x0621, 0x0622, 0x0623, 0x0624, 0x0625, 0x0626, 0x0671:
            result.append(Unicode.Scalar(0x0627)!)
        case 0x0629:
            // Ta marbuta folded to ta - connected-state ة is pronounced
            // /t/, identical to ت (only a paused/isolated ة sounds like
            // /h/ or is silent), so the two sources frequently pick
            // different spellings for it. Same-phoneme treatment as the
            // hamza fold above, not a real word difference.
            result.append(Unicode.Scalar(0x062A)!)
        default:
            result.append(scalar)
        }
    }
    return String(result)
        .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}
