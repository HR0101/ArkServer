import MediaServerKit
import XCTest

final class PINSecurityTests: XCTestCase {
  func testEqualPinsMatch() {
    XCTAssertTrue(PINSecurity.constantTimeEquals("123456", "123456"))
  }

  func testDifferentPinsReject() {
    XCTAssertFalse(PINSecurity.constantTimeEquals("123456", "123457"))
  }

  func testDifferentLengthRejects() {
    XCTAssertFalse(PINSecurity.constantTimeEquals("123456", "12345"))
  }

  func testEmptyEqualsEmpty() {
    XCTAssertTrue(PINSecurity.constantTimeEquals("", ""))
  }

  func testNoLockoutUnderThreshold() {
    XCTAssertNil(PINSecurity.lockoutDelay(failCount: 4))
  }

  func testLockoutEscalation() {
    XCTAssertEqual(PINSecurity.lockoutDelay(failCount: 5), 30)
    XCTAssertEqual(PINSecurity.lockoutDelay(failCount: 6), 60)
    XCTAssertEqual(PINSecurity.lockoutDelay(failCount: 7), 120)
  }

  func testLockoutCapsAtOneHour() {
    XCTAssertEqual(PINSecurity.lockoutDelay(failCount: 100), 3600)
  }
}

final class PINLockoutTrackerTests: XCTestCase {

    private final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    }

    private func makeTracker(_ clock: Clock) -> PINLockoutTracker {
        PINLockoutTracker(maxAttempts: 5, now: { clock.date })
    }

    private func failFiveTimes(_ tracker: PINLockoutTracker, ip: String = "10.0.0.1") {
        for _ in 0..<5 { XCTAssertFalse(tracker.verify(pin: "000000", expected: "123456", ip: ip)) }
    }

    func testCorrectPinSucceedsAndWrongPinFails() {
        let tracker = makeTracker(Clock())
        XCTAssertTrue(tracker.verify(pin: "123456", expected: "123456", ip: "10.0.0.1"))
        XCTAssertFalse(tracker.verify(pin: "999999", expected: "123456", ip: "10.0.0.1"))
    }

    func testNotLockedBeforeThreshold() {
        let tracker = makeTracker(Clock())
        for _ in 0..<4 { _ = tracker.verify(pin: "000000", expected: "123456", ip: "10.0.0.1") }
        XCTAssertFalse(tracker.isLockedOut("10.0.0.1"))
        XCTAssertTrue(tracker.verify(pin: "123456", expected: "123456", ip: "10.0.0.1"))
    }

    func testLocksOutAfterConsecutiveFailures() {
        let tracker = makeTracker(Clock())
        failFiveTimes(tracker)
        XCTAssertTrue(tracker.isLockedOut("10.0.0.1"))
    }

    func testCorrectPinIsRejectedWhileLockedOut() {
        let tracker = makeTracker(Clock())
        failFiveTimes(tracker)
        XCTAssertFalse(tracker.verify(pin: "123456", expected: "123456", ip: "10.0.0.1"))
    }

    func testLockoutExpiresAfterDelay() {
        let clock = Clock()
        let tracker = makeTracker(clock)
        failFiveTimes(tracker)
        clock.advance(29)
        XCTAssertTrue(tracker.isLockedOut("10.0.0.1"))
        clock.advance(2)
        XCTAssertFalse(tracker.isLockedOut("10.0.0.1"))
        XCTAssertTrue(tracker.verify(pin: "123456", expected: "123456", ip: "10.0.0.1"))
    }

    func testLockoutBacksOffExponentially() {
        let clock = Clock()
        let tracker = makeTracker(clock)
        failFiveTimes(tracker)
        clock.advance(31)
        // 6回目の失敗は 60 秒ロック
        XCTAssertFalse(tracker.verify(pin: "000000", expected: "123456", ip: "10.0.0.1"))
        clock.advance(59)
        XCTAssertTrue(tracker.isLockedOut("10.0.0.1"))
        clock.advance(2)
        XCTAssertFalse(tracker.isLockedOut("10.0.0.1"))
    }

    func testSuccessResetsFailureCounter() {
        let tracker = makeTracker(Clock())
        for _ in 0..<4 { _ = tracker.verify(pin: "000000", expected: "123456", ip: "10.0.0.1") }
        XCTAssertTrue(tracker.verify(pin: "123456", expected: "123456", ip: "10.0.0.1"))
        // カウンターがリセットされているので、さらに4回失敗してもロックされない
        for _ in 0..<4 { _ = tracker.verify(pin: "000000", expected: "123456", ip: "10.0.0.1") }
        XCTAssertFalse(tracker.isLockedOut("10.0.0.1"))
    }

    func testLockoutIsPerIP() {
        let tracker = makeTracker(Clock())
        failFiveTimes(tracker, ip: "10.0.0.1")
        XCTAssertTrue(tracker.isLockedOut("10.0.0.1"))
        XCTAssertFalse(tracker.isLockedOut("10.0.0.2"))
        XCTAssertTrue(tracker.verify(pin: "123456", expected: "123456", ip: "10.0.0.2"))
    }
}
