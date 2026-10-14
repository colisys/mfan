import AppKit
import FanCore
import SwiftUI

@main
struct MFanApp: App {
    @StateObject private var model = FanModel()

    var body: some Scene {
        MenuBarExtra {
            FanMenuView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

private enum FanError: LocalizedError {
    case invalidSnapshot
    case missingCLI
    case controlServiceUnavailable
    case controlRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot:
            return "SMC 返回了无效的风扇数据。"
        case .missingCLI:
            return "找不到应用内的 fanctl，请使用打包脚本构建应用。"
        case .controlServiceUnavailable:
            return "风扇控制服务未响应，请重新授权。"
        case .controlRequestFailed(let message):
            return message
        }
    }
}

// Only the serial read queue accesses this client's SMC state.
private final class FanReader {
    private var client: SMCClient?

    func read() throws -> ([FanSnapshot], [TemperatureSnapshot]) {
        do {
            if client == nil { client = try SMCClient() }
            let fans = try client!.fans()
            let valid = Set(fans.map(\.id)).count == fans.count && fans.allSatisfy {
                $0.id >= 0 && $0.currentRPM.isFinite && $0.currentRPM >= 0 &&
                $0.minimumRPM.isFinite && $0.minimumRPM >= 0 &&
                $0.maximumRPM.isFinite && $0.maximumRPM >= $0.minimumRPM &&
                $0.maximumRPM < Double(Int.max) &&
                ceil($0.minimumRPM) <= floor($0.maximumRPM) &&
                ($0.targetRPM.map { $0.isFinite && $0 >= 0 } ?? true)
            }
            guard valid else { throw FanError.invalidSnapshot }
            let temperatures = try client!.temperatures()
            return (fans.sorted { $0.id < $1.id }, temperatures)
        } catch {
            client = nil
            throw error
        }
    }
}

@MainActor
private final class FanModel: ObservableObject {
    @Published private(set) var fans: [FanSnapshot] = []
    @Published private(set) var temperatures: [TemperatureSnapshot] = []
    @Published private(set) var readError: String?
    @Published private(set) var lastRead: Date?
    @Published private(set) var hasRead = false
    @Published private(set) var busy = false
    @Published private(set) var operation = ""
    @Published private(set) var commandMessage: String?
    @Published private(set) var commandFailed = false
    @Published private(set) var controlConnectionError: String?
    @Published private var controlMinimums: [Int: Double] = [:]
    @Published private(set) var controlDeadline: TimeInterval?
    @Published private(set) var statusRotationIndex = 0
    @Published private(set) var statusNow = ProcessInfo.processInfo.systemUptime
    private var currentRefreshInterval: TimeInterval = {
        let saved = UserDefaults.standard.double(forKey: "refreshInterval")
        return refreshIntervals.contains(saved) ? saved : defaultRefreshInterval
    }()
    private var currentStatusDisplayMode = UserDefaults.standard.string(forKey: "statusDisplayMode") ?? "fan"
    private var statusTimerInterval: TimeInterval?

    private let readQueue = DispatchQueue(label: "MFan.SMC.read", qos: .utility)
    private let commands = CommandRunner()
    private let reader = FanReader()
    private var controlClient: PrivilegedControlClient?
    private let serviceID = UUID().uuidString
    private var reading = false
    private var timer: DispatchSourceTimer?
    private var startupSettingAttempted = false
    private var heartbeatTimer: DispatchSourceTimer?
    private var statusTimer: DispatchSourceTimer?
    private var heartbeatActivity: NSObjectProtocol?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatPending = false
    private var wakeObserver: NSObjectProtocol?
    private var statusTicks = 0

    static let defaultRefreshInterval: TimeInterval = 5
    static let refreshIntervals: [TimeInterval] = [3, 5, 10, 15, 30]

    static var supportsArchitecture: Bool {
        #if arch(x86_64)
        true
        #else
        false
        #endif
    }

