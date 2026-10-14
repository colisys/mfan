import Foundation
import Darwin
import FanCore

final class PrivilegedControlClient: Sendable {
    private let socketPath: String
    private static let maximumFrameBytes = 64 * 1024

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func ping() async -> Bool {
        do {
            return try await send(FanControlRequest(command: "ping")).success
        } catch {
            return false
        }
    }

    func send(_ request: FanControlRequest) async throws -> FanControlResponse {
        try await Task.detached(priority: .userInitiated) {
            try self.sendSynchronously(request)
        }.value
    }

    static func responseTimeout(for request: FanControlRequest) -> TimeInterval {
        switch request.command {
        case "ping", "heartbeat": return 3

        default: return 15
        }
    }

    private func sendSynchronously(_ request: FanControlRequest) throws -> FanControlResponse {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + Self.responseTimeout(for: request)
        let sendDeadline = min(deadline, started + 3)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw controlError("无法创建控制连接") }
        defer { close(fd) }

        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            throw controlError("无法配置控制连接")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathLength = socketPath.utf8.count
        guard pathLength < MemoryLayout.size(ofValue: address.sun_path), !socketPath.utf8.contains(0) else {
            throw controlError("控制 socket 路径无效或过长")
        }
        socketPath.withCString { path in
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                let source = UnsafeRawBufferPointer(start: path, count: pathLength)
                bytes.copyBytes(from: source)
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)! + pathLength + 1)
        address.sun_len = UInt8(length)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, length)
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EALREADY || errno == EINTR else {
                throw controlError("控制服务未连接")
            }
            try wait(fd, events: Int16(POLLOUT), deadline: sendDeadline)
            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0, socketError == 0 else {
                throw controlError("控制服务未连接")
            }
        }

        // Each concurrent request owns its socket and codecs (including a deferred timed set).
        var data = try JSONEncoder().encode(request)
        data.append(10)
        guard data.count <= Self.maximumFrameBytes else { throw controlError("控制请求过大") }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                try wait(fd, events: Int16(POLLOUT), deadline: sendDeadline)
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
                if count > 0 {
                    offset += count
                } else if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                    continue
                } else {
                    throw controlError("发送控制请求失败；请求可能已送达")
                }
            }
        }

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while responseData.count < Self.maximumFrameBytes {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let count = recv(fd, &buffer, min(buffer.count, Self.maximumFrameBytes - responseData.count), 0)
            if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            guard count > 0 else { throw controlError("控制服务响应不完整；请求结果未知") }
            if let newline = buffer[..<count].firstIndex(of: 10) {
                responseData.append(contentsOf: buffer[..<newline])
                return try JSONDecoder().decode(FanControlResponse.self, from: responseData)
            }
            responseData.append(contentsOf: buffer[..<count])
        }
        throw controlError("控制服务响应超过大小限制")
    }

    private func wait(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw controlError("控制连接超时；请求结果可能未知") }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(min(ceil(remaining * 1000), Double(Int32.max)))
            let result = poll(&descriptor, 1, milliseconds)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw controlError("等待控制连接失败") }
            if result == 0 { continue }
            guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw controlError("控制连接已关闭") }
            // Let send/recv report errors or drain bytes when POLLHUP accompanies readiness.
            if descriptor.revents & (events | Int16(POLLERR | POLLHUP)) != 0 { return }
        }
    }

    private func controlError(_ message: String) -> NSError {
        NSError(domain: "MFan.Control", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
