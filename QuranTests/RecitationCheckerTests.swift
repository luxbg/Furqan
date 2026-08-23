import XCTest
@testable import Quran

/// Integration tests against the real bundled phoneme corpus - port of the
/// intent of `qrc`'s `tests/test_pipeline.py` + `tests/test_backtracking.py`.
final class RecitationCheckerTests: XCTestCase {
    static let corpus = try! PhonemeCorpus.loadFromBundle()
    var corpus: PhonemeCorpus { Self.corpus }

    private func tokensFor(_ text: String) -> [PhonemeToken] {
        text.phonemeScalars.enumerated().map { PhonemeToken(symbol: String($0.element), timeS: Float($0.offset)) }
    }

    private func ayahWords(_ surah: Int, _ ayah: Int) -> [String] {
        let entry = corpus.ayahsInOrder.first { $0.ref.surah == surah && $0.ref.ayah == ayah }!
        return entry.words
    }

    private func firstGlobalIdx(_ surah: Int, _ ayah: Int) -> Int {
        corpus.globalWords.first { $0.surah == surah && $0.ayah == ayah && $0.localWordIdx == 0 }!.globalWordIdx
    }

    /// 32:8's last corpus phoneme-word used to be one indivisible unit
    /// covering multiple written words - it must settle as independent
    /// per-word results through the full pipeline (localization included).
    func testMergedAyahVerifiesAsIndependentWordsThroughFullPipeline() {
        let ayahEntries = corpus.globalWords.filter { $0.surah == 32 && $0.ayah == 8 }
        XCTAssertGreaterThan(ayahEntries.count, 1, "sanity: 32:8 should be split into multiple real words in the loaded corpus")

        var results: [PhonemeWordCheckResult] = []
        let checker = RecitationChecker(corpus: corpus, settings: .default, onWordResult: { results.append($0) })
        checker.feedTokens(tokensFor(ayahEntries.map(\.phonemeText).joined()))
        checker.finish()

        let recited = results.filter { $0.surah == 32 && $0.ayah == 8 }
        XCTAssertEqual(recited.count, ayahEntries.count)
        XCTAssertTrue(recited.allSatisfy { $0.status == .match })
        XCTAssertEqual(recited.map(\.wordIndex), Array(0..<ayahEntries.count))
    }

    /// The words consumed while localizing must not be silently dropped and
    /// reported as never-recited once localization completes.
    func testWordsUsedToLocalizeAreNotReportedAsDeleted() {
        let words = ayahWords(112, 1) // Al-Ikhlas: قُل هُوَ للَااهُ ءَحَدڇ
        var results: [PhonemeWordCheckResult] = []
        let checker = RecitationChecker(corpus: corpus, settings: .default, onWordResult: { results.append($0) })
        checker.feedTokens(tokensFor(words.joined()))
        checker.finish()

        let recited = results.filter { $0.surah == 112 && $0.ayah == 1 }
        XCTAssertEqual(recited.count, words.count)
        XCTAssertTrue(recited.allSatisfy { $0.status == .match })
        XCTAssertEqual(recited.map(\.actualPhonemes), words)
    }

    func testLocatorRejectsMatchBeforeFloor() {
        let floorIdx = firstGlobalIdx(112, 2)
        let locator = IncrementalAyahLocator(corpus: corpus, settings: .default)
        locator.minGlobalWordIdx = floorIdx

        var result: PhonemeLocalizeResult?
        for w in ayahWords(112, 1) { // before the floor
            result = locator.addChars(w)
        }

        XCTAssertNil(result)
        XCTAssertEqual(locator.lastRejection, .beforeFloor)
    }

    func testLocatorRejectsMatchBeyondCeiling() {
        let floorIdx = firstGlobalIdx(112, 1)
        let ceilingIdx = firstGlobalIdx(112, 2) - 1
        let locator = IncrementalAyahLocator(corpus: corpus, settings: .default)
        locator.minGlobalWordIdx = floorIdx
        locator.maxGlobalWordIdx = ceilingIdx

        var result: PhonemeLocalizeResult?
        for w in ayahWords(112, 3) { // past the ceiling
            result = locator.addChars(w)
        }

        XCTAssertNil(result)
        XCTAssertEqual(locator.lastRejection, .beyondCeiling)
    }

    func testLocatorAcceptsMatchExactlyAtFloor() {
        let floorIdx = firstGlobalIdx(112, 2)
        let locator = IncrementalAyahLocator(corpus: corpus, settings: .default)
        locator.minGlobalWordIdx = floorIdx

        var result: PhonemeLocalizeResult?
        for w in ayahWords(112, 2) {
            result = locator.addChars(w)
            if result != nil { break }
        }

        XCTAssertEqual(result?.globalWordIdx, floorIdx)
    }

    func testPipelineEndToEndBacktrackScenario() {
        var statuses: [String] = []
        let checker = RecitationChecker(corpus: corpus, settings: .default, onWordResult: { _ in }, onStatus: { statuses.append($0) })

        checker.feedTokens(tokensFor(ayahWords(112, 2).joined()))
        checker.finish()
        XCTAssertEqual(checker.sessionStartGlobalWordIdx, firstGlobalIdx(112, 2))

        // Force relocalization so backtracking can be tested without
        // waiting on the aligner's confidence to organically collapse.
        checker.locator.reset()

        // Ayah 1 is before the session's start -- must fail with a clear reason.
        checker.feedTokens(tokensFor(ayahWords(112, 1).joined()))
        XCTAssertFalse(statuses.contains { $0.hasPrefix("localized: surah 112 ayah 1,") })
        XCTAssertTrue(statuses.contains { $0.contains("can't go back before surah 112 ayah 2") })

        // Ayah 2 (exactly the session start) must succeed.
        checker.locator.reset()
        checker.feedTokens(tokensFor(ayahWords(112, 2).joined()))
        XCTAssertTrue(statuses.contains { $0.hasPrefix("localized: surah 112 ayah 2,") })
    }

    func testBacktrackReroutesWithoutReportingAFalseMismatch() {
        var results: [PhonemeWordCheckResult] = []
        let checker = RecitationChecker(corpus: corpus, settings: .default, onWordResult: { results.append($0) })

        checker.feedTokens(tokensFor((ayahWords(112, 1) + ayahWords(112, 2) + ayahWords(112, 3)).joined()))
        XCTAssertTrue(results.allSatisfy { $0.status == .match }, "\(results)")

        // Go back and recite 112:1 again without an explicit relocalize
        // signal -- the aligner is still expecting 112:4 next.
        checker.feedTokens(tokensFor(ayahWords(112, 1).joined()))
        checker.finish()

        XCTAssertFalse(results.contains { $0.status == .mismatch && $0.surah == 112 && $0.ayah == 4 })
        let ayah1Results = results.filter { $0.surah == 112 && $0.ayah == 1 }
        XCTAssertEqual(ayah1Results.count, 8)
        XCTAssertTrue(ayah1Results.allSatisfy { $0.status == .match })
    }
}
