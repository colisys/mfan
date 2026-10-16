import Foundation
import IOKit

public struct FanSnapshot: Codable, Identifiable, Equatable {
    public var id: Int
    public var currentRPM: Double
    public var minimumRPM: Double
    public var maximumRPM: Double
    /// 当前目标转速（读不到为 nil）
    public var targetRPM: Double?
    /// 是否手动模式（读不到为 nil）
    public var isManual: Bool?

    public init(id: Int, currentRPM: Double, minimumRPM: Double, maximumRPM: Double,
                targetRPM: Double? = nil, isManual: Bool? = nil) {
        self.id = id
        self.currentRPM = currentRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.targetRPM = targetRPM
        self.isManual = isManual
    }
}

public struct TemperatureSnapshot: Codable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let celsius: Double

    public init(id: String, name: String, celsius: Double) {
        self.id = id
        self.name = name
        self.celsius = celsius
    }
}

public enum FanError: LocalizedError {
    case smcOpenFailed(Int32)
    case keyNotFound(String)
    case readFailed(String, String)
    case writeFailed(String, UInt8)
    case invalidFanIndex(Int)
    case noFansDetected
    case manualModeUnavailable(Int)

    public var errorDescription: String? {
        switch self {
        case .smcOpenFailed(let code):
            return "无法连接 AppleSMC（IOServiceOpen 失败，kern 返回 0x\(String(code, radix: 16))）。"
        case .keyNotFound(let key):
            return "SMC 中未找到键 \(key)（该机型可能没有风扇，或接口不兼容）。"
        case .readFailed(let key, let detail):
            return "读取 SMC 键 \(key) 失败：\(detail)"
        case .writeFailed(let key, let result):
            return "SMC 拒绝写入键 \(key)（SMC result=0x\(String(result, radix: 16))）。这不是 IOKit 权限错误；该键可能不存在或不支持写入。"
        case .invalidFanIndex(let i):
            return "风扇编号无效：\(i)。"
        case .noFansDetected:
            return "未检测到风扇（FNum = 0）。"
        case .manualModeUnavailable(let index):
            return "风扇 \(index) 不提供 F\(index)Md 手动模式键，不能使用固定 RPM 手动模式。"
        }
    }
}

/// 与 AppleSMC 的底层通信。SMC 接口未被 Apple 公开，本实现为实验性质。
public final class SMCClient {
    private var conn: io_connect_t = 0
    private let queue = DispatchQueue(label: "mfan.smclient")

    public init() throws {
        var iterator: io_iterator_t = 0
        var kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator)
        guard kr == KERN_SUCCESS else { throw FanError.smcOpenFailed(kr) }
        defer { IOObjectRelease(iterator) }
        let device = IOIteratorNext(iterator)
        guard device != 0 else { throw FanError.smcOpenFailed(KERN_FAILURE) }
        defer { IOObjectRelease(device) }
        kr = IOServiceOpen(device, mach_task_self_, 0, &conn)
        guard kr == KERN_SUCCESS else { throw FanError.smcOpenFailed(kr) }
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    // MARK: - Public API

    public func fanCount() throws -> Int {
        let n = try readRaw(key: "FNum") ?? Data()
        guard n.count >= 1 else { throw FanError.keyNotFound("FNum") }
        let count = Int(n[0])
        guard count > 0 else { throw FanError.noFansDetected }
        return count
    }

    public func fans() throws -> [FanSnapshot] {
        // Read FNum once per poll. Calling snapshot(index:) here used to read
        // the same key once for every fan and made each refresh needlessly slow.
        let count = try fanCount()
        return try (0..<count).map { try snapshot(index: $0, fanCount: count) }
    }

    public func snapshot(index: Int) throws -> FanSnapshot {
        let count = try fanCount()
        return try snapshot(index: index, fanCount: count)
    }

