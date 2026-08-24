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

    private func commits(_ flatIndices: [Int], status: PhonemeWordStatus = .match) -> [RecitationCommit] {
        flatIndices.map { RecitationCommit(flatIndex: $0, status: status) }
    }

    private func wrongIDs(_ snapshot: RecitationProgressSnapshot, page: Int) -> Set<String> {
        snapshot.wrongWordIDsByPage[page] ?? []
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

        var snapshot = tracker.handleCommits(commits([flatStart]), database: db)
        XCTAssertEqual(snapshot.highlightedWordIDs, Set(slot0.svgElementIds))
        XCTAssertEqual(snapshot.revealedWordIDsOnActivePage, Set(slot0.svgElementIds).union(slot0.markerSvgElementIds))

        snapshot = tracker.handleCommits(commits([flatStart + 1]), database: db)
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

        let snapshot = tracker.handleCommits(commits([flatStart]), database: db)

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
        let snapshot = tracker.handleCommits(commits(flatIndices), database: db)

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

        let snapshot = tracker.handleCommits(commits(flatIndices), database: db)

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
        _ = tracker.handleCommits(commits(flatIndices), database: db)
        let highestBefore = tracker.highestReachedPage

        // Reciter repeats 1:1 (earlier than what's already been passed).
        let repeatedIndex = ayahIndex(1, 1)
        let snapshot = tracker.handleCommits(commits([db.flatStart(ofAyahIndex: repeatedIndex)]), database: db)

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
        _ = tracker.handleCommits(commits(flatIndices), database: db)

        let repeatedIndex = ayahIndex(1, 3)
        let snapshot = tracker.handleCommits(commits([db.flatStart(ofAyahIndex: repeatedIndex)]), database: db)

        XCTAssertEqual(snapshot.activePage, db.ayahs[repeatedIndex].startPage)
        XCTAssertEqual(snapshot.highlightedWordIDs, Set(db.wordMaps[repeatedIndex].slots[0].svgElementIds))
        XCTAssertFalse(snapshot.highlightedWordIDs.isEmpty)
    }

    func testResetClearsAllState() {
        let tracker = RecitationProgressTracker()
        let index = ayahIndex(1, 1)
        _ = tracker.handleCommits(commits([db.flatStart(ofAyahIndex: index)]), database: db)

        tracker.reset()
        XCTAssertNil(tracker.highestReachedPage)
    }

    // MARK: - wrongWordIDs (persistent red)

    func testMismatchAddsToWrongWordIDs() {
        let tracker = RecitationProgressTracker()
        let index = ayahIndex(1, 1)
        let flatStart = db.flatStart(ofAyahIndex: index)
        let slot0 = db.wordMaps[index].slots[0]

        let snapshot = tracker.handleCommits([RecitationCommit(flatIndex: flatStart, status: .mismatch)], database: db)

        XCTAssertEqual(wrongIDs(snapshot, page: db.ayahs[index].startPage), Set(slot0.svgElementIds))
    }

    /// Confirmed with the user: a word marked wrong stays red for the rest
    /// of the session even if the reciter later backtracks and says it
    /// correctly - a permanent mistake record, not a "currently wrong" flag.
    func testWrongWordIDsPersistAfterLaterCorrectRecitation() {
        let tracker = RecitationProgressTracker()
        let index = ayahIndex(1, 1)
        let flatStart = db.flatStart(ofAyahIndex: index)
        let slot0 = db.wordMaps[index].slots[0]

        _ = tracker.handleCommits([RecitationCommit(flatIndex: flatStart, status: .mismatch)], database: db)
        let snapshot = tracker.handleCommits([RecitationCommit(flatIndex: flatStart, status: .match)], database: db)

        XCTAssertEqual(wrongIDs(snapshot, page: db.ayahs[index].startPage), Set(slot0.svgElementIds), "must not clear just because the same word later matched")
    }

    func testResetClearsWrongWordIDs() {
        let tracker = RecitationProgressTracker()
        let index = ayahIndex(1, 1)
        let flatStart = db.flatStart(ofAyahIndex: index)
        _ = tracker.handleCommits([RecitationCommit(flatIndex: flatStart, status: .mismatch)], database: db)

        tracker.reset()

        XCTAssertTrue(tracker.wrongWordIDsByPage.isEmpty)
    }

    /// Regression: `WordSlot.svgElementIds` are only unique *within* one
    /// page's own SVG (every mushaf page's own ids restart at
    /// `md-word-001`, confirmed against the actual SVG files - adjacent
    /// pages share nearly all their id strings). A wrong word's ids must
    /// only ever surface under its OWN page's key, never under some other
    /// page's - a flat, page-agnostic set would make a mistake on one page
    /// also paint a same-numbered, completely unrelated word red on
    /// whichever other page happens to reuse that id string.
    func testWrongWordIDsAreScopedToTheirOwnPage() {
        let tracker = RecitationProgressTracker()
        let firstPageIndex = ayahIndex(1, 7) // last ayah of Al-Fatiha (page 1)
        let laterPageIndex = ayahIndex(2, 1) // first ayah of Al-Baqarah (a later page)
        let firstPage = db.ayahs[firstPageIndex].startPage
        let laterPage = db.ayahs[laterPageIndex].startPage
        XCTAssertNotEqual(firstPage, laterPage, "test assumes a page boundary here")

        let snapshot = tracker.handleCommits(
            [RecitationCommit(flatIndex: db.flatStart(ofAyahIndex: laterPageIndex), status: .mismatch)],
            database: db
        )

        XCTAssertFalse((snapshot.wrongWordIDsByPage[laterPage] ?? []).isEmpty, "the mistake's own page must carry it")
        XCTAssertTrue((snapshot.wrongWordIDsByPage[firstPage] ?? []).isEmpty, "an earlier page must never inherit another page's mistake, even if its own SVG happens to reuse the same id string")
    }

    // MARK: - strict mode gate

    func testStrictModeHoldsPositionAtMismatchedWord() {
        let tracker = RecitationProgressTracker()
        tracker.strictMode = true
        let index = ayahIndex(1, 1)
        let flatStart = db.flatStart(ofAyahIndex: index)
        let slot0 = db.wordMaps[index].slots[0]

        // A gated word is deliberately withheld from both reveal and
        // highlight - it must not show up on the mushaf as anything
        // (glyph-wise) until it's corrected. It surfaces separately, in
        // `gatedWordIDs`, so the UI can still mark its line red.
        let afterMismatch = tracker.handleCommits([RecitationCommit(flatIndex: flatStart, status: .mismatch)], database: db)
        XCTAssertTrue(afterMismatch.highlightedWordIDs.isEmpty)
        XCTAssertTrue(afterMismatch.revealedWordIDsOnActivePage.isEmpty)
        XCTAssertEqual(afterMismatch.gatedWordIDs, Set(slot0.svgElementIds))
        XCTAssertEqual(wrongIDs(afterMismatch, page: db.ayahs[index].startPage), Set(slot0.svgElementIds))

        // The reciter (or the underlying pipeline, still running underneath)
        // keeps going past the mistake -- the display must not follow, and
        // those withheld commits must not taint the permanent mistake
        // record either (they were never actually shown to the reciter).
        let afterFurtherCommits = tracker.handleCommits(
            [
                RecitationCommit(flatIndex: flatStart + 1, status: .match),
                RecitationCommit(flatIndex: flatStart + 2, status: .mismatch),
            ],
            database: db
        )
        XCTAssertEqual(afterFurtherCommits.gatedWordIDs, Set(slot0.svgElementIds), "gate must stay held at the same word")
        XCTAssertEqual(afterFurtherCommits.revealedWordIDsOnActivePage, afterMismatch.revealedWordIDsOnActivePage, "reveal must not advance past the gate")
        XCTAssertEqual(wrongIDs(afterFurtherCommits, page: db.ayahs[index].startPage), Set(slot0.svgElementIds), "a withheld word's commit must not be added to the permanent mistake record")
    }

    func testStrictModeMatchAtGateClearsAndResumes() {
        let tracker = RecitationProgressTracker()
        tracker.strictMode = true
        let index = ayahIndex(1, 1)
        let flatStart = db.flatStart(ofAyahIndex: index)
        let slot0 = db.wordMaps[index].slots[0]
        let slot1 = db.wordMaps[index].slots[1]

        _ = tracker.handleCommits([RecitationCommit(flatIndex: flatStart, status: .mismatch)], database: db)
        XCTAssertNotNil(tracker.strictGateFlatIndex)

        // Correcting the gate word reveals it (so its glyph finally shows)
        // but, since it's already in the permanent mistake record, it must
        // not get the ordinary "currently reciting" highlight - it goes
        // straight to red.
        let afterCorrection = tracker.handleCommits([RecitationCommit(flatIndex: flatStart, status: .match)], database: db)
        XCTAssertNil(tracker.strictGateFlatIndex, "a genuine match at the gated word must clear the gate")
        XCTAssertTrue(afterCorrection.gatedWordIDs.isEmpty)
        XCTAssertTrue(Set(slot0.svgElementIds).isSubset(of: afterCorrection.revealedWordIDsOnActivePage), "corrected word must now be revealed")
        XCTAssertTrue(afterCorrection.highlightedWordIDs.isEmpty, "a corrected (previously-wrong) word must not flash the ordinary highlight")

        let afterNext = tracker.handleCommits([RecitationCommit(flatIndex: flatStart + 1, status: .match)], database: db)
        XCTAssertEqual(afterNext.highlightedWordIDs, Set(slot1.svgElementIds), "position must resume advancing once the gate clears")
        XCTAssertNotEqual(afterCorrection.highlightedWordIDs, afterNext.highlightedWordIDs)
    }

    func testClearStrictGateReleasesHoldWithoutAMatch() {
        let tracker = RecitationProgressTracker()
        tracker.strictMode = true
        let index = ayahIndex(1, 1)
        let flatStart = db.flatStart(ofAyahIndex: index)
        let slot1 = db.wordMaps[index].slots[1]

        _ = tracker.handleCommits([RecitationCommit(flatIndex: flatStart, status: .mismatch)], database: db)
        tracker.clearStrictGate()

        let snapshot = tracker.handleCommits([RecitationCommit(flatIndex: flatStart + 1, status: .match)], database: db)

        XCTAssertNil(tracker.strictGateFlatIndex)
        XCTAssertEqual(snapshot.highlightedWordIDs, Set(slot1.svgElementIds))
    }

    /// Regression, matching the real caller (`RecitationSession.
    /// handleRelocalized` only ever releases a gate via a genuinely
    /// *backward* relocalization, never a forward one): a gate released
    /// without ever being corrected must not leave its word revealable once
    /// position has moved to an earlier ayah - it's still in `wrongWordIDs`
    /// (permanent record) but was never actually confirmed at its own
    /// position, so it must stay out of `revealedWordIDsOnActivePage`. The
    /// UI relies on this: it only ever renders a `wrongWordIDs` member red
    /// on the active page when it's ALSO revealed - otherwise a released
    /// gate would show up as a red glyph floating disconnected from wherever
    /// the reveal frontier actually is.
    func testReleasedGateWordStaysUnrevealedAfterBackwardRelocalize() {
        let tracker = RecitationProgressTracker()
        tracker.strictMode = true
        let earlierIndex = ayahIndex(1, 1)
        let laterIndex = ayahIndex(1, 3)
        let gateFlatStart = db.flatStart(ofAyahIndex: laterIndex)
        let gateSlot0 = db.wordMaps[laterIndex].slots[0]
        let earlierSlot0 = db.wordMaps[earlierIndex].slots[0]

        // A mismatch lands on a later ayah (as if the pipeline briefly
        // misheard the start of a backtrack as belonging to whatever was
        // next in the expected queue) and opens a gate there.
        let afterMismatch = tracker.handleCommits([RecitationCommit(flatIndex: gateFlatStart, status: .mismatch)], database: db)
        XCTAssertNotNil(tracker.strictGateFlatIndex)
        XCTAssertEqual(afterMismatch.gatedWordIDs, Set(gateSlot0.svgElementIds))

        // The genuine backtrack is then detected and releases the gate
        // (never corrected) before landing on the earlier ayah.
        tracker.clearStrictGate()
        let snapshot = tracker.handleCommits([RecitationCommit(flatIndex: db.flatStart(ofAyahIndex: earlierIndex), status: .match)], database: db)

        XCTAssertTrue(snapshot.gatedWordIDs.isEmpty)
        XCTAssertTrue(Set(gateSlot0.svgElementIds).isDisjoint(with: snapshot.revealedWordIDsOnActivePage), "the never-confirmed gate word must not be swept into reveal")
        XCTAssertEqual(wrongIDs(snapshot, page: db.ayahs[laterIndex].startPage), Set(gateSlot0.svgElementIds), "still a permanent mistake record, just not revealed")
        XCTAssertEqual(snapshot.highlightedWordIDs, Set(earlierSlot0.svgElementIds))
    }

    /// Regression: a live, mid-recitation skip (the DP alignment settling a
    /// word `.deleted` because the reciter's audio jumped straight past it -
    /// see `PhonemeWordAligner`) must gate strict mode exactly like a
    /// mismatch, not silently let the display advance past a word that was
    /// never actually recited.
    func testStrictModeGatesOnLiveSkippedWord() {
        let tracker = RecitationProgressTracker()
        tracker.strictMode = true
        let index = ayahIndex(1, 1)
        let flatStart = db.flatStart(ofAyahIndex: index)
        let slot0 = db.wordMaps[index].slots[0]

        let afterSkip = tracker.handleCommits([RecitationCommit(flatIndex: flatStart, status: .deleted, isSessionEndDeletion: false)], database: db)

        XCTAssertNotNil(tracker.strictGateFlatIndex, "a live skip must open a gate")
        XCTAssertEqual(afterSkip.gatedWordIDs, Set(slot0.svgElementIds))
        XCTAssertEqual(wrongIDs(afterSkip, page: db.ayahs[index].startPage), Set(slot0.svgElementIds))

        // The reciter goes back and actually says the skipped word - a
        // genuine match at the gate must still clear it, same as correcting
        // an ordinary mismatch.
        let afterCorrection = tracker.handleCommits([RecitationCommit(flatIndex: flatStart, status: .match)], database: db)
        XCTAssertNil(tracker.strictGateFlatIndex)
        XCTAssertTrue(Set(slot0.svgElementIds).isSubset(of: afterCorrection.revealedWordIDsOnActivePage))
    }

    /// Regression: a `.deleted` word only because the session ended before
    /// reaching it (`RecitationChecker.finish()`'s forced flush) must NOT
    /// gate - that's "the reciter stopped reciting for now", not evidence
    /// they skipped something mid-recitation.
    func testStrictModeDoesNotGateOnSessionEndDeletion() {
        let tracker = RecitationProgressTracker()
        tracker.strictMode = true
        let index = ayahIndex(1, 1)
        let flatStart = db.flatStart(ofAyahIndex: index)

        let snapshot = tracker.handleCommits([RecitationCommit(flatIndex: flatStart, status: .deleted, isSessionEndDeletion: true)], database: db)

        XCTAssertNil(tracker.strictGateFlatIndex)
        XCTAssertTrue(snapshot.wrongWordIDsByPage.isEmpty)
    }

    /// Regression guard: every earlier test in this file runs with
    /// `strictMode` at its default (false) and must be completely
    /// unaffected by the gate logic existing at all.
    func testStrictModeOffDoesNotGate() {
        let tracker = RecitationProgressTracker()
        XCTAssertFalse(tracker.strictMode)
        let index = ayahIndex(1, 1)
        let flatStart = db.flatStart(ofAyahIndex: index)
        let slot1 = db.wordMaps[index].slots[1]

        _ = tracker.handleCommits([RecitationCommit(flatIndex: flatStart, status: .mismatch)], database: db)
        let snapshot = tracker.handleCommits([RecitationCommit(flatIndex: flatStart + 1, status: .match)], database: db)

        XCTAssertEqual(snapshot.highlightedWordIDs, Set(slot1.svgElementIds), "no gate should ever form when strictMode is off")
    }
}
