import FanCore
import XCTest
@testable import MFan

final class FanSafetyTests: XCTestCase {
    private func fan(current: Double, target: Double? = nil, max: Double = 6000) -> FanSnapshot {
        FanSnapshot(id: 0, currentRPM: current, minimumRPM: 1200, maximumRPM: max, targetRPM: target)
    }

    func testWarnsAtExactlySeventyFivePercentWhenUnlimited() {
        XCTAssertTrue(FanSafety.showsHighSpeedWarning(fan: fan(current: 4500), heldUnlimited: true))
        XCTAssertFalse(FanSafety.showsHighSpeedWarning(fan: fan(current: 4499), heldUnlimited: true))
    }

    func testNoWarningWhenNotHeldUnlimited() {
        XCTAssertFalse(FanSafety.showsHighSpeedWarning(fan: fan(current: 6000), heldUnlimited: false))
    }

    func testHighTargetWarnsBeforeFanSpinsUp() {
        XCTAssertTrue(FanSafety.showsHighSpeedWarning(fan: fan(current: 2000, target: 5000), heldUnlimited: true))
    }

    func testInvalidMaximumNeverWarns() {
        XCTAssertFalse(FanSafety.showsHighSpeedWarning(fan: fan(current: 5000, max: 0), heldUnlimited: true))
        XCTAssertFalse(FanSafety.showsHighSpeedWarning(fan: fan(current: 5000, max: .infinity), heldUnlimited: true))
    }
}
