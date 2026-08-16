import XCTest
@testable import Quran

/// Regression tests for AyahMatcher.attemptAyahMatch, built directly from
/// real quran.sqlite data (via QuranDatabase, loaded once for the whole
/// test class) so cases stay accurate if the underlying text ever changes.
final class AyahMatcherTests: XCTestCase {
    static let database = QuranDatabase()
    var db: QuranDatabase { Self.database }

    private func ayah(_ surah: Int, _ ayahNumber: Int) -> Ayah {
        db.ayahs.first { $0.surah == surah && $0.ayahNumber == ayahNumber }!
    }

    /// Normal case: a fresh mid-ayah start (only part of the ayah captured
    /// so far) still resolves, and the cursor is advanced past the whole
    /// ayah's word count so the next tick starts fresh.
    func testMidAyahStartResolves() {
        let target = ayah(2, 255) // Ayat al-Kursi - long, distinctive
        let tail = Array(target.tashkeelWords.suffix(4)) // last 4 words only
        let attempt = attemptAyahMatch(words: tail, cursor: 0, database: db, currentPages: target.startPage...target.endPage)
        XCTAssertEqual(attempt.ayah?.surah, 2)
        XCTAssertEqual(attempt.ayah?.ayahNumber, 255)
        XCTAssertEqual(attempt.newCursor, target.tashkeelWords.count)
    }

    /// Cross-ayah-boundary start (Fix 1): the very first captured words
    /// straddle an ayah boundary - last 2 words of one ayah, first 2 of the
    /// next - before anything has resolved. Must resolve to the earlier
    /// ayah via the pair fallback, not stall forever.
    func testCrossAyahBoundaryStartResolves() {
        let first = ayah(2, 2)
        let second = ayah(2, 3)
        let words = Array(first.tashkeelWords.suffix(2)) + Array(second.tashkeelWords.prefix(2))
        // Off-page on purpose, to exercise the global-uniqueness branch of
        // the pair fallback rather than the on-page-priority branch.
        let attempt = attemptAyahMatch(words: words, cursor: 0, database: db, currentPages: 1...1)
        XCTAssertEqual(attempt.ayah?.surah, 2)
        XCTAssertEqual(attempt.ayah?.ayahNumber, 2)
        XCTAssertEqual(attempt.newCursor, first.tashkeelWords.count)
    }

    /// Muqatta'at glomming (Fix 2): the ASR glues the disconnected-letter
    /// opening onto the very next word with no space ("المذلك..."),
    /// which matches neither ayah's real skeleton under normal (space-
    /// aware) matching. Must resolve straight to the following ayah.
    func testMuqattaatGluedOpeningResolves() {
        let opening = ayah(2, 1) // "الم"
        let next = ayah(2, 2)
        // Built from skeleton (not tashkeel) words on purpose: 2:2 opens with
        // "ذَٰلِكَ", whose Uthmani dagger-alef normalizeArabicTashkeel expands
        // into a real alif letter - a separate, pre-existing Tier-1
        // representation gap (Uthmani-tashkeel vs. Imlaei-skeleton) unrelated
        // to the muqatta'at fallback this test targets. Skeleton words keep
        // the two sides consistent so this test isolates Fix 2 itself.
        let nextSkeletonWords = next.skeletonText.split(separator: " ").map(String.init)
        var words: [String] = []
        words.append(opening.skeletonText + nextSkeletonWords[0]) // glued, no space
        words.append(contentsOf: nextSkeletonWords.dropFirst())
        // Off-page on purpose, to exercise the global-uniqueness branch.
        let attempt = attemptAyahMatch(words: words, cursor: 0, database: db, currentPages: 500...500)
        XCTAssertEqual(attempt.ayah?.surah, 2)
        XCTAssertEqual(attempt.ayah?.ayahNumber, 2)
        XCTAssertEqual(attempt.newCursor, next.tashkeelWords.count)
    }

    /// Single-word-on-page resolution (Fix 3): a distinctive word, with the
    /// matching ayah's own page already open, resolves immediately - no
    /// need to wait for 3 words.
    func testSingleWordResolvesWhenPageAlreadyOpen() {
        let target = ayah(112, 4) // "وَلَمْ يَكُن لَّهُ كُفُوًا أَحَدٌ" - "kufuwan" is rare/distinctive
        let word = target.tashkeelWords[3] // "كُفُوًا"
        let attempt = attemptAyahMatch(words: [word], cursor: 0, database: db, currentPages: target.startPage...target.endPage)
        XCTAssertEqual(attempt.ayah?.surah, 112)
        XCTAssertEqual(attempt.ayah?.ayahNumber, 4)
    }

    /// The same single word, with a *different* page open, must NOT
    /// resolve early - only the on-page-open shortcut bypasses the 3-word
    /// minimum.
    func testSingleWordDoesNotResolveWhenOffPage() {
        let target = ayah(112, 4)
        let word = target.tashkeelWords[3]
        let attempt = attemptAyahMatch(words: [word], cursor: 0, database: db, currentPages: 1...1)
        XCTAssertNil(attempt.ayah)
        XCTAssertEqual(attempt.newCursor, 0)
    }

    /// A single word that's ambiguous even within the open page (matches
    /// 2+ on-page candidates) must not resolve early - falls through to
    /// the normal >=3-word flow unchanged.
    func testAmbiguousSingleWordOnPageDoesNotResolveEarly() {
        // Find a real page where a single (skeleton-normalized) word
        // matches 2+ on-page ayahs, so this test tracks real data instead
        // of an assumption that could silently stop holding.
        var found: (page: Int, word: String)?
        outer: for page in 1...604 {
            let onPage = db.ayahs.filter { $0.startPage <= page && $0.endPage >= page }
            guard onPage.count >= 2 else { continue }
            for candidate in onPage {
                guard let word = candidate.tashkeelWords.first else { continue }
                let skeleton = normalizeArabicSkeleton(word)
                let matchCount = onPage.filter { $0.skeletonText.contains(skeleton) }.count
                if matchCount >= 2 {
                    found = (page, word)
                    break outer
                }
            }
        }
        guard let found else {
            XCTFail("no page with an ambiguous single-word case found - data may have changed")
            return
        }
        let skeleton = normalizeArabicSkeleton(found.word)
        let recomputed = db.ayahs.filter { $0.startPage <= found.page && $0.endPage >= found.page && $0.skeletonText.contains(skeleton) }
        let attempt = attemptAyahMatch(words: [found.word], cursor: 0, database: db, currentPages: found.page...found.page)
        XCTAssertNil(attempt.ayah, "expected no early resolution for an ambiguous on-page word \"\(found.word)\" (skeleton \"\(skeleton)\") on page \(found.page); recomputed matches: \(recomputed.map { "\($0.surah):\($0.ayahNumber)" })")
    }
}