    init() {
        guard Self.supportsArchitecture else {
            readError = "仅支持 Intel Mac，不支持 Apple Silicon。"
            return
        }
        if Self.isTranslated {
            readError = "检测到 Rosetta 转译；Apple Silicon 不受支持。"
            return
        }

        refresh()
        let timer = DispatchSource.makeTimerSource(queue: readQueue)
        timer.schedule(deadline: .now() + currentRefreshInterval,
                       repeating: currentRefreshInterval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.timer = timer
        timer.resume()

        let statusTimer = DispatchSource.makeTimerSource(queue: .main)
        statusTimer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.tickStatus() }
        }
        self.statusTimer = statusTimer
        statusTimer.resume()
        rescheduleStatusTimer()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sendHeartbeat(immediate: true) }
        }
    }

    deinit {
        timer?.cancel()
        heartbeatTimer?.cancel()
        statusTimer?.cancel()
        heartbeatTask?.cancel()
        if let heartbeatActivity { ProcessInfo.processInfo.endActivity(heartbeatActivity) }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    private static var isTranslated: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 && value == 1
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        guard Self.refreshIntervals.contains(interval), let timer else { return }
        currentRefreshInterval = interval
        timer.schedule(deadline: .now() + interval,
                       repeating: interval, leeway: .milliseconds(250))
        rescheduleStatusTimer()
        refresh()
    }

    func refresh() {
        guard Self.supportsArchitecture, !Self.isTranslated, !reading else { return }
        reading = true
        let reader = self.reader
        readQueue.async { [weak self] in
            let result = Result { try reader.read() }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reading = false
                self.hasRead = true

                switch result {
                case .success(let result):
                    if self.fans != result.0 { self.fans = result.0 }
                    if self.temperatures != result.1 { self.temperatures = result.1 }
                    self.lastRead = Date()
                    if self.readError != nil { self.readError = nil }

                    self.applyStartupSettingIfNeeded()
                case .failure(let error):
                    if !self.fans.isEmpty { self.fans = [] }
                    let message = "读取 SMC 失败：\(error.localizedDescription)"
                    if self.readError != message { self.readError = message }
                }
            }
        }
    }

    func controlSnapshot(_ fan: FanSnapshot) -> FanSnapshot {
        var result = fan
        if let minimum = controlMinimums[fan.id], minimum.isFinite,
           minimum >= 0, ceil(minimum) <= floor(fan.maximumRPM) {
            result.minimumRPM = minimum
        }
        return result
    }

    func set(fanID: Int, rpm: Int, seconds: Int) {
        guard !busy, readError == nil,
              let snapshot = fans.first(where: { $0.id == fanID }),
              seconds == 0 || (30...600).contains(seconds) else { return }
        let fan = controlSnapshot(snapshot)
        let rpm = Int(min(floor(fan.maximumRPM), max(ceil(fan.minimumRPM), Double(rpm))))

        execute(
            request: FanControlRequest(command: "set", fan: fanID, rpm: Double(rpm), seconds: seconds),
            description: seconds == 0
                ? "风扇 #\(fanID) · \(rpm) RPM · 不限时"
                : "风扇 #\(fanID) · \(rpm) RPM · \(seconds) 秒"
        )
    }

    private func applyStartupSettingIfNeeded() {
        guard !startupSettingAttempted,
              UserDefaults.standard.bool(forKey: "startupFanEnabled"),
              let fan = fans.first(where: { $0.id == UserDefaults.standard.integer(forKey: "startupFanID") }) else { return }
        let configuredRPM = UserDefaults.standard.double(forKey: "startupFanRPM")
        guard configuredRPM.isFinite else { return }
        let rpm = Int(min(floor(fan.maximumRPM), max(ceil(fan.minimumRPM), configuredRPM)))
        guard rpm > 0 else { return }
        startupSettingAttempted = true
        set(fanID: fan.id, rpm: rpm, seconds: 0)
    }

    private func startHeartbeat(for client: PrivilegedControlClient) async {
        controlClient = client
        if heartbeatActivity == nil {
            // Keep the hidden menu-bar app responsive to lease renewals, without
            // preventing idle sleep or lid-close sleep.
            heartbeatActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Maintain the temporary fan-control safety heartbeat"
            )
        }
        if heartbeatTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.sendHeartbeat() }
            }
            heartbeatTimer = timer
            timer.resume()
        }
        sendHeartbeat(immediate: true)
        await heartbeatTask?.value
    }

    private func sendHeartbeat(immediate: Bool = false) {
        guard let client = controlClient else { return }
        guard heartbeatTask == nil else {
            // Coalesce wake/connection events into one follow-up, never overlapping sends.
            if immediate { heartbeatPending = true }
            return
        }
        heartbeatTask = Task { @MainActor [weak self] in
            let failure: String?
            do {
                let response = try await client.send(FanControlRequest(command: "heartbeat"))
                if let self, self.controlClient === client, !self.busy {
                    self.updateControlStatus(response)
                }
                failure = response.success ? nil : (response.error ?? "控制服务拒绝心跳")
            } catch {
                failure = error.localizedDescription
            }
            guard let self else { return }
            self.heartbeatTask = nil
            if self.controlClient === client {
                self.controlConnectionError = failure.map {
                    "控制服务状态异常：\($0)"
                }
            }
            if self.heartbeatPending {
                self.heartbeatPending = false
                self.sendHeartbeat()
            }
        }
    }

    func restoreAutomatic() {
        guard !busy, Self.supportsArchitecture, !Self.isTranslated else { return }
        execute(
            request: FanControlRequest(command: "auto"),
            description: "正在恢复所有风扇的自动控制…"
        )
    }

    private func execute(request: FanControlRequest, description: String) {
        guard !busy else { return }
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else {
            commandFailed = true
            commandMessage = FanError.missingCLI.localizedDescription
            return
        }

        let cli = directory.appendingPathComponent("fanctl")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            commandFailed = true
            commandMessage = FanError.missingCLI.localizedDescription
            return
        }

        busy = true
        operation = description
        commandMessage = nil
        commandFailed = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.busy = false
                self.operation = ""
                self.refresh()
            }
            do {
                let client: PrivilegedControlClient
                do {
                    client = try await self.ensureControlClient()
                } catch {
                    // Authorization is allowed only before attempting the user's request.
                    self.controlClient = nil
                    try? FileManager.default.removeItem(atPath: self.serviceLogPath)
                    let script = CommandRunner.authorizationScript(
                        cli: cli,
                        arguments: ["serve", self.socketPath],
                        background: true,
                        backgroundLogPath: self.serviceLogPath
                    )
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        self.commands.submit(script: script) { result in
                            continuation.resume(with: result)
                        }
                    }
                    client = try await self.waitForControlClient()
                }

                let response: FanControlResponse
                do {
                    response = try await client.send(request)
                } catch {
                    // A missing response does not mean the write was not applied. Never replay it.
                    throw FanError.controlRequestFailed(
                        "控制请求结果未知，未自动重试：\(error.localizedDescription)"
                    )
                }
                self.updateControlStatus(response)
                self.commandFailed = !response.success
                self.commandMessage = response.success
                    ? (response.message ?? "操作已完成")
                    : (response.error ?? "控制服务拒绝请求")
            } catch {
                self.commandFailed = true
                self.commandMessage = self.serviceErrorMessage(error)
            }
        }
    }

    private func rescheduleStatusTimer() {
        guard let statusTimer else { return }
        let countdownIsDisplayed = currentStatusDisplayMode == "countdown" &&
            (controlDeadline ?? 0) > ProcessInfo.processInfo.systemUptime
        let interval = countdownIsDisplayed ? 1 : currentRefreshInterval
        guard statusTimerInterval != interval else { return }
        statusTimerInterval = interval
        statusTimer.schedule(deadline: .now() + interval,
                             repeating: interval,
                             leeway: .milliseconds(countdownIsDisplayed ? 100 : 250))
    }

    private func tickStatus() {
        statusNow = ProcessInfo.processInfo.systemUptime
        if let deadline = controlDeadline, statusNow >= deadline {
            controlDeadline = nil
            statusTicks = 0
            statusRotationIndex = 0
            rescheduleStatusTimer()
        } else if controlDeadline == nil && currentStatusDisplayMode == "countdown" {
            statusRotationIndex = (statusRotationIndex + 1) % 2
        }
    }

    private func updateControlStatus(_ response: FanControlResponse) {
        if let minima = response.minimumRPMs { controlMinimums = minima }
        if let seconds = response.controlSeconds, seconds > 0 {
            controlDeadline = ProcessInfo.processInfo.systemUptime + Double(seconds)
        } else if response.success {
            controlDeadline = nil
        }
        statusTicks = 0
        statusRotationIndex = 0
        rescheduleStatusTimer()
    }

    func setStatusDisplay(_ mode: String) {
        guard mode == "fan" || mode == "cpu" || mode == "battery" || mode == "countdown" else { return }
        currentStatusDisplayMode = mode
        statusDisplayMode = mode
        statusRotationIndex = 0
        statusTicks = 0
        rescheduleStatusTimer()
    }

    @Published private(set) var statusDisplayMode = "fan"

    func quit() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let controlClient {
                _ = try? await controlClient.send(FanControlRequest(command: "shutdown"))
            }
            self.heartbeatTimer?.cancel()
            self.heartbeatTimer = nil
            self.statusTimer?.cancel()
            self.statusTimer = nil
            if let activity = self.heartbeatActivity {
                ProcessInfo.processInfo.endActivity(activity)
                self.heartbeatActivity = nil
            }
            NSApplication.shared.terminate(nil)
        }
    }

    private var serviceDirectory: URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mfan-\(NSUserName())")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return base
    }

    private var socketPath: String {
        // sockaddr_un.sun_path is limited to roughly 104 bytes on macOS.
        // The per-user temporary directory is already long, so keep the
        // randomized socket directly under /tmp and pass the full same path
        // to both the privileged server and this client.
        "/tmp/mfan-\(serviceID)"
    }

    private var serviceLogPath: String {
        serviceDirectory.appendingPathComponent("control-service.log").path
    }

    private func serviceErrorMessage(_ error: Error) -> String {
        let logURL = URL(fileURLWithPath: serviceLogPath)
        if let data = try? Data(contentsOf: logURL),
           let log = String(data: data, encoding: .utf8),
           !log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let tail = String(log.suffix(800)).trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(error.localizedDescription)\n服务日志：\(tail)"
        }
        return "\(error.localizedDescription)\n服务日志路径：\(serviceLogPath)"
    }

    private func ensureControlClient() async throws -> PrivilegedControlClient {
        let client = controlClient ?? PrivilegedControlClient(socketPath: socketPath)
        guard await client.ping() else { throw FanError.controlServiceUnavailable }
        await startHeartbeat(for: client)
        return client
    }

    private func waitForControlClient() async throws -> PrivilegedControlClient {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            let client = PrivilegedControlClient(socketPath: socketPath)
            if await client.ping() {
                await startHeartbeat(for: client)
                return client
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw FanError.controlServiceUnavailable
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var model: FanModel
    @AppStorage("statusDisplayMode") private var statusDisplayMode = "fan"

    private var cpuTemperature: Double? {
        let candidates = ["CPU Die", "CPU Proximity", "CPU Core"]
        return candidates.lazy.compactMap { name in
            model.temperatures.first(where: { $0.name == name })?.celsius
        }.first
    }

    private var batteryTemperature: Double? {
        model.temperatures.first(where: { $0.name == "Battery" })?.celsius
    }

    private var countdown: Int? {
        guard let deadline = model.controlDeadline else { return nil }
        return max(0, Int(ceil(deadline - model.statusNow)))
    }

    private var showsCountdown: Bool { statusDisplayMode == "countdown" && (countdown ?? 0) > 0 }
    private var showsFan: Bool {
        statusDisplayMode == "fan" || (statusDisplayMode == "countdown" && !showsCountdown && model.statusRotationIndex == 0)
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: statusDisplayMode == "battery" ? "battery.100" : (showsFan ? "fan.fill" : (showsCountdown ? "timer" : "thermometer.medium")))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(showsFan ? iconColor : .primary)
            if statusDisplayMode == "battery" {
                if let batteryTemperature {
                    Text("\(Int(batteryTemperature))°").font(.caption.monospacedDigit())
                } else {
                    Text("--°").font(.caption.monospacedDigit())
                }
            } else if showsCountdown, let countdown {
                Text("\(countdown)s").font(.caption.monospacedDigit())
            } else if showsFan, let fan = model.fans.first {
                Text("\(Int(fan.currentRPM))").font(.caption.monospacedDigit())
            } else if let cpuTemperature {
                Text("\(Int(cpuTemperature))°").font(.caption.monospacedDigit())
            } else if !showsFan {
                Text("--°").font(.caption.monospacedDigit())
            }
        }
        .onChange(of: statusDisplayMode) { mode in model.setStatusDisplay(mode) }
    }

    private var iconColor: Color {
        guard let fan = model.fans.first else { return .secondary }
        if fan.currentRPM >= 5_000 { return .red }
        if fan.currentRPM >= 3_500 { return .orange }
        return .primary
    }
}

