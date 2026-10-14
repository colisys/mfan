import Foundation
import FanCore
import Darwin

protocol ServiceFanHardware: AnyObject {
    func fanCount() throws -> Int
    func snapshot(index: Int) throws -> FanSnapshot
    func supportsManualMode(fanIndex: Int) throws -> Bool
    func setManualSpeed(fanIndex: Int, rpm: Double) throws
    func raiseMinimumSpeed(fanIndex: Int, rpm: Double) throws -> Double
    func restoreMinimumSpeed(fanIndex: Int, rpm: Double) throws
    func restoreAuto(fanIndex: Int) throws
}

extension SMCClient: ServiceFanHardware {}

final class PrivilegedFanServer {
    private let socketPath: String
    private let client: ServiceFanHardware
    private let clock: () -> ServiceClockSample
    private var serverFD: Int32 = -1
    private var socketIdentity: (device: dev_t, inode: ino_t)?
    private var lease = HeartbeatLease(now: .now())
    private var peers: [Int32: Peer] = [:]
    private var restores: [Int: Restore] = [:]
    // Recovery retries own no reply FD and use awake time, independently of timed sets.
    private var restoreRetries: [Int: TimeInterval] = [:]
    private var pending: PendingSet?

    private struct Peer {
        var data = Data()
        let deadline: TimeInterval
    }
    private enum Restore {
        case automatic
        case minimum(Double)
    }
    private struct PendingSet {
        let fan: Int
        let fd: Int32
        let deadline: TimeInterval
    }

    init(socketPath: String) throws {
        self.socketPath = socketPath
        client = try SMCClient()
        clock = ServiceClockSample.now
    }

    init(socketPath: String, client: ServiceFanHardware, clock: @escaping () -> ServiceClockSample) {
        self.socketPath = socketPath
        self.client = client
        self.clock = clock
    }

