import XCTest
import Foundation
import Darwin
import FanCore
@testable import fanctl
@testable import MFan

final class HeartbeatServerTests: XCTestCase {
    private func startHarness(manual: Bool, path: String? = nil, fanCount: Int = 1) async throws -> Harness {
        let harness = Harness(manual: manual, path: path, fanCount: fanCount)
        addTeardownBlock { await harness.cleanup() }
        harness.start()
        try await harness.waitUntilReady()
        return harness
    }

    func testTimedSetAcceptsHeartbeatAndRestoresOnTimeout() async throws {
        let harness = try await startHarness(manual: false)
        let result = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 600))
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.message?.contains("3000") == true)
        XCTAssertTrue(result.message?.contains("600") == true)
        XCTAssertEqual(result.minimumRPMs?[0], 2_000)
        harness.clock.set(awake: 50, continuous: 50)
        let alive = try await harness.send(.init(command: "heartbeat"))
        XCTAssertTrue(alive.success)
        harness.clock.set(awake: 61, continuous: 61)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.minimumRestores, 0)
        harness.clock.set(awake: 111, continuous: 111)
        await fulfillment(of: [harness.stopped], timeout: 3)
        XCTAssertEqual(harness.hardware.restoredMinimum, 2_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.path))
    }

    func testSleepPreservesUnlimitedControlThenWatchdogRestores() async throws {
        let harness = try await startHarness(manual: true)
        let result = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 0))
        XCTAssertTrue(result.success)
        harness.clock.set(awake: 59, continuous: 3_659)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.autoRestores, 0)
        // Ping must not renew the watchdog. Wake grace ends at awake=89.
        harness.clock.set(awake: 90, continuous: 3_690)
        await fulfillment(of: [harness.stopped], timeout: 3)
        XCTAssertEqual(harness.hardware.autoRestores, 1)
    }

    func testTimedDeadlineIncludesSleepAndShutdownRestoresUnlimited() async throws {
        let harness = try await startHarness(manual: false)
        let result = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 30))
        XCTAssertTrue(result.success)
        XCTAssertEqual(harness.hardware.minimumRestores, 0)
        harness.clock.set(awake: 1, continuous: 3_601)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.restoredMinimum, 2_000)
        let set = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 0))
        XCTAssertTrue(set.success)
        let shutdown = try await harness.send(.init(command: "shutdown"))
        XCTAssertTrue(shutdown.success)
        await fulfillment(of: [harness.stopped], timeout: 3)
        XCTAssertEqual(harness.hardware.minimumRestores, 2)
    }

    func testFailedTimedRestoreRetriesOnAwakeTimeAndRejectsSet() async throws {
        let harness = try await startHarness(manual: false)
        harness.hardware.failRestores(1)
        let result = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 30))
        XCTAssertTrue(result.success)
        harness.clock.set(awake: 30, continuous: 30)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.restoreAttempts, 1)

        let rejected = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 0))
        XCTAssertFalse(rejected.success)
        XCTAssertEqual(harness.hardware.writeCount, 1)
        // Sleep must not bring the awake-time retry forward.
        harness.clock.set(awake: 34, continuous: 3_634)
        let heartbeat = try await harness.send(.init(command: "heartbeat"))
        XCTAssertFalse(heartbeat.success)
        XCTAssertTrue(heartbeat.error?.contains("风扇 0") == true)
        XCTAssertTrue(heartbeat.error?.contains("等待重试") == true)
        XCTAssertTrue(heartbeat.error?.contains("injected restore failure") == true)
        XCTAssertEqual(heartbeat.minimumRPMs?[0], 2_000)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.restoreAttempts, 1)
        harness.clock.set(awake: 35, continuous: 3_635)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.restoreAttempts, 2)
        XCTAssertEqual(harness.hardware.restoredMinimum, 2_000)

        // Successful recovery removes both the retry and the set restriction.
        harness.clock.set(awake: 40, continuous: 3_640)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.restoreAttempts, 2)
        let set = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 0))
        XCTAssertTrue(set.success)
    }

    func testAutoCanResolveFailedTimedRestoreBeforeRetry() async throws {
        let harness = try await startHarness(manual: true)
        harness.hardware.failRestores(1)
        let result = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 30))
        XCTAssertTrue(result.success)
        harness.clock.set(awake: 30, continuous: 30)
        try await harness.pingBarrier()
        let auto = try await harness.send(.init(command: "auto", fan: 0))
        XCTAssertTrue(auto.success)
        harness.clock.set(awake: 35, continuous: 35)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.restoreAttempts, 2)
        let set = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 0))
        XCTAssertTrue(set.success)
    }

    func testPersistentRestoreFailureStillExitsOnWatchdog() async throws {
        let harness = try await startHarness(manual: false)
        harness.hardware.failRestores(.max)
        let result = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 30))
        XCTAssertTrue(result.success)
        harness.clock.set(awake: 30, continuous: 30)
        try await harness.pingBarrier()
        harness.clock.set(awake: 35, continuous: 35)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.restoreAttempts, 2)
        // Failed shutdown remains available, reports failure, and keeps recovery state.
        let shutdown = try await harness.send(.init(command: "shutdown"))
        XCTAssertFalse(shutdown.success)
        XCTAssertEqual(harness.hardware.restoreAttempts, 3)
        harness.clock.set(awake: 61, continuous: 61)
        await fulfillment(of: [harness.stopped], timeout: 3)
        // One watchdog attempt plus one final deferred attempt, even after failures.
        XCTAssertEqual(harness.hardware.restoreAttempts, 5)
        XCTAssertEqual(harness.hardware.minimumRestores, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.path))
    }

    func testSixHundredSecondSetAllowsImmediateAuto() async throws {
        for manual in [false, true] {
            let harness = try await startHarness(manual: manual)
            let set = try await harness.send(.init(command: "set", fan: 0, rpm: 4_000, seconds: 600))
            XCTAssertTrue(set.success)
            let auto = try await harness.send(.init(command: "auto", fan: 0))
            XCTAssertTrue(auto.success)
            XCTAssertTrue(auto.minimumRPMs?.isEmpty == true)
            XCTAssertEqual(harness.hardware.restoreAttempts, 1)
            harness.clock.set(awake: 1, continuous: 601)
            try await harness.pingBarrier()
            XCTAssertEqual(harness.hardware.restoreAttempts, 1)
        }
    }

    func testLoweringTemporaryMinimumPreservesOriginalInEveryResponse() async throws {
        let harness = try await startHarness(manual: false)
        let first = try await harness.send(.init(command: "set", fan: 0, rpm: 4_000, seconds: 600))
        XCTAssertTrue(first.success)
        let lower = try await harness.send(.init(command: "set", fan: 0, rpm: 2_500, seconds: 600))
        XCTAssertTrue(lower.success)
        XCTAssertEqual(lower.minimumRPMs?[0], 2_000)
        XCTAssertEqual(try harness.hardware.snapshot(index: 0).minimumRPM, 2_500)
        XCTAssertEqual(harness.hardware.raiseCount, 1)
        XCTAssertEqual(harness.hardware.writtenTargets(), [4_000, 2_500])
        let ping = try await harness.send(.init(command: "ping"))
        XCTAssertEqual(ping.minimumRPMs?[0], 2_000)
        let heartbeat = try await harness.send(.init(command: "heartbeat"))
        XCTAssertEqual(heartbeat.minimumRPMs?[0], 2_000)
        let invalid = try await harness.send(.init(command: "unknown"))
        XCTAssertFalse(invalid.success)
        XCTAssertEqual(invalid.minimumRPMs?[0], 2_000)
        let auto = try await harness.send(.init(command: "auto", fan: 0))
        XCTAssertTrue(auto.success)
        XCTAssertTrue(auto.minimumRPMs?.isEmpty == true)
        XCTAssertEqual(harness.hardware.writtenTargets(), [4_000, 2_500, 2_000])
    }

    func testNewTimedSetReplacesOnlyItsDeadline() async throws {
        let harness = try await startHarness(manual: false)
        let first = try await harness.send(.init(command: "set", fan: 0, rpm: 4_000, seconds: 30))
        XCTAssertTrue(first.success)
        harness.clock.set(awake: 10, continuous: 10)
        let second = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 30))
        XCTAssertTrue(second.success)
        harness.clock.set(awake: 30, continuous: 30)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.writtenTargets(), [4_000, 3_000])
        harness.clock.set(awake: 40, continuous: 40)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.writtenTargets(), [4_000, 3_000, 2_000])
    }

    func testReplacementCanShortenDeadline() async throws {
        let harness = try await startHarness(manual: true)
        let first = try await harness.send(.init(command: "set", fan: 0, rpm: 4_000, seconds: 600))
        XCTAssertTrue(first.success)
        let shorter = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 30))
        XCTAssertTrue(shorter.success)
        harness.clock.set(awake: 30, continuous: 30)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.autoRestores, 1)
        harness.clock.set(awake: 31, continuous: 601)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.autoRestores, 1)
    }

    func testAutoAllClearsEveryTimedFan() async throws {
        let harness = try await startHarness(manual: false, fanCount: 2)
        for fan in 0..<2 {
            let set = try await harness.send(.init(command: "set", fan: fan, rpm: 3_000, seconds: 600))
            XCTAssertTrue(set.success)
        }
        let auto = try await harness.send(.init(command: "auto"))
        XCTAssertTrue(auto.success)
        XCTAssertTrue(auto.minimumRPMs?.isEmpty == true)
        XCTAssertEqual(harness.hardware.minimumRestores, 2)
        harness.clock.set(awake: 1, continuous: 601)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.minimumRestores, 2)
    }

    func testUnlimitedSetCancelsPreviousDeadline() async throws {
        let harness = try await startHarness(manual: false)
        let first = try await harness.send(.init(command: "set", fan: 0, rpm: 4_000, seconds: 30))
        XCTAssertTrue(first.success)
        let unlimited = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 0))
        XCTAssertTrue(unlimited.success)
        XCTAssertTrue(unlimited.message?.contains("不限时") == true)
        harness.clock.set(awake: 30, continuous: 30)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.writtenTargets(), [4_000, 3_000])
        let auto = try await harness.send(.init(command: "auto", fan: 0))
        XCTAssertTrue(auto.success)
        XCTAssertEqual(harness.hardware.restoredMinimum, 2_000)
    }

    func testMultipleFansHaveIndependentDeadlinesAndAuto() async throws {
        let harness = try await startHarness(manual: false, fanCount: 2)
        let first = try await harness.send(.init(command: "set", fan: 0, rpm: 4_000, seconds: 30))
        XCTAssertTrue(first.success)
        let second = try await harness.send(.init(command: "set", fan: 1, rpm: 3_500, seconds: 40))
        XCTAssertTrue(second.success)
        XCTAssertEqual(second.minimumRPMs, [0: 2_000, 1: 2_000])
        let auto = try await harness.send(.init(command: "auto", fan: 0))
        XCTAssertTrue(auto.success)
        XCTAssertEqual(auto.minimumRPMs, [1: 2_000])
        let replacement = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 0))
        XCTAssertTrue(replacement.success)
        harness.clock.set(awake: 30, continuous: 30)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.writtenTargets(fan: 0), [4_000, 2_000, 3_000])
        XCTAssertEqual(harness.hardware.writtenTargets(fan: 1), [3_500])
        harness.clock.set(awake: 40, continuous: 40)
        let heartbeat = try await harness.send(.init(command: "heartbeat"))
        XCTAssertTrue(heartbeat.success)
        XCTAssertEqual(heartbeat.minimumRPMs, [0: 2_000])
        XCTAssertEqual(harness.hardware.writtenTargets(fan: 1), [3_500, 2_000])
        XCTAssertEqual(try harness.hardware.snapshot(index: 0).minimumRPM, 3_000)
    }

    func testRequestsClampWithoutUsingCurrentRPM() async throws {
        for manual in [false, true] {
            let harness = try await startHarness(manual: manual)
            harness.hardware.configure(current: 7_000)
            for (requested, target) in [(3_000.0, 3_000.0), (9_000, 6_000), (-100, 2_000)] {
                let response = try await harness.send(.init(command: "set", fan: 0, rpm: requested, seconds: 0))
                XCTAssertTrue(response.success)
                XCTAssertTrue(response.message?.contains("\(target)") == true)
            }
            XCTAssertEqual(harness.hardware.writtenTargets(), [3_000, 6_000, 2_000])
            if !manual { XCTAssertEqual(harness.hardware.raiseCount, 1) }
        }
    }

    func testInvalidHardwareBoundsAreRejectedBeforeWriting() async throws {
        let harness = try await startHarness(manual: false)
        let bounds: [(Double, Double)] = [(.nan, 6_000), (2_000, .infinity),
                                          (-1, 6_000), (2_000, 1_000), (0, 0)]
        for (minimum, maximum) in bounds {
            harness.hardware.configure(minimum: minimum, maximum: maximum)
            let response = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 0))
            XCTAssertFalse(response.success)
            XCTAssertTrue(response.minimumRPMs?.isEmpty == true)
        }
        XCTAssertEqual(harness.hardware.writeCount, 0)
    }

    func testFailedReplacementPreservesOriginalMinimumAndDeadline() async throws {
        let harness = try await startHarness(manual: false)
        let first = try await harness.send(.init(command: "set", fan: 0, rpm: 4_000, seconds: 30))
        XCTAssertTrue(first.success)
        harness.clock.set(awake: 10, continuous: 10)
        harness.hardware.failWrites(1)
        let failed = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 0))
        XCTAssertFalse(failed.success)
        XCTAssertEqual(failed.minimumRPMs?[0], 2_000)
        harness.clock.set(awake: 15, continuous: 15)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.writtenTargets(), [4_000, 3_000])
        harness.clock.set(awake: 30, continuous: 30)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.writtenTargets(), [4_000, 3_000, 2_000])
    }

    func testPartialFirstWriteSchedulesRecoveryWithoutInstallingDeadline() async throws {
        for manual in [false, true] {
            let harness = try await startHarness(manual: manual)
            harness.hardware.failWrites(1)
            let failed = try await harness.send(.init(command: "set", fan: 0, rpm: 4_000, seconds: 600))
            XCTAssertFalse(failed.success)
            let heartbeat = try await harness.send(.init(command: "heartbeat"))
            XCTAssertFalse(heartbeat.success)
            XCTAssertTrue(heartbeat.error?.contains("injected partial write failure") == true)
            harness.clock.set(awake: 5, continuous: 5)
            let recovered = try await harness.send(.init(command: "heartbeat"))
            XCTAssertTrue(recovered.success)
            XCTAssertTrue(recovered.minimumRPMs?.isEmpty == true)
            XCTAssertEqual(harness.hardware.restoreAttempts, 1)
            harness.clock.set(awake: 6, continuous: 601)
            try await harness.pingBarrier()
            XCTAssertEqual(harness.hardware.restoreAttempts, 1)
            if !manual { XCTAssertEqual(harness.hardware.restoredMinimum, 2_000) }
        }
    }

    func testFailedUnlimitedReplacementRetriesOriginalMinimum() async throws {
        let harness = try await startHarness(manual: false)
        let first = try await harness.send(.init(command: "set", fan: 0, rpm: 4_000, seconds: 0))
        XCTAssertTrue(first.success)
        harness.hardware.failWrites(1)
        let failed = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 600))
        XCTAssertFalse(failed.success)
        XCTAssertEqual(failed.minimumRPMs?[0], 2_000)
        harness.clock.set(awake: 5, continuous: 5)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.writtenTargets(), [4_000, 3_000, 2_000])
    }

    func testFailedAutoCanBeRetriedImmediatelyAndCancelsDeadline() async throws {
        let harness = try await startHarness(manual: false)
        let set = try await harness.send(.init(command: "set", fan: 0, rpm: 4_000, seconds: 600))
        XCTAssertTrue(set.success)
        harness.hardware.failRestores(1)
        let failed = try await harness.send(.init(command: "auto", fan: 0))
        XCTAssertFalse(failed.success)
        XCTAssertEqual(failed.minimumRPMs?[0], 2_000)
        let heartbeat = try await harness.send(.init(command: "heartbeat"))
        XCTAssertFalse(heartbeat.success)
        let auto = try await harness.send(.init(command: "auto", fan: 0))
        XCTAssertTrue(auto.success)
        harness.clock.set(awake: 5, continuous: 605)
        let recovered = try await harness.send(.init(command: "heartbeat"))
        XCTAssertTrue(recovered.success)
        XCTAssertEqual(harness.hardware.restoreAttempts, 2)
    }

    func testFailedRecoveryDoesNotBlockAnotherFanAndHeartbeatStillRenewsLease() async throws {
        let harness = try await startHarness(manual: true, fanCount: 2)
        let first = try await harness.send(.init(command: "set", fan: 0, rpm: 4_000, seconds: 30))
        XCTAssertTrue(first.success)
        harness.hardware.failRestores(.max)
        harness.clock.set(awake: 30, continuous: 30)
        let failedHeartbeat = try await harness.send(.init(command: "heartbeat"))
        XCTAssertFalse(failedHeartbeat.success)
        let other = try await harness.send(.init(command: "set", fan: 1, rpm: 3_000, seconds: 0))
        XCTAssertTrue(other.success)
        let lower = try await harness.send(.init(command: "set", fan: 1, rpm: 2_500, seconds: 0))
        XCTAssertTrue(lower.success)
        XCTAssertEqual(harness.hardware.writtenTargets(fan: 1), [3_000, 2_500])
        harness.clock.set(awake: 61, continuous: 61)
        try await harness.pingBarrier()
        // The failed heartbeat at 30 renewed the lease beyond the initial 60.
        harness.clock.set(awake: 91, continuous: 91)
        await fulfillment(of: [harness.stopped], timeout: 3)
    }

    func testExistingSocketIsNotRemovedOnBindFailure() async throws {
        let harness = try await startHarness(manual: false)
        let before = try socketInfo(harness.path)
        let other = PrivilegedFanServer(socketPath: harness.path, client: Hardware(manual: false), clock: harness.clock.now)
        XCTAssertThrowsError(try other.run())
        let after = try socketInfo(harness.path)
        XCTAssertEqual(before.st_dev, after.st_dev)
        XCTAssertEqual(before.st_ino, after.st_ino)
        try await harness.pingBarrier()
    }

    func testReplacedSocketIsNotRemovedOnExit() async throws {
        let original = try await startHarness(manual: false)
        let movedPath = original.path + ".old"
        try FileManager.default.moveItem(atPath: original.path, toPath: movedPath)
        addTeardownBlock {
            await original.cleanup()
            try? FileManager.default.removeItem(atPath: movedPath)
        }
        // Keep the old node alive to prevent inode reuse, then bind a new service.
        let replacement = try await startHarness(manual: false, path: original.path)
        let before = try socketInfo(replacement.path)
        original.clock.set(awake: 61, continuous: 61)
        await fulfillment(of: [original.stopped], timeout: 3)
        let after = try socketInfo(replacement.path)
        XCTAssertEqual(before.st_dev, after.st_dev)
        XCTAssertEqual(before.st_ino, after.st_ino)
        try await replacement.pingBarrier()
    }

    private func socketInfo(_ path: String) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else {
            throw NSError(domain: "test socket identity", code: 1)
        }
        return info
    }
}

