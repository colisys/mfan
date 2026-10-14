import XCTest
@testable import FanCore

final class HeartbeatLeaseTests: XCTestCase {
    private func time(_ awake: Double, sleep: Double = 0) -> ServiceClockSample {
        .init(awake: awake, continuous: awake + sleep)
    }

    func testNoHeartbeatExpiresAfterSixtyAwakeSeconds() {
        var lease = HeartbeatLease(now: time(0))
        XCTAssertFalse(lease.isExpired(now: time(59)))
        XCTAssertTrue(lease.isExpired(now: time(60)))
    }

    func testHeartbeatRenewsButObservingDoesNot() {
        var lease = HeartbeatLease(now: time(0))
        lease.receiveHeartbeat(now: time(50))
        XCTAssertFalse(lease.isExpired(now: time(100)))
        XCTAssertTrue(lease.isExpired(now: time(110)))
    }

    func testLongSleepDoesNotConsumeLeaseAndWakeHasGrace() {
        var lease = HeartbeatLease(now: time(0))
        XCTAssertFalse(lease.isExpired(now: time(59)))
        XCTAssertFalse(lease.isExpired(now: time(59, sleep: 28_800)))
        XCTAssertFalse(lease.isExpired(now: time(88, sleep: 28_800)))
        XCTAssertTrue(lease.isExpired(now: time(89, sleep: 28_800)))
    }

    func testWakeHeartbeatRestoresNormalLease() {
        var lease = HeartbeatLease(now: time(0))
        XCTAssertFalse(lease.isExpired(now: time(59, sleep: 3_600)))
        lease.receiveHeartbeat(now: time(65, sleep: 3_600))
        XCTAssertFalse(lease.isExpired(now: time(124, sleep: 3_600)))
        XCTAssertTrue(lease.isExpired(now: time(125, sleep: 3_600)))
    }

    func testSuspendedGUIWithoutSystemSleepStillExpires() {
        var lease = HeartbeatLease(now: time(0))
        XCTAssertTrue(lease.isExpired(now: time(120)))
    }
}
