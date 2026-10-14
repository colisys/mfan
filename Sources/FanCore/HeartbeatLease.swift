import Foundation
import Darwin

/// Uses clocks unaffected by wall-clock changes. mach_absolute_time excludes
/// sleep on macOS; mach_continuous_time includes it, allowing wake detection.
public struct ServiceClockSample {
    public let awake: TimeInterval
    public let continuous: TimeInterval

    public init(awake: TimeInterval, continuous: TimeInterval) {
        self.awake = awake
        self.continuous = continuous
    }

    public static func now() -> ServiceClockSample {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let scale = Double(info.numer) / Double(info.denom) / 1_000_000_000
        return ServiceClockSample(awake: Double(mach_absolute_time()) * scale,
                                  continuous: Double(mach_continuous_time()) * scale)
    }
}

public struct HeartbeatLease {
    public static let timeout: TimeInterval = 60
    public static let wakeGrace: TimeInterval = 30
    private var lastSample: ServiceClockSample
    private var deadline: TimeInterval

    public init(now: ServiceClockSample) {
        lastSample = now
        deadline = now.awake + Self.timeout
    }

    /// Only the explicit heartbeat command renews the lease, not connections,
    /// ping probes, control requests or malformed traffic.
    public mutating func receiveHeartbeat(now: ServiceClockSample) {
        observe(now)
        deadline = now.awake + Self.timeout
    }

    public mutating func isExpired(now: ServiceClockSample) -> Bool {
        observe(now)
        return now.awake >= deadline
    }

    private mutating func observe(_ now: ServiceClockSample) {
        let sleepDuration = (now.continuous - lastSample.continuous) - (now.awake - lastSample.awake)
        if sleepDuration > 1 {
            deadline = max(deadline, now.awake + Self.wakeGrace)
        }
        lastSample = now
    }
}
