import Foundation

/// Harakat-stripped skeleton form, tolerant of ASR mistakes and of
/// representation differences between the ASR's plain-Arabic output and
/// the database's Uthmani-script text (e.g. QUL's alternate sukun/waqf
/// marks). Used to identify *which ayah* is being recited - forgiving by
/// design, since a single wrong diacritic must never block recognizing the
/// ayah itself. Strips all diacritics/tatweel and folds alif variants to
/// bare alif.
func normalizeArabicSkeleton(_ s: String) -> String {
    var result = String.UnicodeScalarView()
    for scalar in s.unicodeScalars {
        switch scalar.value {
        case 0x0610...0x061A, 0x064B...0x065F, 0x0670, 0x06D6...0x06ED, 0x0640:
            continue
        case 0x0623, 0x0625, 0x0622, 0x0671:
            result.append(Unicode.Scalar(0x0627)!)
        default:
            result.append(scalar)
        }
    }
    return String(result)
        .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

/// Harakat-*aware* form used only for per-word tashkeel-correctness
/// comparison after an ayah has already been identified (never for
/// matching/candidate search - see `normalizeArabicSkeleton`). Keeps the 8
/// standard diacritics the ASR's vocabulary can actually produce
/// (U+064B-U+0652: fathatan/dammatan/kasratan/fatha/damma/kasra/shadda/
/// sukun), maps the two QUL-only marks that carry real phonetic content to
/// their standard equivalents (U+06E1 small-high-rounded-zero, used as
/// Uthmani's sukun, -> U+0652 standard sukun; U+0670 superscript alef,
/// an elongation the ASR can only spell as a full letter -> U+0627 alef),
/// strips purely-decorative Quran-specific annotation marks the ASR could
/// never produce (waqf/pause signs, idgham/iqlab indicator letters,
/// honorific marks), folds alif variants, strips tatweel, collapses
/// whitespace, and canonicalizes combining-mark order (NFC) so e.g. a
/// shadda-before-damma vs damma-before-shadda encoding of the same sound
/// (both render as "رُّ") compare equal.
func normalizeArabicTashkeel(_ s: String) -> String {
    var result = String.UnicodeScalarView()
    for scalar in s.unicodeScalars {
        switch scalar.value {
        case 0x0640:
            continue
        case 0x0623, 0x0625, 0x0622, 0x0671:
            result.append(Unicode.Scalar(0x0627)!)
        case 0x06E1:
            result.append(Unicode.Scalar(0x0652)!)
        case 0x0670:
            result.append(Unicode.Scalar(0x0627)!)
        case 0x0610...0x061A, 0x0653...0x065F, 0x06D6...0x06ED:
            continue
        default:
            result.append(scalar)
        }
    }
    let collapsed = String(result)
        .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    return collapsed.precomposedStringWithCanonicalMapping
}
