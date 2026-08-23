import Foundation
import SQLite3

struct Ayah {
    let id: Int
    let surah: Int
    let ayahNumber: Int
    let textUthmani: String
    let startPage: Int
    let endPage: Int
}

/// One entry in the whole-Quran flattened word stream (`QuranDatabase.flatWords`).
/// Position in this list is what `RecitationProgressTracker` reveals/
/// highlights against, and what `PhonemeWordMapping` maps the phoneme
/// pipeline's per-word verdicts onto. Built directly from the mushaf SVG's
/// own per-word rows (already one row per real written word, already merged
/// for waw-al-atf) - no reconciliation against a second text source needed
/// to construct this anymore (matching is phoneme-level now, not text-level;
/// see `PhonemeWordMapping` for the one reconciliation this app still needs,
/// between the phoneme corpus's Uthmani words and these).
struct FlatWord {
    let ayahIndex: Int
    let wordIndexInAyah: Int
    /// This word's own Uthmani script, straight from the mushaf SVG data -
    /// display-only (e.g. status-line logging), never used for matching.
    let textUthmani: String
}

/// Loads every ayah from `quran.sqlite` once at launch and holds them in
/// memory, plus a flattened whole-Quran word stream (`flatWords`) that
/// `RecitationProgressTracker`/`PhonemeWordMapping` track position against.
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
            SELECT id, surah, ayah_number, text_uthmani, start_page, end_page
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
            let startPage = Int(sqlite3_column_int(statement, 4))
            let endPage = Int(sqlite3_column_int(statement, 5))

            loaded.append(Ayah(
                id: id, surah: surah, ayahNumber: ayahNumber,
                textUthmani: textUthmani,
                startPage: startPage, endPage: endPage
            ))
        }
        ayahs = loaded

        // Real spoken words only (word_type='word') become slots - this is
        // now directly the canonical real-written-word sequence (no second
        // text source to reconcile against; matching is phoneme-level, see
        // `PhonemeWordMapping` for the one reconciliation this app still
        // needs, between the phoneme corpus's own Uthmani words and these).
        // A waw-al-atf row (is_waw_alatf=1) is its own word_type='word' row
        // in this table, but glues onto the very next word with no space in
        // the mushaf rasm (e.g. "وَإِيَّاكَ" is one real word, two SVG
        // glyphs) - held as `pendingWaw` until the following real word
        // arrives, then both become one slot. Waqf/juz-star/sajda-mehrab
        // marker rows are bucketed onto the nearest preceding real-word slot
        // (or the first slot, if a marker precedes any real word in the
        // ayah - e.g. a leading juz-star).
        struct RawSlot { let ids: [String]; let markers: [String]; let textUthmani: String }
        var rawSlotsByAyahID: [Int: [RawSlot]] = [:]
        let wordsSQL = """
            SELECT surah, ayah_number, word_type, is_waw_alatf, svg_element_id, text_uthmani
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
        var pendingWaw: (ids: [String], textUthmani: String)?

        func flushCurrentAyah() {
            guard let ayahID = currentAyahID else { return }
            if let waw = pendingWaw {
                // A dangling waw-alatf with no following word (shouldn't
                // occur in practice) still gets its own slot rather than
                // being silently dropped.
                currentSlots.append(RawSlot(ids: waw.ids, markers: [], textUthmani: waw.textUthmani))
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
                    textUthmani: currentSlots[last].textUthmani
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
            let textUthmaniWord = String(cString: sqlite3_column_text(wordsStatement, 5))
            let ayahID = surah * 1000 + ayahNumber

            if ayahID != currentAyahID {
                flushCurrentAyah()
                currentAyahID = ayahID
                pendingMarkerIDs = []
                pendingWaw = nil
            }

            if wordType == "word", isWawAlatf {
                pendingWaw = (ids: [svgElementId], textUthmani: textUthmaniWord)
            } else if wordType == "word" {
                // Markers seen before this word (e.g. a leading juz-star)
                // attach to it rather than being dropped; a pending
                // waw-alatf becomes part of this same slot.
                let ids = (pendingWaw?.ids ?? []) + [svgElementId]
                let textUthmaniSlot = (pendingWaw?.textUthmani ?? "") + textUthmaniWord
                currentSlots.append(RawSlot(ids: ids, markers: pendingMarkerIDs, textUthmani: textUthmaniSlot))
                pendingMarkerIDs = []
                pendingWaw = nil
            } else if !currentSlots.isEmpty {
                let last = currentSlots.count - 1
                currentSlots[last] = RawSlot(
                    ids: currentSlots[last].ids,
                    markers: currentSlots[last].markers + [svgElementId],
                    textUthmani: currentSlots[last].textUthmani
                )
            } else {
                pendingMarkerIDs.append(svgElementId)
            }
        }
        flushCurrentAyah()

        // flatWords/wordMaps are now built directly from the SVG's own raw
        // slots, one-to-one, in order - the raw slot list *is* the
        // canonical real-written-word sequence for the ayah.
        var flat: [FlatWord] = []
        var flatStart: [Int] = []
        var builtWordMaps: [AyahWordMap] = []
        let totalWords = rawSlotsByAyahID.values.reduce(0) { $0 + $1.count }
        flat.reserveCapacity(totalWords)
        flatStart.reserveCapacity(loaded.count)
        builtWordMaps.reserveCapacity(loaded.count)
        for (ayahIndex, ayah) in loaded.enumerated() {
            let raw = rawSlotsByAyahID[ayah.id] ?? []
            flatStart.append(flat.count)
            for (wordIndex, slot) in raw.enumerated() {
                flat.append(FlatWord(ayahIndex: ayahIndex, wordIndexInAyah: wordIndex, textUthmani: slot.textUthmani))
            }
            let slots = raw.map { WordSlot(svgElementIds: $0.ids, markerSvgElementIds: $0.markers) }
            builtWordMaps.append(AyahWordMap(page: ayah.startPage, slots: slots))
        }
        flatWords = flat
        ayahFlatStart = flatStart
        wordMaps = builtWordMaps

        var byPage: [Int: [Int]] = [:]
        for (ayahIndex, ayah) in loaded.enumerated() {
            byPage[ayah.startPage, default: []].append(ayahIndex)
        }
        ayahIndicesByPage = byPage
    }

    /// The flat-word index of `ayah`'s first word.
    func flatStart(ofAyahIndex ayahIndex: Int) -> Int {
        ayahFlatStart[ayahIndex]
    }

    /// The slice of `flatWords` belonging to one ayah, in word order.
    func flatWords(inAyahIndex ayahIndex: Int) -> ArraySlice<FlatWord> {
        let start = ayahFlatStart[ayahIndex]
        let count = wordMaps[ayahIndex].slots.count
        return flatWords[start..<(start + count)]
    }
}
