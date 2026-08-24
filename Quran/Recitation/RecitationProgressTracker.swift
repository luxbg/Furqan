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
    /// Every word ever settled as `.mismatch` this session, whole-session
    /// (never shrinks, never recomputed away - even if the same word is
    /// later backtracked-to and recited correctly, unlike
    /// `revealedWordIDsOnActivePage`/`highlightedWordIDs` which recompute
    /// wholesale each snapshot) and union-only - a permanent mistake record
    /// for the session, mirroring how `highestReachedPage` already persists.
    /// Keyed by page number: `WordSlot.svgElementIds` are only unique
    /// *within* one page's own SVG (`md-word-001`, `md-word-002`, ... start
    /// over on every page - confirmed against the actual mushaf SVG files),
    /// so a flat, page-agnostic `Set<String>` would make a wrong word on one
    /// page also light up red on any other page whose own SVG happens to
    /// reuse the same id string for a completely different word (which,
    /// given near-total id overlap between adjacent pages, is basically
    /// guaranteed to happen) - `wordDisplayState(for:)` must always look up
    /// this page's own entry, never pass the whole thing to every page.
    let wrongWordIDsByPage: [Int: Set<String>]
    /// Strict mode only: the word currently gating the display, if any -
    /// deliberately excluded from `revealedWordIDsOnActivePage`/
    /// `highlightedWordIDs` (the mushaf shouldn't show *what* the word is
    /// while it's still wrong) but broken out here so the UI can still draw
    /// something at its position (a red placeholder line instead of the
    /// ordinary grey one) rather than looking identical to text that just
    /// hasn't been reached yet. Once corrected, the word moves out of this
    /// set and into `revealedWordIDsOnActivePage` (and stays in `wrongWordIDs`,
    /// so it then renders with its glyph shown in red).
    let gatedWordIDs: Set<String>
}

/// One settled word's flat-word position plus the verdict it settled with -
/// `RecitationProgressTracker` is otherwise deliberately correctness-agnostic
/// about *position* tracking, but needs the status to know which words to
/// add to `wrongWordIDs` (and, in strict mode, which words to gate on).
struct RecitationCommit {
    let flatIndex: Int
    let status: PhonemeWordStatus
    /// Mirrors `PhonemeWordCheckResult.isSessionEndDeletion` -- only
    /// meaningful when `status == .deleted`. See `handleCommits`.
    var isSessionEndDeletion = false
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
    private(set) var wrongWordIDsByPage: [Int: Set<String>] = [:]

    /// Set once by `RecitationSession` at session start from
    /// `PhonemeSettings.strictMode`; not itself reset by `reset()` (a
    /// pause/resume shouldn't silently drop the setting).
    var strictMode = false
    /// The flat-word index strict mode is currently holding the display at,
    /// or nil if nothing is gated. See `handleCommits`/`clearStrictGate`.
    private(set) var strictGateFlatIndex: Int?

    func reset() {
        highestReachedPage = nil
        activePage = nil
        currentAyahIndex = nil
        currentWordIndexInAyah = nil
        wrongWordIDsByPage = [:]
        strictGateFlatIndex = nil
    }

