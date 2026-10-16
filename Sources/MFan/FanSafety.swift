import FanCore

enum FanSafety {
    /// Fraction of the fan's maximum RPM at which the warning starts.
    static let highSpeedFraction = 0.75

    static let highSpeedWarning = "请勿让风扇长时间不限时高速运作，以免损坏机械结构"

    /// True when the fan is held without a time limit and runs (or is told to run)
    /// at 75% or more of its maximum. The higher of current and target is used, so
    /// the warning shows as soon as a high target is set and stays until it has spun down.
    static func showsHighSpeedWarning(fan: FanSnapshot, heldUnlimited: Bool) -> Bool {
        guard heldUnlimited, fan.maximumRPM.isFinite, fan.maximumRPM > 0 else { return false }
        let rpm = max(fan.currentRPM, fan.targetRPM ?? 0)
        return rpm >= fan.maximumRPM * highSpeedFraction
    }
}
