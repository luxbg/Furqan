import Foundation
import SQLite3

struct Ayah {
    let id: Int
    let surah: Int
    let ayahNumber: Int
    let textUthmani: String
    /// Per-word ground truth for live per-word correctness checking, from
    /// Tanzil's "Simple Plain" text (`text_imlaei_tashkeel` - plain,
    /// non-mushaf-rasm, letter-by-letter diacritics, no idgham/assimilation
    /// notation). Each entry pre-normalized with `normalizeGroundTruthTashkeel`
    /// at load time.
    let groundTruthWords: [String]
    /// Alternate per-word ground truth, from Tanzil's assimilated "Simple"
    /// variant (`text_imlaei_tashkeel_alt` - e.g. "مِّن رَّبِّهِمْ" instead
    /// of `groundTruthWords`' "مِنْ رَبِّهِمْ"). Found live: the ASR isn't
    /// consistently one convention or the other per word, so a transcribed
    /// word is judged tashkeel-correct if it matches *either* array (see
    /// `RecitationSession`) - same count/positions as `groundTruthWords` by
    /// construction (both files share the same Tanzil tokenization).
    let groundTruthWordsAlt: [String]
    /// Skeleton (harakat-stripped, hamza-folded) form of each entry in
    /// `groundTruthWords` - same count/positions by construction (both
    /// derived from the same Tanzil "Simple Plain" source), used by
    /// `AyahAligner` for candidate identification search.
    let groundTruthSkeletonWords: [String]
    let startPage: Int
    let endPage: Int
}

/// One entry in the whole-Quran flattened word stream (`QuranDatabase.flatWords`),
/// used uniformly by `AyahAligner` for both identification and tracking so
/// tracking can flow across ayah boundaries with no discrete "transition"
/// event.
struct FlatWord {
    let ayahIndex: Int
    let wordIndexInAyah: Int
    let skeleton: String
    let groundTruth: String
    /// See `Ayah.groundTruthWordsAlt`.
    let groundTruthAlt: String
}

/// Loads every ayah from `quran.sqlite` once at launch and holds them in
/// memory, plus a flattened whole-Quran word stream for `AyahAligner`.
nonisolated final class QuranDatabase {
    let ayahs: [Ayah]
    let flatWords: [FlatWord]
    /// Parallel to `ayahs` - the flat index of each ayah's first word, for
    /// mapping an ayah to a position in `flatWords`.
    private let ayahFlatStart: [Int]

    init() {
        var db: OpaquePointer?
        guard let url = Bundle.main.url(forResource: "quran", withExtension: "sqlite"),
              sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            fatalError("could not open quran.sqlite")
        }
        defer { sqlite3_close(db) }

        var loaded: [Ayah] = []
        // ORDER BY id (surah*1000 + ayah_number) guarantees canonical mushaf
        // order, which `flatWords`/`ayahFlatStart` below rely on.
        let sql = """
            SELECT id, surah, ayah_number, text_uthmani, text_imlaei_tashkeel, text_imlaei_tashkeel_alt, start_page, end_page
            FROM ayahs ORDER BY id
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            fatalError("could not prepare ayahs query")
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = Int(sqlite3_column_int(statement, 0))
            let surah = Int(sqlite3_column_int(statement, 1))
            let ayahNumber = Int(sqlite3_column_int(statement, 2))
            let textUthmani = String(cString: sqlite3_column_text(statement, 3))
            let textImlaeiTashkeel = String(cString: sqlite3_column_text(statement, 4))
            let textImlaeiTashkeelAlt = String(cString: sqlite3_column_text(statement, 5))
            let startPage = Int(sqlite3_column_int(statement, 6))
            let endPage = Int(sqlite3_column_int(statement, 7))

            // Real words only - a standalone pause/waqf mark (e.g. "ۖ")
            // appears as its own space-separated token in this data, and
            // must be dropped so groundTruthWords/groundTruthSkeletonWords
            // stay index-aligned with each other and with the ASR's output
            // (which never produces a pause-mark-only token).
            let groundTruthWords = textImlaeiTashkeel.split(separator: " ").map(String.init)
                .filter(isRealArabicWordToken).map(normalizeGroundTruthTashkeel)
            let groundTruthWordsAlt = textImlaeiTashkeelAlt.split(separator: " ").map(String.init)
                .filter(isRealArabicWordToken).map(normalizeGroundTruthTashkeel)
            let groundTruthSkeletonWords = groundTruthWords.map(normalizeArabicSkeleton)

            guard groundTruthWords.count == groundTruthWordsAlt.count else {
                fatalError("tashkeel word-count mismatch at \(surah):\(ayahNumber) - plain/assimilated Tanzil sources drifted")
            }

            loaded.append(Ayah(
                id: id, surah: surah, ayahNumber: ayahNumber,
                textUthmani: textUthmani,
                groundTruthWords: groundTruthWords,
                groundTruthWordsAlt: groundTruthWordsAlt,
                groundTruthSkeletonWords: groundTruthSkeletonWords,
                startPage: startPage, endPage: endPage
            ))
        }
        ayahs = loaded

        var flat: [FlatWord] = []
        var flatStart: [Int] = []
        flat.reserveCapacity(loaded.reduce(0) { $0 + $1.groundTruthWords.count })
        flatStart.reserveCapacity(loaded.count)
        for (ayahIndex, ayah) in loaded.enumerated() {
            flatStart.append(flat.count)
            for wordIndex in 0..<ayah.groundTruthWords.count {
                flat.append(FlatWord(
                    ayahIndex: ayahIndex, wordIndexInAyah: wordIndex,
                    skeleton: ayah.groundTruthSkeletonWords[wordIndex],
                    groundTruth: ayah.groundTruthWords[wordIndex],
                    groundTruthAlt: ayah.groundTruthWordsAlt[wordIndex]
                ))
            }
        }
        flatWords = flat
        ayahFlatStart = flatStart
    }

    /// The flat-word index of the first word of the earliest ayah whose
    /// `startPage` is on or after `pagesBack` pages before `page` (clamped to
    /// the very first word of the Quran) - used to bound the backtrack
    /// tracking window (`AyahAligner`'s local-backtrack tier). `ayahs` is
    /// sorted in canonical mushaf order, and `startPage` is non-decreasing
    /// along that order, so the first ayah meeting the threshold is the
    /// earliest one on or after that page.
    func flatWordIndex(pagesBack: Int, fromPage page: Int) -> Int {
        let targetPage = max(1, page - pagesBack)
        let index = ayahs.firstIndex { $0.startPage >= targetPage } ?? 0
        return ayahFlatStart[index]
    }

    /// The flat-word index of `ayah`'s first word.
    func flatStart(ofAyahIndex ayahIndex: Int) -> Int {
        ayahFlatStart[ayahIndex]
    }
}
