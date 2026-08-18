import Foundation

/// Whether `word` has at least one real (non-diacritic, non-tatweel) letter -
/// as opposed to a standalone pause/waqf mark token (e.g. "ۖ") that appears
/// as its own space-separated token in this app's Quran text sources, with
/// zero base letters once diacritics are stripped.
func isRealArabicWordToken(_ word: String) -> Bool {
    word.unicodeScalars.contains { scalar in
        switch scalar.value {
        case 0x0610...0x061A, 0x064B...0x065F, 0x0670, 0x06D6...0x06ED, 0x0640:
            return false
        default:
            return true
        }
    }
}

/// Harakat-stripped skeleton form, tolerant of ASR mistakes and of
/// representation differences between the ASR's plain-Arabic output and
/// the database's Uthmani-script text (e.g. QUL's alternate sukun/waqf
/// marks). Used to identify *which ayah* is being recited - forgiving by
/// design, since a single wrong diacritic must never block recognizing the
/// ayah itself. Strips all diacritics/tatweel and folds every hamza seat
/// (standalone ء and all four alif/waw/ya-carried forms) to bare alif -
/// they're the same phoneme, and Uthmani/imlaei/ASR output frequently pick
/// different seats for it.
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
            // /h/ or is silent), so the ASR frequently spells it with the
            // plain-ta letter. Same-phoneme treatment as the hamza fold
            // above, not a real word difference.
            result.append(Unicode.Scalar(0x062A)!)
        default:
            result.append(scalar)
        }
    }
    return String(result)
        .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

/// Tashkeel-aware normalization for per-word correctness checking
/// (`AyahAligner`/`RecitationSession`, applied to both `Ayah.groundTruthWords`
/// and the live transcript). Keeps the 8 standard diacritics the ASR's
/// vocabulary can actually produce (U+064B-U+0652:
/// fathatan/dammatan/kasratan/fatha/damma/kasra/shadda/sukun), folds alif
/// variants, strips tatweel and purely-decorative Quran-specific annotation
/// marks the ASR could never produce (waqf/pause signs, idgham/iqlab
/// indicator letters, honorific marks), collapses whitespace, and
/// canonicalizes combining-mark order (NFC) so e.g. a shadda-before-damma vs
/// damma-before-shadda encoding of the same sound (both render as "رُّ")
/// compare equal.
///
/// A dagger alif (U+0670) is *stripped*, never converted to a literal alif
/// letter - correct for Tanzil's "Simple Plain" text (see
/// `scripts/build_database.py`), which is already fully spelled out:
/// scanning every dagger alif in that file found just two shapes, neither of
/// which should add a letter - riding an already-written ى ("عَلَىٰ", 1912
/// occurrences, always immediately after ى) or on one of a small closed set
/// of words that never get a real alif even in full spelling (ذَٰلِكَ,
/// هَٰذَا, الرَّحْمَٰنِ, أُولَٰئِكَ, وَلَٰكِنَّ, هَٰؤُلَاءِ, إِلَٰهَ, ... - 76
/// distinct words, 1418 occurrences total).
func normalizeGroundTruthTashkeel(_ s: String) -> String {
    var result = String.UnicodeScalarView()
    for scalar in s.unicodeScalars {
        switch scalar.value {
        case 0x0640, 0x0670:
            continue
        case 0x0621, 0x0622, 0x0623, 0x0624, 0x0625, 0x0626, 0x0671:
            result.append(Unicode.Scalar(0x0627)!)
        case 0x06E1:
            result.append(Unicode.Scalar(0x0652)!)
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

/// Folds ة (ta marbuta) to ت, for *tashkeel-correctness comparison only*
/// (see `AyahAligner.buildResult`) - never applied to the ground truth
/// string actually displayed/printed, which must keep the Uthmani/imlaei
/// ة spelling. Same phonetic-equivalence rationale as the skeleton-level
/// fold in `normalizeArabicSkeleton`: connected-state ة sounds like /t/,
/// so a reciter saying e.g. "نِعْمَةَ اللَّهِ" correctly is legitimately
/// transcribed by the ASR as "نِعْمَتَ" - a spelling difference, not a
/// wrong diacritic.
func foldTaMarbutaForComparison(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.map { $0.value == 0x0629 ? Unicode.Scalar(0x062A)! : $0 }))
}

