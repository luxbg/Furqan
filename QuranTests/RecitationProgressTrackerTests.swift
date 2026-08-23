import XCTest
@testable import Quran

/// Regression tests for RecitationProgressTracker, built from real
/// quran.sqlite data (via QuranDatabase, loaded once for the whole test
/// class) so cases stay accurate if the underlying text ever changes.
final class RecitationProgressTrackerTests: XCTestCase {
    static let database = QuranDatabase()
    var db: QuranDatabase { Self.database }

    private func ayahIndex(_ surah: Int, _ ayahNumber: Int) -> Int {
        db.ayahs.firstIndex { $0.surah == surah && $0.ayahNumber == ayahNumber }!
    }

    /// Identification alone (before any word is individually matched) sets
    /// the jump target but must not highlight anything within the
    /// identified ayah - there's nothing committed yet to highlight.
    func testIdentificationSetsActivePageWithoutHighlight() {
        let tracker = RecitationProgressTracker()
        let index = ayahIndex(1, 1)
        let flatStart = db.flatStart(ofAyahIndex: index)

        let snapshot = tracker.handleIdentification(flatPosition: flatStart, database: db)

        XCTAssertEqual(snapshot.activePage, db.ayahs[index].startPage)
        XCTAssertTrue(snapshot.highlightedWordIDs.isEmpty)
        XCTAssertEqual(snapshot.highestReachedPage, db.ayahs[index].startPage)
    }

    /// Bug regression: identifying/starting mid-ayah on a multi-ayah page
    /// (1:1 is on the same page as, and precedes, 1:5) must reveal every
    /// earlier ayah on that page wholesale, even though none of it was
    /// individually recited this session.
    func testIdentificationRevealsEverythingBeforeOnTheSamePage() {
        let tracker = RecitationProgressTracker()
        let startIndex = ayahIndex(1, 5)
        XCTAssertEqual(db.ayahs[ayahIndex(1, 1)].startPage, db.ayahs[startIndex].startPage, "test assumes both ayahs share a page")

        let snapshot = tracker.handleIdentification(flatPosition: db.flatStart(ofAyahIndex: startIndex), database: db)

        for slot in db.wordMaps[ayahIndex(1, 1)].slots {
            for id in slot.svgElementIds {
                XCTAssertTrue(snapshot.revealedWordIDsOnActivePage.contains(id), "ayah before the starting ayah should be revealed wholesale")
            }
        }
        for slot in db.wordMaps[startIndex].slots {
            for id in slot.svgElementIds {
                XCTAssertFalse(snapshot.revealedWordIDsOnActivePage.contains(id), "nothing of the starting ayah itself is revealed until matched")
            }
        }
    }

    /// The core "highlight only after settled" requirement: after
    /// committing word 0, only word 0 highlights - word 1 (not yet
    /// committed) must not be the highlight.
    func testHighlightOnlyReflectsMostRecentlyCommittedWord() {
        let tracker = RecitationProgressTracker()
        let index = ayahIndex(1, 1)
        let flatStart = db.flatStart(ofAyahIndex: index)
        let slot0 = db.wordMaps[index].slots[0]
        let slot1 = db.wordMaps[index].slots[1]

        var snapshot = tracker.handleCommits([flatStart], database: db)
        XCTAssertEqual(snapshot.highlightedWordIDs, Set(slot0.svgElementIds))
        XCTAssertEqual(snapshot.revealedWordIDsOnActivePage, Set(slot0.svgElementIds).union(slot0.markerSvgElementIds))

        snapshot = tracker.handleCommits([flatStart + 1], database: db)
        XCTAssertEqual(snapshot.highlightedWordIDs, Set(slot1.svgElementIds), "highlight should move to the newly committed word")
        XCTAssertTrue(Set(slot0.svgElementIds).isSubset(of: snapshot.revealedWordIDsOnActivePage), "word 0 stays revealed")
    }

    /// Position tracking here is correctness-agnostic: a settled word
    /// (whether it matched, mismatched, or was never recited at all) still
    /// advances reveal/highlight - it represents a spot the aligner has
    /// finished judging and moved past, which is what "revealed" tracks
    /// (correctness is a separate concern, surfaced elsewhere).
    func testAnySettledPositionStillReveals() {
        let tracker = RecitationProgressTracker()
        let index = ayahIndex(1, 1)
        let flatStart = db.flatStart(ofAyahIndex: index)
        let slot0 = db.wordMaps[index].slots[0]

        let snapshot = tracker.handleCommits([flatStart], database: db)

        XCTAssertEqual(snapshot.highlightedWordIDs, Set(slot0.svgElementIds))
    }

