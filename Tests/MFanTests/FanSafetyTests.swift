import FanCore
import XCTest
@testable import MFan

final class FanSafetyTests: XCTestCase {
    private func fan(current: Double, target: Double? = nil, max: Double = 6000) -> FanSnapshot {
        FanSnapshot(id: 0, currentRPM: current, minimumRPM: 1200, maximumRPM: max, targetRPM: target)
    }

    func testWarnsAtExactlyEightyFivePercentWhenUnlimited() {
        XCTAssertTrue(FanSafety.showsHighSpeedWarning(fan: fan(current: 5100), heldUnlimited: true))
        XCTAssertFalse(FanSafety.showsHighSpeedWarning(fan: fan(current: 5099), heldUnlimited: true))
    }

    func testNoWarningWhenNotHeldUnlimited() {
        XCTAssertFalse(FanSafety.showsHighSpeedWarning(fan: fan(current: 6000), heldUnlimited: false))
    }

    func testHighTargetWarnsBeforeFanSpinsUp() {
        XCTAssertTrue(FanSafety.showsHighSpeedWarning(fan: fan(current: 2000, target: 5400), heldUnlimited: true))
    }

    func testInvalidMaximumNeverWarns() {
        XCTAssertFalse(FanSafety.showsHighSpeedWarning(fan: fan(current: 5000, max: 0), heldUnlimited: true))
        XCTAssertFalse(FanSafety.showsHighSpeedWarning(fan: fan(current: 5000, max: .infinity), heldUnlimited: true))
    }
}
