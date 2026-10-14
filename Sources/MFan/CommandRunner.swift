import Foundation

/// Serializes whole authorization/control sessions without blocking the UI or SMC queue.
final class CommandRunner {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MFan.commands"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    func submit(script: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.addOperation {
            let result = Result { try Self.run(script: script) }
            completion(result)
        }
    }

    static func authorizationScript(cli: URL, arguments: [String], background: Bool = false, backgroundLogPath: String? = nil) -> String {
        let commandParts = [cli.path] + arguments
        let command = commandParts.map {
            "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        // Redirect all inherited descriptors before backgrounding so the
        // authorization shell can return without waiting for the service.
        let suffix: String
        if background {
            let log = backgroundLogPath.map {
                "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
            } ?? "/dev/null"
            suffix = " </dev/null >>\(log) 2>&1 &"
        } else {
            suffix = ""
        }
        return "do shell script \"\(escaped)\(suffix)\" with administrator privileges"
    }

    static func run(script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain before waiting: a full pipe must not stall the child process.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommandError.failed(process.terminationStatus, detail)
        }
    }
}

private enum CommandError: LocalizedError {
    case failed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .failed(_, let detail) where detail.contains("(-128)"):
            return "管理员授权已取消；请检查当前风扇状态。"
        case .failed(let status, let detail):
            return "授权或 fanctl 执行失败（\(status)）：\(detail.isEmpty ? "osascript 未提供错误详情" : detail)"
        }
    }
}