    private func snapshot(index: Int, fanCount: Int) throws -> FanSnapshot {
        guard index >= 0, index < fanCount else { throw FanError.invalidFanIndex(index) }
        let current = try readFanSpeed("F\(index)Ac") ?? 0
        // Some Intel SMC revisions expose fan limits using different types.
        let min = try readFanSpeed("F\(index)Mn") ?? 0
        let max = try readFanSpeed("F\(index)Mx") ?? 0
        let target = try readFanSpeed("F\(index)Tg")
        let manual = try readFlag("F\(index)Md")
        return FanSnapshot(id: index, currentRPM: current, minimumRPM: min,
                           maximumRPM: max, targetRPM: target, isManual: manual)
    }

    public func supportsManualMode(fanIndex: Int) throws -> Bool {
        let count = try fanCount()
        guard fanIndex >= 0, fanIndex < count else { throw FanError.invalidFanIndex(fanIndex) }
        return try readKey("F\(fanIndex)Md") != nil
    }

    /// 将风扇切到手动模式并设定目标转速。
    public func setManualSpeed(fanIndex: Int, rpm: Double) throws {
        let count = try fanCount()
        guard fanIndex >= 0, fanIndex < count else { throw FanError.invalidFanIndex(fanIndex) }
        guard try readKey("F\(fanIndex)Md") != nil else {
            throw FanError.manualModeUnavailable(fanIndex)
        }
        try writeFlag("F\(fanIndex)Md", value: 1)
        try writeFanSpeed("F\(fanIndex)Tg", rpm: rpm)
    }

    /// Raise the minimum speed on models without a manual-mode key, returning the prior value.
    public func raiseMinimumSpeed(fanIndex: Int, rpm: Double) throws -> Double {
        let snapshot = try self.snapshot(index: fanIndex)
        guard rpm >= snapshot.minimumRPM, rpm <= snapshot.maximumRPM else {
            throw FanError.invalidFanIndex(fanIndex)
        }
        try writeFanSpeed("F\(fanIndex)Mn", rpm: rpm)
        return snapshot.minimumRPM
    }

    public func restoreMinimumSpeed(fanIndex: Int, rpm: Double) throws {
        let count = try fanCount()
        guard fanIndex >= 0, fanIndex < count else { throw FanError.invalidFanIndex(fanIndex) }
        try writeFanSpeed("F\(fanIndex)Mn", rpm: rpm)
    }

    /// Restore automatic mode when a mode key exists. Models without one are already system-managed.
    public func restoreAuto(fanIndex: Int) throws {
        let count = try fanCount()
        guard fanIndex >= 0, fanIndex < count else { throw FanError.invalidFanIndex(fanIndex) }
        guard try readKey("F\(fanIndex)Md") != nil else { return }
        try writeFlag("F\(fanIndex)Md", value: 0)
    }

    /// Read common internal temperature sensors. Missing keys are normal because
    /// sensor names differ between Intel Mac generations.
    public func temperatures() throws -> [TemperatureSnapshot] {
        // Sensor inventories vary widely. One unsupported or transient key must
        // not make the whole fan poll fail.
        temperatureCandidates.compactMap { candidate in
            do {
                guard let (type, data) = try readKey(candidate.key),
                      let celsius = decodeTemperature(type: type, data: data),
                      celsius.isFinite, (-20...130).contains(celsius) else {
                    return nil
                }
                return TemperatureSnapshot(id: candidate.key, name: candidate.name, celsius: celsius)
            } catch {
                return nil
            }
        }
    }

    // MARK: - 读取

    private func readFanSpeed(_ key: String) throws -> Double? {
        guard let (type, data) = try readKey(key) else { return nil }
        switch type {
        case "fpe2", "fpes": // 2 位小数定点，大端
            guard data.count >= 2 else { return nil }
            let raw = (UInt16(data[0]) << 8) | UInt16(data[1])
            return Double(raw) / 4.0
        case "ui16", "u16 ":
            guard data.count >= 2 else { return nil }
            let raw = (UInt16(data[0]) << 8) | UInt16(data[1])
            return Double(raw)
        case "flt ":
            return decodeFloat32(data)
        case "ui32", "u32 ":
            guard data.count >= 4 else { return nil }
            let raw = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 |
                UInt32(data[2]) << 8 | UInt32(data[3])
            return Double(raw)
        default:
            return nil
        }
    }

