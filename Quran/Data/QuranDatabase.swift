import Foundation
import SQLite3

struct Ayah {
    let id: Int
    let surah: Int
    let ayahNumber: Int
    let textUthmani: String
    /// Harakat-stripped skeleton, for candidate matching (§7).
    let skeletonText: String
    /// Tashkeel-normalized per-word text_uthmani, for per-word correctness
    /// comparison once an ayah has already been identified.
    let tashkeelWords: [String]
    let startPage: Int
    let endPage: Int
}

/// Two consecutive ayahs (in canonical mushaf order, surah boundaries
/// included), so a tail that straddles an ayah boundary before anything has
/// resolved yet can still be found - see AyahMatcher's cross-ayah-boundary
/// fallback. `first` is the ayah the reciter is completing; `second` is the
/// one they've already started on.
struct AyahPair {
    let first: Ayah
    let second: Ayah
    let joinedSkeleton: String
}

/// A surah-opening muqatta'at token (disconnected letters, e.g. "الم") paired
/// with just the single word immediately following it, matched space-
/// insensitively. There is no real speech pause after a muqatta'at token, so
/// the ASR can glue it onto whatever comes next (e.g. "المذلك") in a way
/// that matches neither ayah's real skeleton text under normal (space-
/// aware) matching. Deliberately kept to *one* following word (not the rest
/// of the ayah/next ayah) to keep the comparison string short - some
/// muqatta'at ayahs (e.g. 14:1 "الر ۚ كتاب...") carry substantial text of
/// their own after the letters, and matching against that whole text would
/// risk incidental false-positive substring collisions with unrelated
/// common words elsewhere in a session's transcript.
struct MuqattaatEntry {
    /// The ayah to resolve to on a match: the opening ayah itself when the
    /// following word is more of that same (composite) ayah, or the next
    /// ayah when the opening is pure disconnected letters on their own.
    let resolvesTo: Ayah
    let strippedJoined: String
}

/// Surah, ayah-number pairs for the known disconnected-letter openings.
/// Ash-Shura (42) splits its muqatta'at across two ayahs (حم at 42:1, عسق
/// at 42:2) - both included since either could get glued to what follows.
private let muqattaatAyahs: [(surah: Int, ayah: Int)] = [
    (2, 1), (3, 1), (7, 1), (10, 1), (11, 1), (12, 1), (13, 1), (14, 1), (15, 1),
    (19, 1), (20, 1), (26, 1), (27, 1), (28, 1), (29, 1), (30, 1), (31, 1), (32, 1),
    (36, 1), (38, 1), (40, 1), (41, 1), (42, 1), (42, 2), (43, 1), (44, 1), (45, 1),
    (46, 1), (50, 1), (68, 1),
]

/// Loads every ayah from `quran.sqlite` once at launch and holds them in
/// memory so live-transcription matching (§7 of the transcription plan) can
/// linearly scan for substring candidates without touching disk per tick.
nonisolated final class QuranDatabase {
    let ayahs: [Ayah]
    /// Every canonically-adjacent ayah pair (surah boundaries included), for
    /// the cross-ayah-boundary matching fallback.
    let ayahPairs: [AyahPair]
    let muqattaatEntries: [MuqattaatEntry]

    init() {
        var db: OpaquePointer?
        guard let url = Bundle.main.url(forResource: "quran", withExtension: "sqlite"),
              sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            fatalError("could not open quran.sqlite")
        }
        defer { sqlite3_close(db) }

        var loaded: [Ayah] = []
        // ORDER BY id (surah*1000 + ayah_number) guarantees canonical mushaf
        // order, which `ayahPairs`/`muqattaatEntries` below rely on.
        let sql = "SELECT id, surah, ayah_number, text_uthmani, text_imlaei, start_page, end_page FROM ayahs ORDER BY id"
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
            let textImlaei = String(cString: sqlite3_column_text(statement, 4))
            let startPage = Int(sqlite3_column_int(statement, 5))
            let endPage = Int(sqlite3_column_int(statement, 6))
            loaded.append(Ayah(
                id: id, surah: surah, ayahNumber: ayahNumber,
                textUthmani: textUthmani,
                skeletonText: normalizeArabicSkeleton(textImlaei),
                tashkeelWords: normalizeArabicTashkeel(textUthmani).split(separator: " ").map(String.init),
                startPage: startPage, endPage: endPage
            ))
        }
        ayahs = loaded

        var pairs: [AyahPair] = []
        pairs.reserveCapacity(max(0, loaded.count - 1))
        for i in 0..<max(0, loaded.count - 1) {
            let first = loaded[i]
            let second = loaded[i + 1]
            pairs.append(AyahPair(first: first, second: second, joinedSkeleton: first.skeletonText + " " + second.skeletonText))
        }
        ayahPairs = pairs

        let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        muqattaatEntries = muqattaatAyahs.compactMap { entry -> MuqattaatEntry? in
            let id = entry.surah * 1000 + entry.ayah
            guard let opening = byID[id] else { return nil }
            let openingWords = opening.skeletonText.split(separator: " ").map(String.init)
            guard let letters = openingWords.first else { return nil }
            let resolvesTo: Ayah
            let followingWord: String
            if openingWords.count > 1 {
                // Composite (e.g. 14:1 "الر ۚ كتاب...") - the letters and
                // the rest of the text are already in the same ayah.
                resolvesTo = opening
                followingWord = openingWords[1]
            } else {
                // Pure disconnected letters alone (e.g. 2:1 "الم") - glue to
                // the very next ayah's first word instead.
                guard let next = byID[id + 1], let nextFirst = next.skeletonText.split(separator: " ").first else { return nil }
                resolvesTo = next
                followingWord = String(nextFirst)
            }
            return MuqattaatEntry(resolvesTo: resolvesTo, strippedJoined: letters + followingWord)
        }
    }

    func candidates(forSkeletonSubstring skeleton: String) -> [Ayah] {
        ayahs.filter { $0.skeletonText.contains(skeleton) }
    }

    func pairCandidates(forSkeletonSubstring skeleton: String) -> [AyahPair] {
        ayahPairs.filter { $0.joinedSkeleton.contains(skeleton) }
    }

    /// `strippedJoined` is a short, fixed 2-word signature (see
    /// `MuqattaatEntry`); `stripped` is the caller's whole (possibly longer,
    /// still-growing) tail, so containment runs the opposite direction from
    /// `candidates(forSkeletonSubstring:)` - here we're searching for the
    /// short signature somewhere inside the longer tail, not the reverse.
    func muqattaatCandidates(forStrippedSubstring stripped: String) -> [MuqattaatEntry] {
        muqattaatEntries.filter { stripped.contains($0.strippedJoined) }
    }
}
