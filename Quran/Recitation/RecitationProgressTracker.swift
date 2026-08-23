import Foundation

struct RecitationProgressSnapshot: Equatable {
    /// Sticky/monotonic upper bound: once recitation has reached this page,
    /// every page up to it stays revealed even if the reciter later
    /// backtracks to an earlier one. `nil` before the very first
    /// identification of the session. Combined with `activePage` in
    /// `ContentView.wordDisplayState(for:)`: every page strictly before
    /// `activePage` reveals unconditionally (per the reciter's explicit
    /// preference - starting on page 4 should reveal pages 1-3 too, whether
    /// or not they were individually recited this session), and this field
    /// covers the one remaining case that alone doesn't - a page the
    /// reciter already passed via forward progress, then backtracked
    /// behind, which is now numerically *after* `activePage` but must still
    /// stay revealed rather than reverting to hidden.
    let highestReachedPage: Int?
    let activePage: Int?
    let revealedWordIDsOnActivePage: Set<String>
    /// A slot can be more than one SVG glyph (see `WordSlot.svgElementIds` -
    /// a fused mushaf glyph), so the current word's ids all highlight
    /// together, not just a single id.
    let highlightedWordIDs: Set<String>
}

/// Turns the phoneme pipeline's identification/settle events into word-
/// reveal and highlight state for the mushaf UI.
///
/// Reveal state for the *active* page is always recomputed wholesale from
/// the current position (every ayah on that page up to the current one, in
/// full; the current ayah itself only up to its most recently committed
/// word) rather than accumulated incrementally - two things depend on this:
/// starting mid-page must reveal everything before the starting ayah even
/// though none of it was individually recited this session, and repeating
/// an earlier ayah (a backtrack) must resume normal progressive
/// reveal/highlight from that earlier point, not leave the whole page
/// blanket-revealed with no highlight just because it happened to have been
/// fully passed once already.
///
/// Highlight only ever reflects a word the aligner has actually settled a
/// verdict for (match, mismatch, *or* deleted -- position tracking here is
/// deliberately correctness-agnostic; whether the word was recited right is
/// a separate concern from where the reciter currently is) - "highlight
/// only after settled" falls out for free by simply never showing anything
/// ahead of what's been committed. Unlike the old word-level aligner, the
/// phoneme pipeline has no "extra word said" concept to filter out (see
/// `RecitationChecker`'s "why character-level" doc) - every settled result
/// has a real flat-word position.
final class RecitationProgressTracker {
    private(set) var highestReachedPage: Int?
    private var activePage: Int?
    private var currentAyahIndex: Int?
    /// How many of the current ayah's words have been committed - nil right
    /// after a fresh identification, before any word in it is matched.
    private var currentWordIndexInAyah: Int?

    func reset() {
        highestReachedPage = nil
        activePage = nil
        currentAyahIndex = nil
        currentWordIndexInAyah = nil
    }

    /// Called once identification first resolves (session start, or after a
    /// pause/resume jump) - establishes which page/ayah to jump to. Nothing
    /// in the identified ayah has actually been matched yet, so nothing in
    /// it is highlighted until the first `handleCommits` call arrives -
    /// everything on the page *before* it, however, reveals immediately.
    func handleIdentification(flatPosition: Int, database: QuranDatabase) -> RecitationProgressSnapshot {
        let word = database.flatWords[flatPosition]
        setPosition(ayahIndex: word.ayahIndex, wordIndexInAyah: nil, database: database)
        return snapshot(database: database)
    }

    /// Called with each tick's newly settled flat-word positions, in order
    /// (mapped from `PhonemeWordCheckResult` via `PhonemeWordMapping` --
    /// this type deliberately doesn't know about the phoneme pipeline at
    /// all, only flat-word positions).
    func handleCommits(_ flatIndices: [Int], database: QuranDatabase) -> RecitationProgressSnapshot {
        for flatIndex in flatIndices {
            let word = database.flatWords[flatIndex]
            setPosition(ayahIndex: word.ayahIndex, wordIndexInAyah: word.wordIndexInAyah, database: database)
        }
        return snapshot(database: database)
    }

    private func setPosition(ayahIndex: Int, wordIndexInAyah: Int?, database: QuranDatabase) {
        let page = database.ayahs[ayahIndex].startPage
        highestReachedPage = max(highestReachedPage ?? page, page)
        activePage = page
        currentAyahIndex = ayahIndex
        currentWordIndexInAyah = wordIndexInAyah
    }

    private func snapshot(database: QuranDatabase) -> RecitationProgressSnapshot {
        guard let activePage, let currentAyahIndex else {
            return RecitationProgressSnapshot(
                highestReachedPage: highestReachedPage, activePage: nil, revealedWordIDsOnActivePage: [], highlightedWordIDs: []
            )
        }

        var revealed: Set<String> = []
        var highlighted: Set<String> = []
        for ayahIndex in database.ayahIndicesByPage[activePage] ?? [] where ayahIndex <= currentAyahIndex {
            let slots = database.wordMaps[ayahIndex].slots
            if ayahIndex < currentAyahIndex {
                for slot in slots {
                    revealed.formUnion(slot.svgElementIds)
                    revealed.formUnion(slot.markerSvgElementIds)
                }
            } else if let upTo = currentWordIndexInAyah {
                for (wordIndex, slot) in slots.enumerated() where wordIndex <= upTo {
                    revealed.formUnion(slot.svgElementIds)
                    revealed.formUnion(slot.markerSvgElementIds)
                }
                if slots.indices.contains(upTo) {
                    highlighted = Set(slots[upTo].svgElementIds)
                }
            }
        }

        return RecitationProgressSnapshot(
            highestReachedPage: highestReachedPage,
            activePage: activePage,
            revealedWordIDsOnActivePage: revealed,
            highlightedWordIDs: highlighted
        )
    }
}