    private func readFlag(_ key: String) throws -> Bool? {
        guard let (_, data) = try readKey(key), data.count >= 1 else { return nil }
        return data[0] != 0
    }

    private func decodeTemperature(type: String, data: Data) -> Double? {
        guard data.count >= 2 else { return nil }
        let raw16 = (UInt16(data[0]) << 8) | UInt16(data[1])
        switch type {
        case "sp78":
            return Double(Int16(bitPattern: raw16)) / 256.0
        case "fpe2", "fpes":
            return Double(raw16) / 4.0
        case "ui16", "u16 ":
            return Double(raw16)
        case "flt ":
            return decodeFloat32(data)
        default:
            return nil
        }
    }

    private func decodeFloat32(_ data: Data) -> Double? {
        guard data.count >= 4 else { return nil }
        // AppleSMC stores `flt ` payloads in native/little-endian byte order
        // on the affected Intel/T2 machines.
        let bits = UInt32(data[0]) | UInt32(data[1]) << 8 |
            UInt32(data[2]) << 16 | UInt32(data[3]) << 24
        return Double(Float(bitPattern: bits))
    }

    /// 返回 (dataType 四字符, 数据)。键不存在返回 nil。
    private func readKey(_ key: String) throws -> (String, Data)? {
        // Callers that poll use their own serial queue. Do not sync back onto
        // this queue here: fans() -> snapshot() -> readKey() would deadlock.
        try _readKey(key)
    }

    private func _readKey(_ key: String) throws -> (String, Data)? {
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.data8 = UInt8(kSMCReadKeyInfo)
        var output = SMCParamStruct()
        try call(&input, &output, key: key)
        guard output.result == UInt8(kSMCSuccess) else {
            if output.result == UInt8(kSMCKeyNotFound) { return nil }
            throw FanError.readFailed(key, "SMC 命令 \(kSMCReadKeyInfo) 返回 result=0x\(String(output.result, radix: 16))。")
        }
        let size = Int(output.keyInfo.dataSize)
        let type = unFourCC(output.keyInfo.dataType)

        input = SMCParamStruct()
        input.key = fourCC(key)
        input.data8 = UInt8(kSMCReadBytes)
        input.keyInfo.dataSize = UInt32(size)
        input.keyInfo.dataType = output.keyInfo.dataType
        output = SMCParamStruct()
        try call(&input, &output, key: key)
        guard output.result == UInt8(kSMCSuccess) else {
            throw FanError.readFailed(key, "SMC 命令 \(kSMCReadBytes) 返回 result=0x\(String(output.result, radix: 16))。")
        }
        return (type, Data(toBytes(output).prefix(size)))
    }

    private func readRaw(key: String) throws -> Data? {
        try _readKey(key)?.1
    }

    private struct SMCKeyInfo {
        let size: Int
        let type: String
        let rawType: UInt32
    }

    private func readKeyInfo(_ key: String) throws -> SMCKeyInfo? {
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.data8 = UInt8(kSMCReadKeyInfo)
        var output = SMCParamStruct()
        try call(&input, &output, key: key)
        guard output.result == UInt8(kSMCSuccess) else {
            if output.result == UInt8(kSMCKeyNotFound) { return nil }
            throw FanError.readFailed(key, "SMC 命令 \(kSMCReadKeyInfo) 返回 result=0x\(String(output.result, radix: 16))。")
        }
        return SMCKeyInfo(size: Int(output.keyInfo.dataSize),
                          type: unFourCC(output.keyInfo.dataType),
                          rawType: output.keyInfo.dataType)
    }

    // MARK: - 写入

