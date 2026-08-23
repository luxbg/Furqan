import Foundation

/// Port of `qrc/corpus/models.py`.
struct PhonemeAyahRef: Hashable {
    let surah: Int
    let ayah: Int
}

struct PhonemeAyahEntry {
    let ref: PhonemeAyahRef
    let ayaText: String
    let ayaPhoneme: String
    /// The corpus's own phoneme-word segmentation for this ayah (training-
    /// label units - may merge/split real written words, see
    /// `PhonemeCorpus`).
    let words: [String]
}

/// One real written word in the whole-Quran phoneme corpus, after exploding
/// each corpus phoneme-word unit into its real per-word spans via
/// `word_text_map.json` (see `PhonemeCorpus.build`).
struct PhonemeGlobalWordEntry {
    let globalWordIdx: Int
    let surah: Int
    let ayah: Int
    let localWordIdx: Int
    let phonemeText: String
    /// Real Uthmani script word, from `word_text_map.json` - `nil` if that
    /// precompute couldn't confidently map this specific word.
    let wordText: String?
    /// This word's own phoneme rendering when phonetized standalone (as if
    /// paused/waqf right after it) - differs from `phonemeText` wherever
    /// cross-word tajweed liaison or a pause-dropped tanween/short-vowel
    /// affects the connected-recitation form.
    let isolatedPhonemeText: String?
    /// Only ever set for an ayah's true *last* written word: its phoneme
    /// rendering if recitation continues straight into the next ayah
    /// rather than pausing there.
    let continuedPhonemeText: String?
    /// True when this corpus phoneme-word is part of the *same* real
    /// written word as the immediately preceding entry (a muqatta'at
    /// split, e.g. "الٓمٓ" spans two phoneme-word units).
    let wordTextContinuesPrevious: Bool
}
