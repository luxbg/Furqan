import XCTest
@testable import Quran

final class PhonemeAlignDPTests: XCTestCase {
    func testIdenticalStringsHaveZeroDistance() {
        let a = "بسم".phonemeScalars
        let b = "بسم".phonemeScalars
        let result = PhonemeAlignDP.editDistanceWithBackpointers(a, b)
        XCTAssertEqual(result.dp[a.count][b.count], 0)
    }

    func testSingleSubstitutionHasDistanceOne() {
        let a = "بست".phonemeScalars
        let b = "بسم".phonemeScalars
        let result = PhonemeAlignDP.editDistanceWithBackpointers(a, b)
        XCTAssertEqual(result.dp[a.count][b.count], 1)
    }

    func testTracebackReconstructsMatchPath() {
        let a = "بسم".phonemeScalars
        let b = "بسم".phonemeScalars
        let result = PhonemeAlignDP.editDistanceWithBackpointers(a, b)
        let path = PhonemeAlignDP.traceback(result.bp, a.count, b.count)
        XCTAssertEqual(path.count, 3)
        for step in path {
            XCTAssertEqual(step.op, .match)
        }
    }

    func testTracebackHandlesInsertionAndDeletion() {
        // a has an extra leading char not in b -- insertA; b has an extra
        // trailing char not in a -- deleteA.
        let a = "xبسم".phonemeScalars
        let b = "بسمy".phonemeScalars
        let result = PhonemeAlignDP.editDistanceWithBackpointers(a, b)
        let path = PhonemeAlignDP.traceback(result.bp, a.count, b.count)
        XCTAssertEqual(path.first?.op, .insertA)
        XCTAssertEqual(path.last?.op, .deleteA)
    }

    func testArgminFindsFirstMinimum() {
        XCTAssertEqual(PhonemeAlignDP.argmin([5, 3, 1, 4, 1]), 2)
    }

    func testArgminSingleElement() {
        XCTAssertEqual(PhonemeAlignDP.argmin([7]), 0)
    }
}
