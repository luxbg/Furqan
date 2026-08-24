import Foundation
import Observation

/// UI-facing recitation progress, owned by `ContentView` via `@State` and
/// written to from `RecitationSession`'s tick loop on the main actor - the
/// same pattern `RecitationBarState.liveTranscript` already uses. Kept
/// separate from `RecitationBarState` since this is consumed by every
/// mounted `MushafPageView` (potentially dozens), not just the bottom
/// control bar.
@Observable
final class RecitationProgress {
    private(set) var highestReachedPage: Int?
    private(set) var activePage: Int?
    private(set) var revealedWordIDsOnActivePage: Set<String> = []
    private(set) var highlightedWordIDs: Set<String> = []
    /// Keyed by page number - see `RecitationProgressSnapshot.wrongWordIDsByPage`
    /// for why this must never be flattened into a single page-agnostic set.
    private(set) var wrongWordIDsByPage: [Int: Set<String>] = [:]
    private(set) var gatedWordIDs: Set<String> = []
    private(set) var isActive = false

    func beginSession() {
        isActive = true
        highestReachedPage = nil
        activePage = nil
        revealedWordIDsOnActivePage = []
        highlightedWordIDs = []
        wrongWordIDsByPage = [:]
        gatedWordIDs = []
    }

    func endSession() {
        isActive = false
        highestReachedPage = nil
        activePage = nil
        revealedWordIDsOnActivePage = []
        highlightedWordIDs = []
        wrongWordIDsByPage = [:]
        gatedWordIDs = []
    }

    func apply(_ snapshot: RecitationProgressSnapshot) {
        highestReachedPage = snapshot.highestReachedPage
        activePage = snapshot.activePage
        revealedWordIDsOnActivePage = snapshot.revealedWordIDsOnActivePage
        highlightedWordIDs = snapshot.highlightedWordIDs
        wrongWordIDsByPage = snapshot.wrongWordIDsByPage
        gatedWordIDs = snapshot.gatedWordIDs
    }
}