private final class Clock {
    private let lock = NSLock()
    private var sample = ServiceClockSample(awake: 0, continuous: 0)
    func now() -> ServiceClockSample { lock.lock(); defer { lock.unlock() }; return sample }
    func set(awake: Double, continuous: Double) {
        lock.lock(); defer { lock.unlock() }
        sample = .init(awake: awake, continuous: continuous)
    }
}

private final class Hardware: ServiceFanHardware {
    let manual: Bool
    private let lock = NSLock()
    private var snapshots: [FanSnapshot]
    private var targets: [Int: [Double]] = [:]
    private var raises = 0
    private var writes = 0
    private var autos = 0
    private var minimums = 0
    private var attempts = 0
    private var failuresRemaining = 0
    private var writeFailuresRemaining = 0
    private var restored: Double?
    init(manual: Bool, fanCount: Int = 1) {
        self.manual = manual
        snapshots = (0..<fanCount).map {
            .init(id: $0, currentRPM: 2_000, minimumRPM: 2_000, maximumRPM: 6_000)
        }
    }
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    var raiseCount: Int { lock.lock(); defer { lock.unlock() }; return raises }
    var autoRestores: Int { lock.lock(); defer { lock.unlock() }; return autos }
    var minimumRestores: Int { lock.lock(); defer { lock.unlock() }; return minimums }
    var restoreAttempts: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    var restoredMinimum: Double? { lock.lock(); defer { lock.unlock() }; return restored }
    func writtenTargets(fan: Int = 0) -> [Double] {
        lock.lock(); defer { lock.unlock() }; return targets[fan, default: []]
    }
    func configure(fan: Int = 0, current: Double = 2_000, minimum: Double = 2_000, maximum: Double = 6_000) {
        lock.lock(); defer { lock.unlock() }
        snapshots[fan] = .init(id: fan, currentRPM: current, minimumRPM: minimum, maximumRPM: maximum)
    }
    func failRestores(_ count: Int) { lock.lock(); defer { lock.unlock() }; failuresRemaining = count }
    func failWrites(_ count: Int) { lock.lock(); defer { lock.unlock() }; writeFailuresRemaining = count }
    func fanCount() throws -> Int { lock.lock(); defer { lock.unlock() }; return snapshots.count }
    func snapshot(index: Int) throws -> FanSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard snapshots.indices.contains(index) else { throw NSError(domain: "invalid fan", code: 1) }
        return snapshots[index]
    }
    func supportsManualMode(fanIndex: Int) throws -> Bool { manual }
    func setManualSpeed(fanIndex: Int, rpm: Double) throws {
        lock.lock(); defer { lock.unlock() }
        snapshots[fanIndex].targetRPM = rpm
        try recordWrite(fan: fanIndex, rpm: rpm)
    }
    func raiseMinimumSpeed(fanIndex: Int, rpm: Double) throws -> Double {
        lock.lock(); defer { lock.unlock() }
        raises += 1
        let original = snapshots[fanIndex].minimumRPM
        let target = max(original, rpm)
        snapshots[fanIndex].minimumRPM = target
        try recordWrite(fan: fanIndex, rpm: target)
        return original
    }
    func restoreMinimumSpeed(fanIndex: Int, rpm: Double) throws {
        lock.lock(); defer { lock.unlock() }
        try attemptRestore()
        snapshots[fanIndex].minimumRPM = rpm
        try recordWrite(fan: fanIndex, rpm: rpm)
        restored = rpm
        minimums += 1
    }
    func restoreAuto(fanIndex: Int) throws {
        lock.lock(); defer { lock.unlock() }
        try attemptRestore()
        snapshots[fanIndex].targetRPM = nil
        autos += 1
    }
    // Fail after mutation to simulate a hardware write that only partly succeeded.
    private func recordWrite(fan: Int, rpm: Double) throws {
        writes += 1
        targets[fan, default: []].append(rpm)
        if writeFailuresRemaining > 0 {
            writeFailuresRemaining -= 1
            throw NSError(domain: "test hardware", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "injected partial write failure"])
        }
    }
    // Called with the hardware lock held.
    private func attemptRestore() throws {
        attempts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw NSError(domain: "test hardware", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "injected restore failure"])
        }
    }
}

