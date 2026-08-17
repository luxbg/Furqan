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

    /// Per-ayah SVG word-slot mapping, for the live word-highlighting UI -
    /// parallel to `ayahs`/`flatWords` (`wordMaps[ayahIndex].slots[i]`
    /// corresponds to `flatWords[flatStart(ofAyahIndex: ayahIndex) + i]`).
    let wordMaps: [AyahWordMap]
    /// Ayah indices where `reconcileWordSlots` couldn't find a clean
    /// correspondence and `proportionalWordSlotMapping` was used instead -
    /// exposed for a regression test asserting this stays a small, bounded
    /// set rather than silently growing as the data changes.
    let wordSlotFallbackAyahIndices: Set<Int>
    /// Ayah indices grouped by `startPage`, in ascending order within each
    /// page - lets `RecitationProgressTracker` reveal "every ayah on this
    /// page up to the current one" without scanning all of `ayahs`.
    let ayahIndicesByPage: [Int: [Int]]

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

        // Real spoken words only (word_type='word') become slots. A
        // waw-al-atf row (is_waw_alatf=1) is its own word_type='word' row in
        // this table, but glues onto the very next word with no space in
        // both text_uthmani and Tanzil's plain script (e.g. "وَإِيَّاكَ" is
        // one Tanzil word, two SVG glyphs) - held as `pendingWawSvgIds`
        // until the following real word arrives, then both become one raw
        // slot. Waqf/juz-star/sajda-mehrab marker rows are bucketed onto the
        // nearest preceding real-word slot (or the first slot, if a marker
        // precedes any real word in the ayah - e.g. a leading juz-star).
        //
        // Each raw slot is still SVG-indexed at this point, not yet aligned
        // to Tanzil's tokenization (see `reconcileWordSlots` below, which
        // handles the small remaining set of words the mushaf rasm fuses
        // that Tanzil's plain script spells separately, e.g. a vocative "يا"
        // prefix).
        struct RawSlot { let ids: [String]; let markers: [String]; let imlaei: String }
        var rawSlotsByAyahID: [Int: [RawSlot]] = [:]
        let wordsSQL = """
            SELECT surah, ayah_number, word_type, is_waw_alatf, svg_element_id, text_imlaei
            FROM words ORDER BY surah, ayah_number, word_index
            """
        var wordsStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, wordsSQL, -1, &wordsStatement, nil) == SQLITE_OK else {
            fatalError("could not prepare words query")
        }
        defer { sqlite3_finalize(wordsStatement) }

        var currentAyahID: Int?
        var currentSlots: [RawSlot] = []
        var pendingMarkerIDs: [String] = []
        var pendingWaw: (ids: [String], imlaei: String)?

        func flushCurrentAyah() {
            guard let ayahID = currentAyahID else { return }
            if let waw = pendingWaw {
                // A dangling waw-alatf with no following word (shouldn't
                // occur in practice) still gets its own slot rather than
                // being silently dropped.
                currentSlots.append(RawSlot(ids: waw.ids, markers: [], imlaei: waw.imlaei))
                pendingWaw = nil
            }
            // Any markers still pending (an ayah with no real words at all,
            // which doesn't occur in practice, or trailing markers after
            // the last real word) attach to the final slot if one exists.
            if !pendingMarkerIDs.isEmpty, !currentSlots.isEmpty {
                let last = currentSlots.count - 1
                currentSlots[last] = RawSlot(
                    ids: currentSlots[last].ids,
                    markers: currentSlots[last].markers + pendingMarkerIDs,
                    imlaei: currentSlots[last].imlaei
                )
                pendingMarkerIDs = []
            }
            rawSlotsByAyahID[ayahID] = currentSlots
            currentSlots = []
        }

        while sqlite3_step(wordsStatement) == SQLITE_ROW {
            let surah = Int(sqlite3_column_int(wordsStatement, 0))
            let ayahNumber = Int(sqlite3_column_int(wordsStatement, 1))
            let wordType = String(cString: sqlite3_column_text(wordsStatement, 2))
            let isWawAlatf = sqlite3_column_int(wordsStatement, 3) != 0
            let svgElementId = String(cString: sqlite3_column_text(wordsStatement, 4))
            let textImlaei = String(cString: sqlite3_column_text(wordsStatement, 5))
            let ayahID = surah * 1000 + ayahNumber

            if ayahID != currentAyahID {
                flushCurrentAyah()
                currentAyahID = ayahID
                pendingMarkerIDs = []
                pendingWaw = nil
            }

            if wordType == "word", isWawAlatf {
                pendingWaw = (ids: [svgElementId], imlaei: textImlaei)
            } else if wordType == "word" {
                // Markers seen before this word (e.g. a leading juz-star)
                // attach to it rather than being dropped; a pending
                // waw-alatf becomes part of this same slot.
                let ids = (pendingWaw?.ids ?? []) + [svgElementId]
                let imlaei = (pendingWaw?.imlaei ?? "") + textImlaei
                currentSlots.append(RawSlot(ids: ids, markers: pendingMarkerIDs, imlaei: imlaei))
                pendingMarkerIDs = []
                pendingWaw = nil
            } else if !currentSlots.isEmpty {
                let last = currentSlots.count - 1
                currentSlots[last] = RawSlot(
                    ids: currentSlots[last].ids,
                    markers: currentSlots[last].markers + [svgElementId],
                    imlaei: currentSlots[last].imlaei
                )
            } else {
                pendingMarkerIDs.append(svgElementId)
            }
        }
        flushCurrentAyah()

        // Reconcile each ayah's SVG-indexed raw slots against its Tanzil
        // ground-truth word count, producing slots indexed the same way as
        // `flatWords`/`ayah.groundTruthWords` - see `reconcileWordSlots`.
        var builtWordMaps: [AyahWordMap] = []
        builtWordMaps.reserveCapacity(loaded.count)
        var fallbackIndices: Set<Int> = []
        for (ayahIndex, ayah) in loaded.enumerated() {
            let raw = rawSlotsByAyahID[ayah.id] ?? []
            let svgSkeletons = raw.map { normalizeArabicSkeleton($0.imlaei) }
            let tanzilSkeletons = ayah.groundTruthSkeletonWords
            let mapping = reconcileWordSlots(svgSkeletons: svgSkeletons, tanzilSkeletons: tanzilSkeletons)
            let resolvedMapping: [Int]
            if let mapping {
                resolvedMapping = mapping
            } else {
                fallbackIndices.insert(ayahIndex)
                resolvedMapping = proportionalWordSlotMapping(svgCount: raw.count, tanzilCount: tanzilSkeletons.count)
            }
            let slots = resolvedMapping.map { svgIndex -> WordSlot in
                guard raw.indices.contains(svgIndex) else { return WordSlot(svgElementIds: [], markerSvgElementIds: []) }
                return WordSlot(svgElementIds: raw[svgIndex].ids, markerSvgElementIds: raw[svgIndex].markers)
            }
            builtWordMaps.append(AyahWordMap(page: ayah.startPage, slots: slots))
        }
        wordMaps = builtWordMaps
        wordSlotFallbackAyahIndices = fallbackIndices

        var byPage: [Int: [Int]] = [:]
        for (ayahIndex, ayah) in loaded.enumerated() {
            byPage[ayah.startPage, default: []].append(ayahIndex)
        }
        ayahIndicesByPage = byPage
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