    /// Releases a strict-mode gate without requiring a `.match` commit at
    /// the gated position - used when the reciter has genuinely relocalized
    /// backward of the gate (see `RecitationSession`'s wiring of
    /// `RecitationChecker.onRelocalized`), which is a real "moved on"
    /// signal distinct from ordinary forward commits.
    func clearStrictGate() {
        strictGateFlatIndex = nil
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

    /// Called with each tick's newly settled commits, in order (mapped from
    /// `PhonemeWordCheckResult` via `PhonemeWordMapping` -- this type
    /// deliberately doesn't know about the phoneme pipeline at all, only
    /// flat-word positions plus the bare status needed for `wrongWordIDs`/
    /// strict-mode gating).
    func handleCommits(_ commits: [RecitationCommit], database: QuranDatabase) -> RecitationProgressSnapshot {
        for commit in commits {
            let word = database.flatWords[commit.flatIndex]

            if strictMode {
                if let gate = strictGateFlatIndex {
                    // Anything other than the gate itself, while a gate is
                    // active, is withheld entirely - including from
                    // `wrongWordIDs`. The aligner keeps running underneath a
                    // held gate (see `RecitationChecker`), so a commit here
                    // for some other position reflects the pipeline still
                    // sorting itself out mid-correction, not a real verdict
                    // on a word the reciter was ever actually shown - baking
                    // it into the permanent mistake record would falsely,
                    // permanently mark words red that were never wrong.
                    guard commit.flatIndex == gate else { continue }
                    if isGateWorthy(commit) {
                        let slot = database.wordMaps[word.ayahIndex].slots[word.wordIndexInAyah]
                        let page = database.ayahs[word.ayahIndex].startPage
                        wrongWordIDsByPage[page, default: []].formUnion(slot.svgElementIds)
                    } else if commit.status == .match {
                        strictGateFlatIndex = nil
                        setPosition(ayahIndex: word.ayahIndex, wordIndexInAyah: word.wordIndexInAyah, database: database)
                    }
                    continue
                }
                if isGateWorthy(commit) {
                    // Deliberately does NOT call `setPosition` -- the gate
                    // word itself is never a confirmed position (that's the
                    // whole point of gating it), so `currentWordIndexInAyah`
                    // must stay at whatever was last genuinely settled.
                    // `snapshot()` still surfaces this word separately (via
                    // `strictGateFlatIndex`, looked up directly) for the red
                    // placeholder line - it doesn't need to be "the current
                    // position" for that. Bug regression: this used to call
                    // `setPosition` here, which stuck `currentWordIndexInAyah`
                    // on the gate word; if the gate was later released
                    // without ever being corrected (a backward relocalize,
                    // not a match), any subsequent forward commit's blanket
                    // "reveal 0...here" swept the never-confirmed gate word
                    // in anyway, showing it as a stray red glyph nowhere near
                    // the actual reveal frontier.
                    let slot = database.wordMaps[word.ayahIndex].slots[word.wordIndexInAyah]
                    let page = database.ayahs[word.ayahIndex].startPage
                    wrongWordIDsByPage[page, default: []].formUnion(slot.svgElementIds)
                    strictGateFlatIndex = commit.flatIndex
                    highestReachedPage = max(highestReachedPage ?? page, page)
                    activePage = page
                    continue
                }
                setPosition(ayahIndex: word.ayahIndex, wordIndexInAyah: word.wordIndexInAyah, database: database)
                continue
            }

            if commit.status == .mismatch {
                let slot = database.wordMaps[word.ayahIndex].slots[word.wordIndexInAyah]
                let page = database.ayahs[word.ayahIndex].startPage
                wrongWordIDsByPage[page, default: []].formUnion(slot.svgElementIds)
            }
            setPosition(ayahIndex: word.ayahIndex, wordIndexInAyah: word.wordIndexInAyah, database: database)
        }
        return snapshot(database: database)
    }

    /// Strict mode only: whether `commit` should gate the display like an
    /// ordinary mismatch -- true for a genuine mismatch, and also for a
    /// live, mid-recitation skip (the DP alignment caught the reciter's
    /// audio jumping straight past this word, with nothing matching its
    /// expected phonemes in between - see `PhonemeWordAligner`'s live
    /// `.deleted` settling). Deliberately false for a `.deleted` word that
    /// only exists because the session ended before reaching it
    /// (`isSessionEndDeletion` - `RecitationChecker.finish()`'s forced
    /// flush) - that's "the reciter stopped for now", not a mistake to
    /// block on. Non-strict mode stays correctness-agnostic about `.deleted`
    /// entirely (see the class doc) and never calls this.
    private func isGateWorthy(_ commit: RecitationCommit) -> Bool {
        commit.status == .mismatch || (commit.status == .deleted && !commit.isSessionEndDeletion)
    }

    private func setPosition(ayahIndex: Int, wordIndexInAyah: Int?, database: QuranDatabase) {
        let page = database.ayahs[ayahIndex].startPage
        highestReachedPage = max(highestReachedPage ?? page, page)
        activePage = page
        currentAyahIndex = ayahIndex
        currentWordIndexInAyah = wordIndexInAyah
    }

    /// The strict-mode gate word's own slot, looked up directly from
    /// `strictGateFlatIndex` rather than derived from `currentAyahIndex`/
    /// `currentWordIndexInAyah` -- the gate word is deliberately never a
    /// confirmed position (see `handleCommits`), so it can't be found by
    /// walking from those the way `revealed`/`highlighted` are.
    private func gatedSlot(database: QuranDatabase) -> WordSlot? {
        guard strictMode, let gate = strictGateFlatIndex else { return nil }
        let word = database.flatWords[gate]
        return database.wordMaps[word.ayahIndex].slots[word.wordIndexInAyah]
    }

    private func snapshot(database: QuranDatabase) -> RecitationProgressSnapshot {
        let gated = Set(gatedSlot(database: database)?.svgElementIds ?? [])

        guard let activePage, let currentAyahIndex else {
            return RecitationProgressSnapshot(
                highestReachedPage: highestReachedPage, activePage: activePage, revealedWordIDsOnActivePage: [], highlightedWordIDs: [],
                wrongWordIDsByPage: wrongWordIDsByPage, gatedWordIDs: gated
            )
        }

        let wrongOnActivePage = wrongWordIDsByPage[activePage] ?? []
        var revealed: Set<String> = []
        var highlighted: Set<String> = []
        for ayahIndex in database.ayahIndicesByPage[activePage] ?? [] where ayahIndex <= currentAyahIndex {
            let slots = database.wordMaps[ayahIndex].slots
            if ayahIndex < currentAyahIndex {
                for slot in slots {
                    revealed.formUnion(slot.svgElementIds)
                    revealed.formUnion(slot.markerSvgElementIds)
                }
            } else if let upTo = currentWordIndexInAyah, slots.indices.contains(upTo) {
                for (wordIndex, slot) in slots.enumerated() where wordIndex <= upTo {
                    revealed.formUnion(slot.svgElementIds)
                    revealed.formUnion(slot.markerSvgElementIds)
                }
                let slot = slots[upTo]
                if wrongOnActivePage.isDisjoint(with: slot.svgElementIds) {
                    // A word already wrong (a correction just settled, or a
                    // non-strict-mode backtrack onto an old mistake)
                    // shouldn't flash the ordinary "currently reciting"
                    // highlight - it goes straight to its permanent red
                    // instead (see `wordDisplayState`'s highlighted > wrong
                    // > revealed precedence).
                    highlighted = Set(slot.svgElementIds)
                }
            }
        }

        return RecitationProgressSnapshot(
            highestReachedPage: highestReachedPage,
            activePage: activePage,
            revealedWordIDsOnActivePage: revealed,
            highlightedWordIDs: highlighted,
            wrongWordIDsByPage: wrongWordIDsByPage,
            gatedWordIDs: gated
        )
    }
}
