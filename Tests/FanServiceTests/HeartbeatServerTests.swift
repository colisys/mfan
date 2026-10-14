import XCTest
import Foundation
import Darwin
import FanCore
@testable import fanctl
@testable import MFan

final class HeartbeatServerTests: XCTestCase {
    private func startHarness(manual: Bool, path: String? = nil) async throws -> Harness {
        let harness = Harness(manual: manual, path: path)
        addTeardownBlock { await harness.cleanup() }
        harness.start()
        try await harness.waitUntilReady()
        return harness
    }

    func testTimedSetAcceptsHeartbeatAndRestoresOnTimeout() async throws {
        let harness = try await startHarness(manual: false)
        let reply = harness.begin(.init(command: "set", fan: 0, rpm: 3_000, seconds: 600))
        try await harness.waitForWrite()
        harness.clock.set(awake: 50, continuous: 50)
        let alive = try await harness.send(.init(command: "heartbeat"))
        XCTAssertTrue(alive.success)
        harness.clock.set(awake: 61, continuous: 61)
        try await harness.pingBarrier()
        XCTAssertEqual(harness.hardware.minimumRestores, 0)
        harness.clock.set(awake: 111, continuous: 111)
        let result = try await reply.value()
        XCTAssertFalse(result.success)
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
        let reply = harness.begin(.init(command: "set", fan: 0, rpm: 3_000, seconds: 30))
        try await harness.waitForWrite()
        harness.clock.set(awake: 1, continuous: 3_601)
        let result = try await reply.value()
        XCTAssertTrue(result.success)
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
        let reply = harness.begin(.init(command: "set", fan: 0, rpm: 3_000, seconds: 30))
        try await harness.waitForWrite()
        harness.clock.set(awake: 30, continuous: 30)
        let result = try await reply.value()
        XCTAssertFalse(result.success)
        XCTAssertEqual(harness.hardware.restoreAttempts, 1)

        let rejected = try await harness.send(.init(command: "set", fan: 0, rpm: 3_000, seconds: 0))
        XCTAssertFalse(rejected.success)
        XCTAssertEqual(harness.hardware.writeCount, 1)
        // Sleep must not bring the awake-time retry forward.
        harness.clock.set(awake: 34, continuous: 3_634)
        let heartbeat = try await harness.send(.init(command: "heartbeat"))
        XCTAssertTrue(heartbeat.success)
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
        let reply = harness.begin(.init(command: "set", fan: 0, rpm: 3_000, seconds: 30))
        try await harness.waitForWrite()
        harness.clock.set(awake: 30, continuous: 30)
        let result = try await reply.value()
        XCTAssertFalse(result.success)
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
        let reply = harness.begin(.init(command: "set", fan: 0, rpm: 3_000, seconds: 30))
        try await harness.waitForWrite()
        harness.clock.set(awake: 30, continuous: 30)
        let result = try await reply.value()
        XCTAssertFalse(result.success)
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
    private var writes = 0
    private var autos = 0
    private var minimums = 0
    private var attempts = 0
    private var failuresRemaining = 0
    private var restored: Double?
    init(manual: Bool) { self.manual = manual }
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    var autoRestores: Int { lock.lock(); defer { lock.unlock() }; return autos }
    var minimumRestores: Int { lock.lock(); defer { lock.unlock() }; return minimums }
    var restoreAttempts: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    var restoredMinimum: Double? { lock.lock(); defer { lock.unlock() }; return restored }
    func failRestores(_ count: Int) { lock.lock(); defer { lock.unlock() }; failuresRemaining = count }
    func fanCount() throws -> Int { 1 }
    func snapshot(index: Int) throws -> FanSnapshot {
        .init(id: 0, currentRPM: 2_000, minimumRPM: 2_000, maximumRPM: 6_000)
    }
    func supportsManualMode(fanIndex: Int) throws -> Bool { manual }
    func setManualSpeed(fanIndex: Int, rpm: Double) throws {
        lock.lock(); defer { lock.unlock() }; writes += 1
    }
    func raiseMinimumSpeed(fanIndex: Int, rpm: Double) throws -> Double {
        lock.lock(); defer { lock.unlock() }; writes += 1; return 2_000
    }
    func restoreMinimumSpeed(fanIndex: Int, rpm: Double) throws {
        lock.lock(); defer { lock.unlock() }
        try attemptRestore()
        restored = rpm
        minimums += 1
    }
    func restoreAuto(fanIndex: Int) throws {
        lock.lock(); defer { lock.unlock() }
        try attemptRestore()
        autos += 1
    }
    // Called with the hardware lock held.
    private func attemptRestore() throws {
        attempts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw NSError(domain: "injected restore failure", code: 1)
        }
    }
}

// Do not await a timed-set Task.value directly: the production client's deadline
// may be 615 seconds and cancellation does not interrupt its detached socket I/O.
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
    init(manual: Bool, path: String? = nil) {
        self.path = path ?? "/tmp/mfan-test-\(UUID().uuidString)"
        hardware = Hardware(manual: manual)
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
    func waitForWrite() async throws {
        for _ in 0..<50 {
            if hardware.writeCount > 0 {
                // A reply from the serial request loop proves pending was installed.
                try await pingBarrier()
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "test write", code: 1)
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
