import Foundation

/// Orchestrates live recitation -> ayah matching. Owns the mic capture and
/// ASR transducer, re-decodes the rolling audio buffer on a ~0.5s tick, and
/// drives `AyahAligner` to identify + track the reciter's position in the
/// Quran - and, on top of that, `RecitationProgressTracker` to turn each
/// identification/commit into word-reveal/highlight state for the mushaf UI.
///
/// State is deliberately small: `confirmedPosition` (a flat-word index) and
/// `floor` (where the current identification attempt began - a backtrack
/// can never resolve earlier than this). Jumping to an *unrelated* part of
/// the Quran requires an explicit pause -> resume (polled from
/// `barState.isPaused`, which the existing pause button already drives) -
/// losing track without pausing simply freezes (no resolution, nothing
/// printed) until either the transcript naturally lands back inside the
/// forward/backtrack windows, or the user pauses and resumes.
///
/// `nonisolated` so its background tick loop can call the blocking ASR
/// decode without hopping through the main actor; only the UI-facing
/// `barState`/`onProgress`/`onPageJump` writes hop back via `@MainActor`.
nonisolated final class RecitationSession {
    private let mic = MicrophoneCapture()
    private let currentPages: () -> ClosedRange<Int>
    private let barState: RecitationBarState
    private let onProgress: @MainActor (RecitationProgressSnapshot) -> Void
    private let onPageJump: @MainActor (Int) -> Void

    private var loopTask: Task<Void, Never>?

    private var confirmedPosition: Int?
    private var floor = 0
    private var wasPaused = false
    private var lastTranscript = ""
    /// Skeleton form of the last few committed observed words - the anchor
    /// `AyahAligner.observedTail` searches for to find "new since last
    /// commit" content in each tick's freshly re-decoded transcript.
    private var anchorWords: [String] = []
    /// Words committed since the current position was last freshly
    /// (re-)established (session start, or post-resume) - the first two of
    /// these are never scored, regardless of correctness (see
    /// `AyahAligner`'s doc and the plan's requirement 5: this is what makes
    /// muqata'at mistranscriptions non-fatal, generically, with no
    /// muqata'at-specific code anywhere).
    private var wordsSinceIdentification = 0
    /// Ayah index of the most recently *printed* word, to detect and log
    /// ayah transitions without needing a discrete per-ayah event.
    private var lastPrintedAyahIndex: Int?

    /// Whether `confirmedPosition` is still provisional (resolved off too
    /// few words to fully trust - see `AyahAligner.IdentificationResult`).
    private var isProvisional = false
    private var provisionalWordsRemaining = 0
    /// Ayahs rejected by a prior identification attempt this session (i.e.
    /// a provisional match that failed to track and was reopened) - passed
    /// to `identifyAyah` so the same wrong ayah can't be immediately
    /// re-picked. Cleared once a result is no longer provisional.
    private var excludedAyahIndices: Set<Int> = []

    private let anchorWordCount = 3
    private let progressTracker = RecitationProgressTracker()

    init(
        currentPages: @escaping () -> ClosedRange<Int>,
        barState: RecitationBarState,
        onProgress: @escaping @MainActor (RecitationProgressSnapshot) -> Void,
        onPageJump: @escaping @MainActor (Int) -> Void
    ) {
        self.currentPages = currentPages
        self.barState = barState
        self.onProgress = onProgress
        self.onPageJump = onPageJump
    }

    func start() {
        confirmedPosition = nil
        floor = 0
        wasPaused = false
        lastTranscript = ""
        anchorWords = []
        wordsSinceIdentification = 0
        lastPrintedAyahIndex = nil
        isProvisional = false
        provisionalWordsRemaining = 0
        excludedAyahIndices = []
        progressTracker.reset()

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
                await tick(database: database, transcriber: transcriber)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        mic.stop()
    }

    private func tick(database: QuranDatabase, transcriber: QuranTranscriber) async {
        let isPaused = barState.isPaused

        if isPaused, !wasPaused {
            wasPaused = true
            mic.stop()
            return
        }
        if !isPaused, wasPaused {
            wasPaused = false
            confirmedPosition = nil
            lastTranscript = ""
            anchorWords = []
            isProvisional = false
            provisionalWordsRemaining = 0
            excludedAyahIndices = []
            // A pause/resume is how the reciter signals "I'm jumping to an
            // unrelated part of the Quran" - the reveal/highlight state
            // from before the pause shouldn't carry over into whatever
            // comes next, so this resets exactly like a fresh session start.
            progressTracker.reset()
            dispatch(RecitationProgressSnapshot(
                highestReachedPage: nil, activePage: nil,
                revealedWordIDsOnActivePage: [], highlightedWordIDs: []
            ))
            do {
                try await mic.start()
            } catch {
                print("MicrophoneCapture failed to resume: \(error)")
            }
            return
        }
        guard !isPaused else { return }

        let samples = mic.snapshot()
        guard !samples.isEmpty else { return }

        // Always trust the fresh re-decode directly - unlike a growing or
        // per-ayah-flushed buffer, this is a *rolling* 30s window, so the
        // correct transcript for "right now" can legitimately be shorter
        // than an earlier tick's (old content ages out; a stray ASR
        // hallucination spike can also transiently lengthen one tick's
        // output). A "never let it shrink" guard would permanently wedge
        // `lastTranscript` the first time that happens - `observedTail`'s
        // anchor search is what actually handles this transcript not being
        // append-only, not this.
        lastTranscript = transcriber.transcribe(samples: samples)

        let displayText = lastTranscript
        let barState = barState
        Task { @MainActor in
            barState.liveTranscript = displayText
        }

        let rawWords = lastTranscript.split(separator: " ").map(String.init)
        let skeletonWords = rawWords.map(normalizeArabicSkeleton)
        let tashkeelWords = rawWords.map(normalizeGroundTruthTashkeel)

        guard let position = confirmedPosition else {
            let tail = Array(skeletonWords.suffix(25))
            guard let result = AyahAligner.identifyAyah(
                tailWords: tail, database: database, currentPages: currentPages(), excluding: excludedAyahIndices
            ) else {
                return
            }
            let ayah = database.ayahs[result.ayahIndex]
            let tag = result.isProvisional ? " (provisional)" : ""
            print("[ayah] identified\(tag) \(ayah.surah):\(ayah.ayahNumber)  \(ayah.textUthmani)")
            confirmedPosition = result.flatPosition
            floor = result.flatPosition
            anchorWords = []
            wordsSinceIdentification = 0
            lastPrintedAyahIndex = nil
            isProvisional = result.isProvisional
            provisionalWordsRemaining = result.isProvisional ? AyahAligner.provisionalVerificationWordCount : 0

            let snapshot = progressTracker.handleIdentification(flatPosition: result.flatPosition, database: database)
            dispatch(snapshot)
            return
        }

        let observed = AyahAligner.observedTail(transcript: skeletonWords, anchor: anchorWords)
        guard !observed.isEmpty else { return }
        let observedTashkeel = Array(tashkeelWords.suffix(observed.count))

        let result = AyahAligner.advance(
            observed: observed, observedTashkeel: observedTashkeel, confirmedPosition: position, floor: floor, database: database
        )

        let provisional = AyahAligner.provisionalUpdate(
            isProvisional: isProvisional, wordsRemaining: provisionalWordsRemaining, outcome: result.outcome, commitSteps: result.commitSteps
        )
        if provisional.shouldReopen {
            // A provisional guess that immediately fails to track is a red
            // flag it was wrong - reopen from scratch, excluding it, rather
            // than sitting frozen (see `AyahAligner.provisionalUpdate`).
            let rejectedAyahIndex = database.flatWords[min(position, database.flatWords.count - 1)].ayahIndex
            excludedAyahIndices.insert(rejectedAyahIndex)
            print("[ayah] reopening identification, previous guess didn't hold")
            confirmedPosition = nil
            floor = 0
            anchorWords = []
            isProvisional = false
            provisionalWordsRemaining = 0
            return
        }
        isProvisional = provisional.isProvisional
        provisionalWordsRemaining = provisional.wordsRemaining
        if !isProvisional {
            excludedAyahIndices = []
        }

        switch result.outcome {
        case .frozen:
            return
        case .backtrack:
            let word = database.flatWords[result.commitSteps.first?.flatIndex ?? position]
            let ayah = database.ayahs[word.ayahIndex]
            print("[ayah] reciter repeated from \(ayah.surah):\(ayah.ayahNumber) word \(word.wordIndexInAyah + 1)")
        case .forward:
            break
        }

        confirmedPosition = result.newPosition
        commit(result.commitSteps, observed: observed, observedTashkeel: observedTashkeel, database: database)
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

    /// Prints a verdict for each newly finalized step, feeds them to
    /// `progressTracker` for the mushaf UI, and advances the anchor.
    /// `tashkeelOK` (only meaningful for `.match` steps) comes precomputed
    /// from `AyahAligner.buildResult`, which already applied the same
    /// grace-holdback to it as a wrong word - by the time a step reaches
    /// here, both the skeleton-level and tashkeel-level verdicts are final,
    /// so this only needs to print them.
    private func commit(
        _ steps: [(flatIndex: Int, step: AyahAligner.Step, tashkeelOK: Bool?)],
        observed: [String], observedTashkeel: [String], database: QuranDatabase
    ) {
        guard !steps.isEmpty else { return }
        // `observed`/`observedTashkeel` are the two parallel arrays
        // `advance` was run against - steps reference positions within them
        // via `step.observedIndex`.
        for (flatIndex, step, tashkeelOK) in steps {
            let word = database.flatWords[flatIndex]
            let ayah = database.ayahs[word.ayahIndex]
            let total = ayah.groundTruthWords.count
            let label = "\(ayah.surah):\(ayah.ayahNumber) word \(word.wordIndexInAyah + 1)/\(total)"

            if lastPrintedAyahIndex != word.ayahIndex, step.kind != .extra {
                if lastPrintedAyahIndex != nil {
                    print("[ayah] advancing to \(ayah.surah):\(ayah.ayahNumber)")
                }
                lastPrintedAyahIndex = word.ayahIndex
            }

            let leniencyActive = !AyahAligner.shouldScore(wordsSinceIdentification: wordsSinceIdentification)
            if step.kind != .extra {
                wordsSinceIdentification += 1
            }
            if leniencyActive {
                continue // position-based leniency (plan's requirement 5) - never scored
            }

            let heard = step.observedIndex.flatMap { $0 < observedTashkeel.count ? observedTashkeel[$0] : nil }

            switch step.kind {
            case .match, .substitute:
                if step.kind == .substitute {
                    print("  \u{2717} \(label): expected \"\(word.groundTruth)\" got \"\(heard ?? "?")\"")
                } else if tashkeelOK == true {
                    print("  \u{2713} \(label): \"\(word.groundTruth)\"")
                } else {
                    print("  \u{2248} \(label): expected \"\(word.groundTruth)\" got \"\(heard ?? "?")\" (tashkeel differs)")
                }
            case .missed:
                print("  \u{2298} \(label): \"\(word.groundTruth)\" missed (not recited)")
            case .extra:
                print("  + extra word recited: \"\(heard ?? "?")\" (not in text)")
            }
        }

        // Advance the anchor to the last few *observed* words actually
        // consumed by these steps (skip `.missed`, which has no observed
        // counterpart) - must be the literal transcript skeleton words
        // (not the expected ground truth), since next tick's search looks
        // for this exact text reappearing in the freshly re-decoded
        // transcript.
        if let lastObserved = steps.compactMap(\.step.observedIndex).last {
            let start = max(0, lastObserved + 1 - anchorWordCount)
            anchorWords = Array(observed[start..<(lastObserved + 1)])
        }

        let snapshot = progressTracker.handleCommits(steps, database: database)
        dispatch(snapshot)
    }
}