    /// Committing the FIRST ayah's words on a multi-ayah page reveals it,
    /// but not later, not-yet-reached ayahs on the same page.
    func testCommittingFirstAyahDoesNotRevealLaterAyahsOnSamePage() {
        let tracker = RecitationProgressTracker()
        let firstIndex = ayahIndex(1, 1)
        let secondIndex = ayahIndex(1, 2)

        let firstFlatStart = db.flatStart(ofAyahIndex: firstIndex)
        let flatIndices = Array(firstFlatStart..<(firstFlatStart + db.flatWords(inAyahIndex: firstIndex).count))
        let snapshot = tracker.handleCommits(flatIndices, database: db)

        for slot in db.wordMaps[secondIndex].slots {
            for id in slot.svgElementIds {
                XCTAssertFalse(snapshot.revealedWordIDsOnActivePage.contains(id), "second ayah hasn't been recited yet")
            }
        }
    }

    /// Once recitation moves to a genuinely different page, the page just
    /// finished becomes `highestReachedPage` (everything strictly before it
    /// is fully revealed).
    func testHighestReachedPageAdvancesOnceMovedToADifferentPage() {
        let tracker = RecitationProgressTracker()
        let lastIndex = ayahIndex(1, 7) // last ayah of Al-Fatiha (page 1)
        let nextIndex = ayahIndex(2, 1) // first ayah of Al-Baqarah (a later page)
        XCTAssertNotEqual(db.ayahs[lastIndex].startPage, db.ayahs[nextIndex].startPage, "test assumes a page boundary here")

        let lastFlatStart = db.flatStart(ofAyahIndex: lastIndex)
        var flatIndices = Array(lastFlatStart..<(lastFlatStart + db.flatWords(inAyahIndex: lastIndex).count))
        flatIndices.append(db.flatStart(ofAyahIndex: nextIndex))

        let snapshot = tracker.handleCommits(flatIndices, database: db)

        XCTAssertEqual(snapshot.highestReachedPage, db.ayahs[nextIndex].startPage)
        XCTAssertEqual(snapshot.activePage, db.ayahs[nextIndex].startPage)
        XCTAssertEqual(snapshot.highlightedWordIDs, Set(db.wordMaps[nextIndex].slots[0].svgElementIds))
    }

    /// Sticky/monotonic: once the reached-page range extends past a page, a
    /// later backtrack to an earlier page must not shrink it back down.
    func testBacktrackDoesNotShrinkReachedPageRange() {
        let tracker = RecitationProgressTracker()
        let lastIndex = ayahIndex(1, 7)
        let nextIndex = ayahIndex(2, 1)
        let lastFlatStart = db.flatStart(ofAyahIndex: lastIndex)
        var flatIndices = Array(lastFlatStart..<(lastFlatStart + db.flatWords(inAyahIndex: lastIndex).count))
        flatIndices.append(db.flatStart(ofAyahIndex: nextIndex))
        _ = tracker.handleCommits(flatIndices, database: db)
        let highestBefore = tracker.highestReachedPage

        // Reciter repeats 1:1 (earlier than what's already been passed).
        let repeatedIndex = ayahIndex(1, 1)
        let snapshot = tracker.handleCommits([db.flatStart(ofAyahIndex: repeatedIndex)], database: db)

        XCTAssertEqual(tracker.highestReachedPage, highestBefore, "highest reached page must not shrink")
        XCTAssertEqual(snapshot.activePage, db.ayahs[repeatedIndex].startPage)
    }

    /// Bug regression: backtracking to repeat an ayah on a page that's
    /// already fully passed (within the reached-page range) must still
    /// highlight the backtrack word - the active page always gets masked
    /// treatment with a real highlight, never a blanket "whole page
    /// visible, nothing highlighted" state.
    func testBacktrackIntoAlreadyPassedPageStillHighlights() {
        let tracker = RecitationProgressTracker()
        let lastIndex = ayahIndex(1, 7)
        let nextIndex = ayahIndex(2, 1)
        let lastFlatStart = db.flatStart(ofAyahIndex: lastIndex)
        var flatIndices = Array(lastFlatStart..<(lastFlatStart + db.flatWords(inAyahIndex: lastIndex).count))
        flatIndices.append(db.flatStart(ofAyahIndex: nextIndex))
        _ = tracker.handleCommits(flatIndices, database: db)

        let repeatedIndex = ayahIndex(1, 3)
        let snapshot = tracker.handleCommits([db.flatStart(ofAyahIndex: repeatedIndex)], database: db)

        XCTAssertEqual(snapshot.activePage, db.ayahs[repeatedIndex].startPage)
        XCTAssertEqual(snapshot.highlightedWordIDs, Set(db.wordMaps[repeatedIndex].slots[0].svgElementIds))
        XCTAssertFalse(snapshot.highlightedWordIDs.isEmpty)
    }

    func testResetClearsAllState() {
        let tracker = RecitationProgressTracker()
        let index = ayahIndex(1, 1)
        _ = tracker.handleCommits([db.flatStart(ofAyahIndex: index)], database: db)

        tracker.reset()
        XCTAssertNil(tracker.highestReachedPage)
    }
}
