import Foundation
import FanCore

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    let name = CommandLine.arguments[0].split(separator: "/").last ?? "fanctl"
    print("""
    用法：
      \(name) status                       列出所有风扇状态（JSON）
      \(name) set <风扇编号> <RPM> <秒数>   手动设定转速（需要 root，30-600秒）
      \(name) auto [风扇编号]               恢复系统自动控制（缺省为全部，需要 root）
      \(name) serve <socket>                 启动一次性本地特权控制服务（需要 root）
    """)
    exit(1)
}

guard let cmd = args.first else { usage() }

if cmd == "serve" {
    guard args.count == 2 else { usage() }
    do {
        try PrivilegedFanServer(socketPath: args[1]).run()
        exit(0)
    } catch {
        fputs("错误：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

do {
    let client = try SMCClient()
    
    switch cmd {
    case "status":
        let fans = try client.fans()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(fans)
        print(String(data: json, encoding: .utf8) ?? "[]")
        
    case "set":
        guard args.count == 4,
              let index = Int(args[1]),
              let rpm = Double(args[2]),
              let seconds = Int(args[3]),
              seconds >= 30, seconds <= 600 else {
            print("错误：set 参数无效；收到 \(args.count) 个参数：\(args.dropFirst().joined(separator: " "))。需要 <风扇编号> <RPM> <秒数>，秒数为 30-600。")
            exit(1)
        }
        
        // 读取当前状态并保存起始转速
        let snap = try client.snapshot(index: index)
        let originalSpeed = snap.currentRPM
        
        // 设定手动转速（不低于当前实际转速，防止手动降速过低）
        let targetRPM = max(rpm, originalSpeed)
        if targetRPM > rpm {
            print("警告：目标转速 \(Int(rpm)) 低于当前实际 \(Int(originalSpeed))，已提升到 \(Int(targetRPM))")
        }
        
        let usesManualMode = try client.supportsManualMode(fanIndex: index)
        let originalMinimum: Double?
        if usesManualMode {
            try client.setManualSpeed(fanIndex: index, rpm: targetRPM)
            originalMinimum = nil
        } else {
            originalMinimum = try client.raiseMinimumSpeed(fanIndex: index, rpm: targetRPM)
            print("此风扇无手动模式键；暂时提高最低转速，系统仍会自动调速")
        }
        print("风扇 \(index) 已设定，将在 \(seconds) 秒后恢复")

        // Keep this process alive for the entire control session.
        sleep(UInt32(seconds))

        if let originalMinimum = originalMinimum {
            try client.restoreMinimumSpeed(fanIndex: index, rpm: originalMinimum)
            print("风扇 \(index) 的原最低转速已恢复")
        } else {
            try client.restoreAuto(fanIndex: index)
            print("风扇 \(index) 已恢复系统自动控制")
        }
        
    case "auto":
        if args.count == 1 {
            let count = try client.fanCount()
            for i in 0..<count {
                try client.restoreAuto(fanIndex: i)
            }
            print("所有风扇（共 \(count) 个）均处于系统自动调速状态")
        } else if args.count == 2, let index = Int(args[1]) {
            try client.restoreAuto(fanIndex: index)
            if try client.supportsManualMode(fanIndex: index) {
                print("风扇 \(index) 已恢复系统自动控制")
            } else {
                print("风扇 \(index) 没有手动模式键；系统继续自动调速")
            }
        } else {
            print("错误：auto 参数应为 [风扇编号]")
            exit(1)
        }
        
    default:
        usage()
    }
    
} catch {
    print("错误：\(error.localizedDescription)")
    exit(1)
}