private struct FanMenuView: View {
    @ObservedObject var model: FanModel
    @State private var showingMaintenanceGuide = false
    @AppStorage("startupFanEnabled") private var startupFanEnabled = false
    @AppStorage("startupFanID") private var startupFanID = 0
    @AppStorage("startupFanRPM") private var startupFanRPM = 0.0
    @AppStorage("refreshInterval") private var refreshInterval = FanModel.defaultRefreshInterval
    @AppStorage("statusDisplayMode") private var statusDisplayMode = "fan"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("MFan", systemImage: "fan.fill")
                    .font(.headline)
                Spacer()
                Button {
                    showingMaintenanceGuide.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("查看机器保养须知")
                .popover(isPresented: $showingMaintenanceGuide, arrowEdge: .top) {
                    MaintenanceGuide()
                }
                if model.hasRead && model.readError == nil {
                    Circle().fill(.green).frame(width: 7, height: 7)
                }
            }

            if let error = model.readError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.hasRead {
                ProgressView("正在读取 SMC…")
                    .controlSize(.small)
            } else if model.fans.isEmpty {
                Text("未检测到风扇")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.fans) { fan in
                    FanMenuRow(
                        fan: model.controlSnapshot(fan),
                        busy: model.busy,
                        startupFanID: startupFanID,
                        startupFanRPM: startupFanRPM,
                        set: { rpm, seconds in
                            model.set(fanID: fan.id, rpm: rpm, seconds: seconds)
                        },
                        setStartup: { rpm in
                            startupFanEnabled = true
                            startupFanID = fan.id
                            startupFanRPM = Double(rpm)
                        }
                    )
                }
            }

            if !model.temperatures.isEmpty {
                TemperatureSection(temperatures: model.temperatures)
            }

            if model.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.operation).font(.caption)
                }
            }

            if let error = model.controlConnectionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = model.commandMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(model.commandFailed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("恢复自动") {
                    model.restoreAutomatic()
                }
                .disabled(model.busy || !FanModel.supportsArchitecture)
                Spacer()
                if let date = model.lastRead {
                    Text(date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if startupFanEnabled {
                    Button("取消启动设定") {
                        startupFanEnabled = false
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                } else {
                    Text("启动设定未启用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("状态栏显示", selection: $statusDisplayMode) {
                    Text("风扇转速").tag("fan")
                    Text("CPU 温度").tag("cpu")
                    Text("电池温度").tag("battery")
                    Text("倒计时").tag("countdown")
                }
                .labelsHidden()
                .frame(width: 92)
                .help("选择菜单栏图标旁的状态")
                .onChange(of: statusDisplayMode) { mode in
                    model.setStatusDisplay(mode)
                }
                Picker("刷新间隔", selection: $refreshInterval) {
                    ForEach(FanModel.refreshIntervals, id: \.self) { interval in
                        Text("每 \(Int(interval)) 秒").tag(interval)
                    }
                }
                .labelsHidden()
                .frame(width: 92)
                .help("风扇与温度读取间隔")
                .onChange(of: refreshInterval) { interval in
                    model.setRefreshInterval(interval)
                }
                Button("退出") {
                    model.quit()
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(width: 330)
        .onAppear { model.refresh() }
    }
}

private struct FanMenuRow: View {
    let fan: FanSnapshot
    let busy: Bool
    let startupFanID: Int
    let startupFanRPM: Double
    let set: (Int, Int) -> Void
    let setStartup: (Int) -> Void
    @State private var rpm: Double
    @State private var seconds = 60

    private let rpmStep = 100.0

    init(
        fan: FanSnapshot,
        busy: Bool,
        startupFanID: Int,
        startupFanRPM: Double,
        set: @escaping (Int, Int) -> Void,
        setStartup: @escaping (Int) -> Void
    ) {
        self.fan = fan
        self.busy = busy
        self.startupFanID = startupFanID
        self.startupFanRPM = startupFanRPM
        self.set = set
        self.setStartup = setStartup
        let initial = fan.targetRPM ?? fan.currentRPM
        _rpm = State(initialValue: min(floor(fan.maximumRPM), max(ceil(fan.minimumRPM), initial)))
    }

    private var lower: Double { ceil(fan.minimumRPM) }
    private var upper: Double { floor(fan.maximumRPM) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("风扇 #\(fan.id)").font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(fan.currentRPM)) RPM")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if lower < upper {
                    Slider(value: $rpm, in: lower...upper, step: rpmStep)
                }
                Text("\(snappedRPM)")
                    .font(.caption.monospacedDigit())
                    .frame(width: 48, alignment: .trailing)
            }

            HStack(spacing: 6) {
                Picker("期限", selection: $seconds) {
                    Text("不限时").tag(0)
                    ForEach(Array(stride(from: 30, through: 600, by: 30)), id: \.self) { value in
                        Text("\(value) 秒").tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 88)

                Spacer()

                Button("启动设定") { setStartup(snappedRPM) }
                    .controlSize(.small)
                    .disabled(busy)
                Button("设定") { set(snappedRPM, seconds) }
                    .controlSize(.small)
            }
            if startupFanID == fan.id {
                Text(startupFanRPM > 0
                     ? "软件启动后自动设置为\(snappedStartupRPM) rpm"
                     : "已选为启动时设定风扇")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(busy)
        .onChange(of: fan.minimumRPM) { _ in clampRPM() }
        .onChange(of: fan.maximumRPM) { _ in clampRPM() }
    }

    private var snappedRPM: Int {
        guard upper >= lower else { return Int(lower.rounded()) }
        let stepped = lower + ((rpm - lower) / rpmStep).rounded() * rpmStep
        return Int(min(upper, max(lower, stepped)).rounded())
    }

    private var snappedStartupRPM: Int {
        guard lower < upper else { return Int(lower.rounded()) }
        let stepped = lower + ((startupFanRPM - lower) / rpmStep).rounded() * rpmStep
        return Int(min(upper, max(lower, stepped)).rounded())
    }

    private func clampRPM() {
        rpm = min(upper, max(lower, rpm))
    }
}
