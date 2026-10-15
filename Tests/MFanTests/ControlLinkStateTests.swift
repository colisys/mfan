import XCTest
@testable import MFan

final class ControlLinkStateTests: XCTestCase {
    private func state(
        connected: Bool = true, hasError: Bool = false, busy: Bool = false, heartbeatInFlight: Bool = false
    ) -> ControlLinkState {
        ControlLinkState.resolve(
            connected: connected, hasError: hasError, busy: busy, heartbeatInFlight: heartbeatInFlight
        )
    }

    func testNotConnectedIsRed() {
        XCTAssertEqual(state(connected: false), .disconnected)
    }

    func testHeartbeatFailureIsRed() {
        XCTAssertEqual(state(hasError: true), .disconnected)
    }

    func testIdleWithHealthyHeartbeatIsGreen() {
        XCTAssertEqual(state(), .healthy)
    }

    func testBusyIsYellowEvenBeforeConnecting() {
        XCTAssertEqual(state(connected: false, busy: true), .communicating)
        XCTAssertEqual(state(busy: true), .communicating)
    }

    func testHeartbeatInFlightIsYellow() {
        XCTAssertEqual(state(heartbeatInFlight: true), .communicating)
    }

    func testActivityTakesPriorityOverError() {
        XCTAssertEqual(state(hasError: true, heartbeatInFlight: true), .communicating)
    }

    // MARK: Display filter

    func testFirstStateShowsImmediately() {
        var filter = ControlLinkDisplayFilter(minimumHold: 1)
        XCTAssertNil(filter.update(raw: .healthy, now: 100))
        XCTAssertEqual(filter.displayed, .healthy)
    }

    func testShortHeartbeatStaysYellowForMinimumHold() {
        var filter = ControlLinkDisplayFilter(minimumHold: 1)
        filter.update(raw: .healthy, now: 100)
        // Heartbeat starts long after green settled: shows yellow at once.
        XCTAssertNil(filter.update(raw: .communicating, now: 110))
        XCTAssertEqual(filter.displayed, .communicating)
        // It finishes 5 ms later, but yellow must remain for the rest of the second.
        let delay = filter.update(raw: .healthy, now: 110.005)
        XCTAssertEqual(try XCTUnwrap(delay), 0.995, accuracy: 0.0001)
        XCTAssertEqual(filter.displayed, .communicating)
        XCTAssertNil(filter.update(raw: .healthy, now: 111.0))
        XCTAssertEqual(filter.displayed, .healthy)
    }

    func testBriefIntermediateStateIsSkipped() {
        var filter = ControlLinkDisplayFilter(minimumHold: 1)
        filter.update(raw: .healthy, now: 100)
        filter.update(raw: .communicating, now: 110)
        // Red appears and disappears within the hold; only the latest raw state matters.
        XCTAssertNotNil(filter.update(raw: .disconnected, now: 110.2))
        // Raw is back to what is already displayed, so nothing is pending.
        XCTAssertNil(filter.update(raw: .communicating, now: 110.4))
        XCTAssertEqual(filter.displayed, .communicating)
    }

    func testNoChangeNeedsNoTimer() {
        var filter = ControlLinkDisplayFilter(minimumHold: 1)
        filter.update(raw: .healthy, now: 100)
        XCTAssertNil(filter.update(raw: .healthy, now: 100.1))
    }
}
