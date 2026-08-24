import Foundation

/// Orchestrates live recitation -> mushaf tracking. Owns the mic capture and
/// the phoneme ASR pipeline (`StreamingPhonemeRecognizer` ->
/// `RecitationChecker`, which internally wires the locator + aligner - see
/// `Quran/Phoneme/`), and turns each settled `PhonemeWordCheckResult` into
/// word-reveal/highlight state for the mushaf UI via `PhonemeWordMapping` +
/// `RecitationProgressTracker`.
///
/// Audio is genuinely streaming now (unlike the old rolling-buffer/periodic-
/// full-redecode design): `MicrophoneCapture` pushes small chunks straight
/// into the recognizer as they arrive. A lightweight poll loop only handles
/// pause/resume, which the recitation bar drives via `barState.isPaused`.
///
/// `nonisolated` so its audio-delivery callback can call the blocking ASR
/// decode without hopping through the main actor; only the UI-facing
/// `barState`/`onProgress`/`onPageJump` writes hop back via `@MainActor`.
nonisolated final class RecitationSession {
    private let mic = MicrophoneCapture()
    private let barState: RecitationBarState
    private let onProgress: @MainActor (RecitationProgressSnapshot) -> Void
    private let onPageJump: @MainActor (Int) -> Void

    private var loopTask: Task<Void, Never>?
    private var wasPaused = false
    /// Wall-clock reference for the `[t=...]` diagnostic logging below --
    /// lets console output show whether a settled word's ASR tokens
    /// actually arrived late (model/decoding latency) or arrived promptly
    /// but sat unsettled (aligner latency), which look identical without a
    /// timestamp to compare against.
    private var sessionClockStart = Date()
    private func elapsed() -> String { String(format: "%.2f", Date().timeIntervalSince(sessionClockStart)) }

    private var database: QuranDatabase?
    private var corpus: PhonemeCorpus?
    private var mapping: PhonemeWordMapping?
    private var recognizer: StreamingPhonemeRecognizer?
    private var checker: RecitationChecker?

    private let progressTracker = RecitationProgressTracker()
    private let settings: PhonemeSettings = .default
    /// Mirrors `progressTracker.strictGateFlatIndex`, but in this pipeline's
    /// own `globalWordIdx` space - captured directly from the
    /// `PhonemeWordCheckResult` that opened the gate (no reverse flat-index
    /// -> corpus lookup needed). Kept in sync by `handleWordResult`/
    /// `handleRelocalized`; used to detect a genuine backward relocalize
    /// (see `handleRelocalized`) - the checker itself independently halts
    /// forward recognition at the same word (see `RecitationChecker.pinToGate`).
    private var strictGateGlobalWordIdx: Int?
    /// Rolling display string of the last few settled words' own Uthmani
    /// text - the phoneme ASR's raw output is an internal phonetic
    /// alphabet, not readable Arabic script, so (unlike the old word-level
    /// ASR's raw transcript) it isn't shown directly; this is the
    /// closest readable equivalent for the live-status UI.
    private var recentWordsDisplay: [String] = []
    private let recentWordsDisplayCap = 6

    init(
        barState: RecitationBarState,
        onProgress: @escaping @MainActor (RecitationProgressSnapshot) -> Void,
        onPageJump: @escaping @MainActor (Int) -> Void
    ) {
        self.barState = barState
        self.onProgress = onProgress
        self.onPageJump = onPageJump
    }

    func start() {
        wasPaused = false
        recentWordsDisplay = []
        progressTracker.reset()
        progressTracker.strictMode = settings.strictMode
        strictGateGlobalWordIdx = nil
        sessionClockStart = Date()

        let barState = barState
        loopTask = Task {
            do {
                try await startEngine()
            } catch {
                print("RecitationSession failed to start: \(error)")
                await MainActor.run { barState.endRecording() }
                return
            }

            while !Task.isCancelled {
                await pollPauseState()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        mic.stop()
        checker?.finish()
        checker = nil
        recognizer = nil
    }

    private func startEngine() async throws {
        let database = QuranDatabase()
        let corpus = try PhonemeCorpus.loadFromBundle()
        let mapping = PhonemeWordMapping(corpus: corpus, database: database)
        let recognizer = StreamingPhonemeRecognizer()
        self.database = database
        self.corpus = corpus
        self.mapping = mapping
        self.recognizer = recognizer
        self.checker = Self.makeChecker(corpus: corpus, settings: settings, session: self)

        try await mic.start { [weak self] samples in
            self?.processSamples(samples)
        }
    }

    private static func makeChecker(corpus: PhonemeCorpus, settings: PhonemeSettings, session: RecitationSession) -> RecitationChecker {
        RecitationChecker(
            corpus: corpus,
            settings: settings,
            onWordResult: { [weak session] result in session?.handleWordResult(result) },
            onStatus: { [weak session] message in session?.handleStatus(message) },
            onRelocalized: { [weak session] globalWordIdx in session?.handleRelocalized(globalWordIdx) }
        )
    }

    /// Runs on `MicrophoneCapture`'s own delivery queue, never the audio
    /// render thread or the main actor - this is where the neural network
    /// and the DP alignment run.
    private func processSamples(_ samples: [Float]) {
        guard let recognizer, let checker else { return }
        recognizer.feedAudio(samples: samples)
        let tokens = recognizer.pollNewTokens()
        guard !tokens.isEmpty else { return }
        print("[asr t=\(elapsed())s] +\"\(tokens.map(\.symbol).joined())\" (asrTime=\(tokens.last?.timeS ?? -1))")
        checker.feedTokens(tokens)
    }

    private func pollPauseState() async {
        let isPaused = barState.isPaused

        if isPaused, !wasPaused {
            wasPaused = true
            mic.stop()
            checker?.finish()
            return
        }
        if !isPaused, wasPaused {
            wasPaused = false
            recentWordsDisplay = []
            // A pause/resume is how the reciter signals "I'm jumping to an
            // unrelated part of the Quran" - the reveal/highlight state
            // from before the pause shouldn't carry over, so this resets
            // exactly like a fresh session start: fresh locator/aligner
            // (via a fresh RecitationChecker), same corpus/database/mapping.
            progressTracker.reset()
            progressTracker.strictMode = settings.strictMode
            strictGateGlobalWordIdx = nil
            dispatch(RecitationProgressSnapshot(
                highestReachedPage: nil, activePage: nil,
                revealedWordIDsOnActivePage: [], highlightedWordIDs: [], wrongWordIDsByPage: [:], gatedWordIDs: []
            ))
            guard let corpus else { return }
            checker = Self.makeChecker(corpus: corpus, settings: settings, session: self)
            do {
                try await mic.start { [weak self] samples in
                    self?.processSamples(samples)
                }
            } catch {
                print("MicrophoneCapture failed to resume: \(error)")
            }
            return
        }
    }

    private func handleWordResult(_ result: PhonemeWordCheckResult) {
        guard let database, let mapping else { return }

        let label = "[t=\(elapsed())s] \(result.surah):\(result.ayah) word \(result.wordIndex)"
        switch result.status {
        case .match:
            print("  \u{2713} \(label): \"\(result.wordText ?? result.expectedPhonemes)\"")
        case .mismatch:
            print("  \u{2717} \(label): expected \"\(result.expectedPhonemes)\" got \"\(result.actualPhonemes ?? "?")\"")
        case .deleted:
            print("  \u{2298} \(label): \"\(result.wordText ?? result.expectedPhonemes)\" missed (not recited)")
        }

        if let text = result.wordText, !result.wordTextContinuesPrevious {
            recentWordsDisplay.append(text)
            if recentWordsDisplay.count > recentWordsDisplayCap {
                recentWordsDisplay.removeFirst(recentWordsDisplay.count - recentWordsDisplayCap)
            }
            let displayText = recentWordsDisplay.joined(separator: " ")
            let barState = barState
            Task { @MainActor in barState.liveTranscript = displayText }
        }

        guard let flatIndex = mapping.flatIndex(for: result, database: database) else { return }
        let gateWasActive = progressTracker.strictGateFlatIndex != nil
        let commit = RecitationCommit(flatIndex: flatIndex, status: result.status, isSessionEndDeletion: result.isSessionEndDeletion)
        let snapshot = progressTracker.handleCommits([commit], database: database)

        if settings.strictMode {
            if !gateWasActive, progressTracker.strictGateFlatIndex != nil {
                // A gate just opened at this exact commit -- its
                // globalWordIndex is right here, no reverse flat->corpus
                // lookup needed.
                strictGateGlobalWordIdx = result.globalWordIndex
            } else if gateWasActive, progressTracker.strictGateFlatIndex == nil {
                strictGateGlobalWordIdx = nil
            }
        }

        dispatch(snapshot)
    }

    private func handleStatus(_ message: String) {
        print("[ayah] \(message)")
    }

    /// Wired to `RecitationChecker.onRelocalized` - fired on every genuine
    /// relocalization (never ordinary forward settling, and never the
    /// checker's own `pinToGate` re-pin onto the *same* word - that always
    /// reports `globalWordIdx == gate`, not `<`). Confirmed with the user:
    /// only a jump *backward* of a stuck strict-mode gate counts as "the
    /// reciter deliberately moved on for real" and releases it; a confident
    /// jump forward must not, since that would just be a backdoor around
    /// what strict mode exists to prevent.
    private func handleRelocalized(_ globalWordIdx: Int) {
        guard settings.strictMode, let gate = strictGateGlobalWordIdx, globalWordIdx < gate else { return }
        progressTracker.clearStrictGate()
        strictGateGlobalWordIdx = nil
    }

    private func dispatch(_ snapshot: RecitationProgressSnapshot) {
        let onProgress = onProgress
        let onPageJump = onPageJump
        Task { @MainActor in
            onProgress(snapshot)
            if let page = snapshot.activePage {
                onPageJump(page)
            }
        }
    }
}