    private func writeFanSpeed(_ key: String, rpm: Double) throws {
        guard let info = try readKeyInfo(key) else { throw FanError.keyNotFound(key) }
        let bytes: [UInt8]
        switch info.type {
        case "fpe2", "fpes":
            let raw = UInt16(clamping: Int((max(0, rpm) * 4).rounded()))
            bytes = [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        case "flt ":
            let value = Float(rpm)
            let raw = value.bitPattern
            // The affected Intel/T2 SMC exposes flt payloads little-endian.
            bytes = [UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF),
                     UInt8((raw >> 16) & 0xFF), UInt8((raw >> 24) & 0xFF)]
        case "ui16", "u16 ":
            let raw = UInt16(clamping: Int(max(0, rpm).rounded()))
            bytes = [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        case "ui32", "u32 ":
            let raw = UInt32(clamping: Int(max(0, rpm).rounded()))
            bytes = [UInt8(raw >> 24), UInt8((raw >> 16) & 0xFF),
                     UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
        default:
            throw FanError.readFailed(key, "不支持的 SMC 写入类型 \(info.type)")
        }
        try writeKey(key, info: info, bytes: bytes)
    }

    private func writeFlag(_ key: String, value: UInt8) throws {
        guard let info = try readKeyInfo(key) else { throw FanError.keyNotFound(key) }
        try writeKey(key, info: info, bytes: [value])
    }

    private func writeKey(_ key: String, info: SMCKeyInfo, bytes: [UInt8]) throws {
        guard bytes.count == info.size else {
            throw FanError.readFailed(key, "SMC 键类型 \(info.type) 需要 \(info.size) 字节，实际准备了 \(bytes.count) 字节")
        }
        try queue.sync {
            var input = SMCParamStruct()
            input.key = fourCC(key)
            input.data8 = UInt8(kSMCWriteBytes)
            input.keyInfo.dataSize = UInt32(info.size)
            input.keyInfo.dataType = info.rawType
            withUnsafeMutableBytes(of: &input.bytes) { destination in
                destination.copyBytes(from: bytes)
            }
            var output = SMCParamStruct()
            try call(&input, &output, key: key)
            guard output.result == UInt8(kSMCSuccess) else { throw FanError.writeFailed(key, output.result) }
        }
    }

    private func toBytes(_ s: SMCParamStruct) -> [UInt8] {
        let b = s.bytes
        return [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7,
                b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15,
                b.16, b.17, b.18, b.19, b.20, b.21, b.22, b.23,
                b.24, b.25, b.26, b.27, b.28, b.29, b.30, b.31]
    }

    // MARK: - IOConnect 调用

    private func call(_ input: inout SMCParamStruct, _ output: inout SMCParamStruct, key: String) throws {
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(conn, kSMCSelector,
                                           &input, MemoryLayout<SMCParamStruct>.stride,
                                           &output, &outSize)
        guard kr == KERN_SUCCESS else {
            throw FanError.readFailed(key, "IOConnectCallStructMethod 返回 kern=0x\(String(UInt32(bitPattern: kr), radix: 16))。")
        }
    }
}

private let temperatureCandidates: [(key: String, name: String)] = [
    ("TC0P", "CPU Proximity"),
    ("TC0D", "CPU Die"),
    ("TC0E", "CPU Core"),
    ("TG0P", "GPU Proximity"),
    ("TG0D", "GPU Die"),
    ("TB0T", "Battery"),
    ("TH0P", "Heatsink"),
    ("Tm0P", "Memory"),
    ("Ts0P", "Palm Rest"),
    ("TN0P", "Northbridge")
]

// MARK: - SMC 协议常量与结构

private let kSMCSelector: UInt32 = 2 // KERNEL_INDEX_SMC
private let kSMCReadBytes = 5
private let kSMCWriteBytes = 6
private let kSMCReadKeyInfo = 9
private let kSMCSuccess = 0
private let kSMCKeyNotFound = 132 // 0x84

private func fourCC(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    for c in s.utf8.prefix(4) { v = (v << 8) | UInt32(c) }
    return v
}

private func unFourCC(_ v: UInt32) -> String {
    let b = [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
             UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    return String(bytes: b, encoding: .ascii) ?? "????"
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // C ABI rounds this nested struct from 9 to 12 bytes.
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}
