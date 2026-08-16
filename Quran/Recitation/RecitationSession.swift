import Foundation

/// Orchestrates live recitation → ayah matching (plan §7): owns the mic
/// capture and ASR transducer, re-decodes the rolling audio buffer on a
/// ~0.5s tick, and advances a word-indexed cursor into the running
/// transcript to find which ayah is being recited.
///
/// Matching is deliberately two-tier: candidate search uses the
/// harakat-stripped *skeleton* (forgiving of ASR/database representation
/// differences, so a single wrong diacritic never blocks recognizing the
/// ayah), while a separate, non-blocking tashkeel comparison flags
/// per-word diacritic mistakes once the ayah is already known - a
/// foundation for future accuracy/mistake scoring (not implemented yet).
///
/// `nonisolated` so its background tick loop can call the blocking ASR
/// decode without hopping through the main actor; only the UI-facing
/// `barState` write hops back via `@MainActor`.
nonisolated final class RecitationSession {
    private let mic = MicrophoneCapture()
    private let currentPages: () -> ClosedRange<Int>
    private let barState: RecitationBarState

    private var loopTask: Task<Void, Never>?
    private var wordCursor = 0
    private var lastTranscript = ""

    init(currentPages: @escaping () -> ClosedRange<Int>, barState: RecitationBarState) {
        self.currentPages = currentPages
        self.barState = barState
    }

    func start() {
        wordCursor = 0
        lastTranscript = ""

        let barState = barState
        loopTask = Task {
            do {
                try await mic.start()
            } catch {
                print("MicrophoneCapture failed to start: \(error)")
                await MainActor.run { barState.endRecording() }
                return
            }

            let database = QuranDatabase()
            let transcriber = QuranTranscriber()
            while !Task.isCancelled {
                tick(database: database, transcriber: transcriber)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        mic.stop()
    }

    private func tick(database: QuranDatabase, transcriber: QuranTranscriber) {
        let samples = mic.snapshot()
        guard !samples.isEmpty else { return }

        let text = transcriber.transcribe(samples: samples)
        // A re-decode can occasionally come back shorter mid-word - never
        // let the displayed/matched transcript shrink.
        if text.count >= lastTranscript.count {
            lastTranscript = text
        }

        let displayText = lastTranscript
        let barState = barState
        Task { @MainActor in
            barState.liveTranscript = displayText
        }

        let words = normalizeArabicTashkeel(lastTranscript).split(separator: " ").map(String.init)
        let pages = currentPages()
        let attempt = attemptAyahMatch(words: words, cursor: wordCursor, database: database, currentPages: pages)
        wordCursor = attempt.newCursor
        if let ayah = attempt.ayah {
            print("\(ayah.surah):\(ayah.ayahNumber)  \(ayah.textUthmani)")
        }
        // TEMPORARY diagnostic logging - remove once live matching is confirmed working.
        let tail = words.count > wordCursor ? Array(words[wordCursor...]) : []
        let skeletonTail = normalizeArabicSkeleton(tail.joined(separator: " "))
        let candidateCount = database.candidates(forSkeletonSubstring: skeletonTail).count
        print("[tick] ayahs=\(database.ayahs.count) pages=\(pages) words=\(words.count) cursor=\(wordCursor) resolved=\(attempt.ayah != nil) candidates=\(candidateCount) tail=\"\(tail.suffix(8).joined(separator: " "))\"")
    }
}