    func run() throws {
        try prepareSocket()
        lease = HeartbeatLease(now: clock())
        defer {
            // Always attempt remaining recovery on exit, including poll failures.
            // Watchdog/shutdown failures get a final attempt here and are logged.
            for error in restoreAll() { log(error) }
            if let pending { close(pending.fd) }
            for fd in peers.keys { close(fd) }
            close(serverFD)
            cleanupSocket()
        }

        while true {
            let now = clock()
            if lease.isExpired(now: now) {
                log("面板心跳超时（60 秒清醒时间）；恢复风扇并退出")
                let errors = restoreAll()
                errors.forEach(log)
                if let operation = pending {
                    respond(.init(success: false, error: "面板心跳超时，已尝试恢复风扇。" + errors.joined(separator: "; ")), fd: operation.fd)
                    pending = nil
                }
                return
            }
            if let operation = pending, now.continuous >= operation.deadline {
                do {
                    try restoreFan(operation.fan)
                    respond(.init(success: true, message: "限时会话已结束，风扇 \(operation.fan) 已恢复"), fd: operation.fd)
                } catch {
                    restoreRetries[operation.fan] = clock().awake + 5
                    log("限时恢复失败：\(error.localizedDescription)")
                    respond(.init(success: false, error: error.localizedDescription), fd: operation.fd)
                }
                pending = nil
            }
            for fan in Array(restoreRetries.keys).sorted() where restoreRetries[fan]! <= now.awake {
                do {
                    try restoreFan(fan)
                } catch {
                    restoreRetries[fan] = clock().awake + 5
                    log("风扇 \(fan) 恢复重试失败：\(error.localizedDescription)")
                }
            }
            for fd in Array(peers.keys) where peers[fd]!.deadline <= now.awake {
                close(fd)
                peers.removeValue(forKey: fd)
            }

            var descriptors = [pollfd(fd: serverFD, events: Int16(POLLIN), revents: 0)]
            descriptors += peers.keys.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&descriptors, nfds_t(descriptors.count), 250)
            if ready < 0 {
                if errno == EINTR { continue }
                throw serviceError("poll 失败：\(String(cString: strerror(errno)))")
            }
            if descriptors[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                throw serviceError("监听 socket 已失效")
            }
            if descriptors[0].revents & Int16(POLLIN) != 0 {
                let fd = accept(serverFD, nil, nil)
                if fd >= 0 {
                    if peers.count >= 32 {
                        close(fd)
                    } else {
                        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
                        var enabled: Int32 = 1
                        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                        peers[fd] = Peer(deadline: clock().awake + 3)
                    }
                }
            }
            for descriptor in descriptors.dropFirst() where descriptor.revents != 0 {
                if try readPeer(descriptor.fd) { return }
            }
        }
    }

    /// Incremental, bounded reads keep a silent/partial client from blocking the
    /// watchdog. Timed sets keep only their reply FD, not the request loop.
    private func readPeer(_ fd: Int32) throws -> Bool {
        guard var peer = peers[fd] else { return false }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = recv(fd, &buffer, buffer.count, 0)
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return false }
        guard count > 0 else {
            close(fd)
            peers.removeValue(forKey: fd)
            return false
        }
        peer.data.append(contentsOf: buffer.prefix(count))
        guard peer.data.count <= 4096 else {
            peers.removeValue(forKey: fd)
            respond(.init(success: false, error: "请求过长"), fd: fd)
            return false
        }
        guard peer.data.contains(10) else {
            peers[fd] = peer
            return false
        }
        peers.removeValue(forKey: fd)
        do {
            let request = try JSONDecoder().decode(FanControlRequest.self, from: peer.data)
            switch request.command {
            case "heartbeat":
                lease.receiveHeartbeat(now: clock())
                respond(.init(success: true, message: "alive"), fd: fd)
            case "ping":
                respond(.init(success: true, message: "ready"), fd: fd)
            case "shutdown":
                let errors = restoreAll()
                errors.forEach(log)
                if let operation = pending {
                    respond(.init(success: false, error: "应用退出，会话结束；已尝试恢复风扇"), fd: operation.fd)
                    pending = nil
                }
                respond(.init(success: errors.isEmpty, message: errors.isEmpty ? "stopped" : nil,
                              error: errors.isEmpty ? nil : errors.joined(separator: "; ")), fd: fd)
                // Do not claim shutdown succeeded if restoring hardware failed.
                return errors.isEmpty
            case "auto":
                guard pending == nil else { throw serviceError("限时会话仍在执行") }
                if let fan = request.fan {
                    try restoreFan(fan)
                } else {
                    var errors: [String] = []
                    for fan in 0..<(try client.fanCount()) {
                        do { try restoreFan(fan) } catch { errors.append(error.localizedDescription) }
                    }
                    if !errors.isEmpty { throw serviceError(errors.joined(separator: "; ")) }
                }
                respond(.init(success: true, message: "恢复请求已完成"), fd: fd)
            case "set":
                guard pending == nil else { throw serviceError("限时会话仍在执行") }
                guard restoreRetries.isEmpty else { throw serviceError("风扇恢复尚未完成，请先恢复或稍后重试") }
                guard let fan = request.fan, let rpm = request.rpm, let seconds = request.seconds,
                      seconds == 0 || (30...600).contains(seconds) else { throw serviceError("set 参数无效") }
                try setFan(fan, rpm: rpm)
                if seconds == 0 {
                    respond(.init(success: true, message: "风扇 \(fan) 已设定为不限时；心跳失联后恢复"), fd: fd)
                } else {
                    // Continuous time includes sleep: an expired timed control
                    // is restored on wake, but sleep alone never expires heartbeat.
                    pending = PendingSet(fan: fan, fd: fd, deadline: clock().continuous + Double(seconds))
                }
            default:
                throw serviceError("不支持的命令")
            }
        } catch {
            respond(.init(success: false, error: error.localizedDescription), fd: fd)
        }
        return false
    }

    private func setFan(_ fan: Int, rpm: Double) throws {
        let snapshot = try client.snapshot(index: fan)
        guard rpm.isFinite, rpm >= snapshot.minimumRPM, rpm <= snapshot.maximumRPM else {
            throw serviceError("RPM 超出风扇允许范围")
        }
        let target = max(rpm, snapshot.currentRPM)
        guard target <= snapshot.maximumRPM else { throw serviceError("当前转速超过允许范围") }
        // Record recovery before the first write (manual mode may be written
        // successfully even if the following target-speed write fails).
        if try client.supportsManualMode(fanIndex: fan) {
            if restores[fan] == nil { restores[fan] = .automatic }
            try client.setManualSpeed(fanIndex: fan, rpm: target)
        } else {
            if restores[fan] == nil { restores[fan] = .minimum(snapshot.minimumRPM) }
            _ = try client.raiseMinimumSpeed(fanIndex: fan, rpm: target)
        }
    }

    private func restoreFan(_ fan: Int) throws {
        switch restores[fan] {
        case .minimum(let original): try client.restoreMinimumSpeed(fanIndex: fan, rpm: original)
        default: try client.restoreAuto(fanIndex: fan)
        }
        restores.removeValue(forKey: fan)
        restoreRetries.removeValue(forKey: fan)
    }

    private func restoreAll() -> [String] {
        var errors: [String] = []
        for fan in Array(restores.keys).sorted() {
            do { try restoreFan(fan) } catch {
                errors.append("风扇 \(fan) 恢复失败：\(error.localizedDescription)")
            }
        }
        return errors
    }

    private func prepareSocket() throws {
        var address = sockaddr_un()
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw serviceError("控制 socket 路径过长（最多 103 字节）")
        }
        // Never unlink an endpoint which may belong to an already running service.
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { throw serviceError("无法创建控制服务 socket") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        socketPath.withCString { path in
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                bytes.copyBytes(from: UnsafeRawBufferPointer(start: path, count: socketPath.utf8.count + 1))
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(serverFD)
            throw serviceError("无法绑定 socket：\(String(cString: strerror(errno)))")
        }
        var info = stat()
        guard lstat(socketPath, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else {
            close(serverFD)
            throw serviceError("无法确认控制 socket 身份")
        }
        socketIdentity = (info.st_dev, info.st_ino)
        // Existing local-session transport permissions; deployment authentication
        // is separate from the heartbeat watchdog.
        guard chmod(socketPath, S_IRUSR | S_IWUSR | S_IROTH | S_IWOTH) == 0,
              listen(serverFD, 8) == 0, fcntl(serverFD, F_SETFL, O_NONBLOCK) == 0 else {
            close(serverFD)
            cleanupSocket()
            throw serviceError("无法监听控制服务 socket")
        }
    }

    private func cleanupSocket() {
        guard let identity = socketIdentity else { return }
        defer { socketIdentity = nil }
        var info = stat()
        // The production sticky /tmp directory protects the root-owned endpoint
        // against replacement by other users; never remove a different node.
        guard lstat(socketPath, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_dev == identity.device, info.st_ino == identity.inode else { return }
        unlink(socketPath)
    }

    private func respond(_ response: FanControlResponse, fd: Int32) {
        defer { close(fd) }
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(10)
        // Replies are small, but handle short writes without ever blocking the watchdog.
        data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return }
                sent += count
            }
        }
    }

    private func log(_ message: String) { fputs("fanctl: \(message)\n", stderr) }
    private func serviceError(_ message: String) -> NSError {
        NSError(domain: "MFan.PrivilegedServer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