// Bound every response wait so a regression to blocking timed sets fails quickly,
// even if cancellation does not interrupt the client's detached socket I/O.
private final class Reply {
    private let lock = NSLock()
    private var result: Result<FanControlResponse, Error>?
    init(control: PrivilegedControlClient, request: FanControlRequest) {
        Task {
            do { finish(.success(try await control.send(request))) }
            catch { finish(.failure(error)) }
        }
    }
    private func finish(_ result: Result<FanControlResponse, Error>) {
        lock.lock(); defer { lock.unlock() }; self.result = result
    }
    private func current() -> Result<FanControlResponse, Error>? {
        lock.lock(); defer { lock.unlock() }; return result
    }
    func value() async throws -> FanControlResponse {
        for _ in 0..<150 {
            if let result = current() { return try result.get() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "test response timeout", code: 1)
    }
}

private final class Harness {
    let path: String
    let clock = Clock()
    let hardware: Hardware
    let stopped = XCTestExpectation(description: "watchdog server stopped")
    private let lock = NSLock()
    private var didStop = false
    var control: PrivilegedControlClient { .init(socketPath: path) }
    init(manual: Bool, path: String? = nil, fanCount: Int = 1) {
        self.path = path ?? "/tmp/mfan-test-\(UUID().uuidString)"
        hardware = Hardware(manual: manual, fanCount: fanCount)
    }
    private func markStopped() { lock.lock(); defer { lock.unlock() }; didStop = true }
    private func isStopped() -> Bool { lock.lock(); defer { lock.unlock() }; return didStop }
    func start() {
        let server = PrivilegedFanServer(socketPath: path, client: hardware, clock: clock.now)
        DispatchQueue.global().async {
            defer { self.markStopped(); self.stopped.fulfill() }
            do { try server.run() } catch { XCTFail("\(error)") }
        }
    }
    func begin(_ request: FanControlRequest) -> Reply { Reply(control: control, request: request) }
    func send(_ request: FanControlRequest) async throws -> FanControlResponse {
        try await begin(request).value()
    }
    func pingBarrier() async throws {
        let response = try await send(.init(command: "ping"))
        guard response.success else { throw NSError(domain: "test ping barrier", code: 1) }
    }
    func waitUntilReady() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            do { try await pingBarrier(); return } catch {
                if isStopped() { throw error }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "test startup", code: 1)
    }

    func cleanup() async {
        guard !isStopped() else { return }
        hardware.failRestores(0)
        for attempt in 0..<150 {
            if isStopped() { return }
            // Advance again if an unobserved sleep or in-flight heartbeat grants
            // a fresh lease during teardown. Equal deltas do not simulate sleep.
            if attempt % 25 == 0 {
                let now = clock.now()
                clock.set(awake: now.awake + 120, continuous: now.continuous + 120)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("test server did not stop during cleanup: \(path)")
    }
}
