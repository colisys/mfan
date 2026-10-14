import Darwin
import FanCore
import Foundation
import XCTest
@testable import MFan

final class PrivilegedControlClientTests: XCTestCase {
    func testTimeoutBudgets() {
        XCTAssertEqual(PrivilegedControlClient.responseTimeout(for: FanControlRequest(command: "heartbeat")), 3)
        XCTAssertEqual(PrivilegedControlClient.responseTimeout(for: FanControlRequest(command: "ping")), 3)
        XCTAssertEqual(PrivilegedControlClient.responseTimeout(for: FanControlRequest(command: "set", seconds: 30)), 15)
        XCTAssertEqual(PrivilegedControlClient.responseTimeout(for: FanControlRequest(command: "set", seconds: 600)), 15)
        XCTAssertEqual(PrivilegedControlClient.responseTimeout(for: FanControlRequest(command: "set", seconds: 0)), 15)
    }

    func testPingRemainsPingAndHeartbeatIsExplicit() async throws {
        let server = try SocketFixture()
        let handled = expectation(description: "Both requests")
        handled.expectedFulfillmentCount = 2
        let worker = Task.detached {
            defer { server.closeListener() }
            for expected in ["ping", "heartbeat"] {
                let fd = try server.acceptClient()
                defer { Darwin.close(fd) }
                let request = try SocketFixture.readRequest(fd)
                XCTAssertEqual(request.command, expected)
                try SocketFixture.write(fd, Data("{\"success\":true}\n".utf8))
                handled.fulfill()
            }
        }
        let client = PrivilegedControlClient(socketPath: server.path)
        let ready = await client.ping()
        XCTAssertTrue(ready)
        let response = try await client.send(FanControlRequest(command: "heartbeat"))
        XCTAssertTrue(response.success)
        try await worker.value
        await fulfillment(of: [handled], timeout: 5)
    }

    func testHeartbeatCompletesWhileTimedSetResponseIsDeferred() async throws {
        let server = try SocketFixture()
        let setReceived = expectation(description: "Timed set received")
        let worker = Task.detached {
            defer { server.closeListener() }
            let setFD = try server.acceptClient()
            defer { Darwin.close(setFD) }
            let set = try SocketFixture.readRequest(setFD)
            XCTAssertEqual(set.command, "set")
            setReceived.fulfill()
            let heartbeatFD = try server.acceptClient()
            defer { Darwin.close(heartbeatFD) }
            XCTAssertEqual(try SocketFixture.readRequest(heartbeatFD).command, "heartbeat")
            try SocketFixture.write(heartbeatFD, Data("{\"success\":true,\"message\":\"alive\"}\n".utf8))
            // The timed command remains pending until after the heartbeat response.
            try await Task.sleep(nanoseconds: 200_000_000)
            try SocketFixture.write(setFD, Data("{\"success\":true,\"message\":\"restored\"}\n".utf8))
        }
        let client = PrivilegedControlClient(socketPath: server.path)
        let setTask = Task { try await client.send(FanControlRequest(command: "set", seconds: 30)) }
        await fulfillment(of: [setReceived], timeout: 5)
        let heartbeat = try await client.send(FanControlRequest(command: "heartbeat"))
        XCTAssertEqual(heartbeat.message, "alive")
        let set = try await setTask.value
        XCTAssertEqual(set.message, "restored")
        try await worker.value
    }

    func testFragmentedResponseAndFirstFrameOnly() async throws {
        let response = try await exchange { fd in
            try SocketFixture.write(fd, Data("{\"success\":".utf8))
            Thread.sleep(forTimeInterval: 0.03)
            try SocketFixture.write(fd, Data("true,\"message\":\"ok\"}\nignored trailing data".utf8))
        }
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.message, "ok")
    }

    func testTruncatedFrameIsRejected() async throws {
        do {
            _ = try await exchange { fd in
                try SocketFixture.write(fd, Data("{\"success\":true}".utf8))
            }
            XCTFail("EOF without a newline must not count as a complete response")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("响应不完整"))
        }
    }

    func testOversizedFrameIsRejected() async throws {
        do {
            _ = try await exchange { fd in
                try SocketFixture.write(fd, Data(repeating: 32, count: 64 * 1024))
            }
            XCTFail("An unterminated oversized frame must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("大小限制"))
        }
    }

    func testClosedPeerFailsWithoutReplayingRequest() async throws {
        let server = try SocketFixture()
        let worker = Task.detached {
            defer { server.closeListener() }
            let fd = try server.acceptClient()
            _ = try SocketFixture.readRequest(fd)
            Darwin.close(fd)
            var descriptor = pollfd(fd: server.listener, events: Int16(POLLIN), revents: 0)
            XCTAssertEqual(poll(&descriptor, 1, 300), 0, "Client must not reconnect/replay after losing the response")
        }
        do {
            _ = try await PrivilegedControlClient(socketPath: server.path).send(FanControlRequest(command: "set", seconds: 0))
            XCTFail("Lost response must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("结果未知"))
        }
        try await worker.value
    }

    func testHeartbeatTimeoutIsNotExtendedByTrickledBytes() async throws {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await exchange { fd in
                for _ in 0..<14 {
                    try SocketFixture.write(fd, Data([32]))
                    Thread.sleep(forTimeInterval: 0.2)
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            XCTFail("Heartbeat must time out without a complete frame")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("超时"))
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 4.5)
        }
    }

    private func exchange(_ respond: @escaping @Sendable (Int32) throws -> Void) async throws -> FanControlResponse {
        let server = try SocketFixture()
        let worker = Task.detached {
            defer { server.closeListener() }
            let fd = try server.acceptClient()
            defer { Darwin.close(fd) }
            _ = try SocketFixture.readRequest(fd)
            try respond(fd)
        }
        let result: Result<FanControlResponse, Error>
        do {
            result = .success(try await PrivilegedControlClient(socketPath: server.path).send(FanControlRequest(command: "heartbeat")))
        } catch {
            result = .failure(error)
        }
        try await worker.value
        return try result.get()
    }
}

// Only local mock sockets are used; no authorization, GUI launch, or SMC access.
private final class SocketFixture: @unchecked Sendable {
    let path = "/tmp/mfan-test-\(UUID().uuidString)"
    let listener: Int32

    init() throws {
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Self.failure("socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        path.withCString { path in
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                bytes.copyBytes(from: UnsafeRawBufferPointer(start: path, count: strlen(path) + 1))
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, length) }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            Darwin.close(listener)
            unlink(path)
            throw Self.failure("bind/listen")
        }
    }

    deinit { unlink(path) }

    func closeListener() { Darwin.close(listener) }

    func acceptClient() throws -> Int32 {
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 5000) > 0 else { throw Self.failure("accept timeout") }
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { throw Self.failure("accept") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func readRequest(_ fd: Int32) throws -> FanControlRequest {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 64 * 1024 {
            guard recv(fd, &byte, 1, 0) == 1 else { throw failure("read request") }
            if byte == 10 { return try JSONDecoder().decode(FanControlRequest.self, from: data) }
            data.append(byte)
        }
        throw failure("request too large")
    }

    static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
                guard count > 0 else { throw failure("write response") }
                offset += count
            }
        }
    }

    static func failure(_ operation: String) -> NSError {
        NSError(domain: "MFan.SocketFixture", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: operation])
    }
}
