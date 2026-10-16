import FanCore
import SwiftUI

struct OverviewPage: View {
    @ObservedObject var model: FanModel

    private var averageFanRPM: Int? {
        guard !model.fans.isEmpty else { return nil }
        return Int((model.fans.map(\.currentRPM).reduce(0, +) / Double(model.fans.count)).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusStrip
            fanGrid
        }
    }

    private var statusStrip: some View {
        ControlPanel {
            HStack(alignment: .center, spacing: 0) {
                tile(title: "CPU 温度", icon: "thermometer.medium",
                     value: model.cpuTemperature.map { String(format: "%.1f°", $0) } ?? "--.-°",
                     caption: model.cpuTemperature == nil ? "暂时无法读取" : "摄氏度")
                    .padding(.trailing, 24)
                Divider().frame(height: 84)
                tile(title: "风扇", icon: "fan", value: "\(model.fans.count)",
                     caption: averageFanRPM.map { "平均 \($0) RPM" } ?? "等待风扇数据")
                    .padding(.horizontal, 24)
                Divider().frame(height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    if model.temperatures.isEmpty {
                        Text("正在读取传感器…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        TemperatureSection(temperatures: model.temperatures, showsTitle: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 24)
            }
        }
    }

    private func tile(title: String, icon: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 120, alignment: .leading)
    }

    @ViewBuilder
    private var fanGrid: some View {
        if model.fans.isEmpty {
            ControlPanel {
                Group {
                    if model.hasRead {
                        Label("未检测到风扇", systemImage: "fan.slash").foregroundStyle(.secondary)
                    } else {
                        ProgressView("正在读取 SMC…")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            }
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top),
                                GridItem(.flexible(), spacing: 14, alignment: .top)],
                      spacing: 14) {
                ForEach(model.fans) { fan in
                    ControlPanel {
                        FanControlCard(
                            fan: model.controlSnapshot(fan),
                            busy: model.busy,
                            heldUnlimited: model.unlimitedFans.contains(fan.id),
                            thermalTarget: model.ruleMatch?.targets[fan.id],
                            startupEnabled: model.startupRPM(for: fan.id) != nil,
                            startupFanRPM: model.startupRPM(for: fan.id) ?? 0,
                            set: { model.set(fanID: fan.id, rpm: $0, seconds: $1) },
                            restoreAutomatic: { model.restoreAutomatic(fanID: fan.id) },
                            setStartup: { model.setStartup(fanID: fan.id, rpm: $0) },
                            cancelStartup: { model.cancelStartup(fanID: fan.id) }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

struct ThermalPage: View {
    @ObservedObject var model: FanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ControlPanel {
                ThermalSection(
                    configuration: model.thermalConfiguration,
                    currentTemperature: model.cpuTemperature,
                    busy: model.busy,
                    save: model.saveThermalConfiguration
                )
            }
            targets
        }
    }

    private var targets: some View {
        ControlPanel {
            HStack(spacing: 14) {
                Label("当前目标", systemImage: "scope")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                if model.fans.isEmpty {
                    Text("暂无风扇数据").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.fans) { fan in
                    let target = model.ruleMatch?.targets[fan.id]
                    HStack(spacing: 6) {
                        Text("风扇 #\(fan.id)").font(.caption.weight(.semibold))
                        Text(target.map { "\($0) RPM" } ?? "不接管")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(target == nil ? Color.secondary : Color.accentColor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                }
                Spacer()
                if let match = model.ruleMatch, !match.winners.isEmpty {
                    Text("由 \(match.winners.joined(separator: "、")) 决定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct RulesPage: View {
    @ObservedObject var model: FanModel

    var body: some View {
        ProcessRulesSection(
            rules: model.processRules,
            match: model.ruleMatch,
            fans: model.fanRanges,
            busy: model.busy,
            cpuTemperature: model.cpuTemperature,
            add: { model.addProcessRule(name: $0, percent: $1, fanID: $2, triggerTemp: $3) },
            remove: model.removeProcessRule,
            setEnabled: { model.setProcessRule(id: $0, enabled: $1) },
            setPercent: { model.setProcessRule(id: $0, percent: $1) },
            setTriggerTemp: { model.setProcessRule(id: $0, triggerTemp: $1) }
        )
    }
}

struct SettingsPage: View {
    @ObservedObject var model: FanModel
    @AppStorage("refreshInterval") private var refreshInterval = FanModel.defaultRefreshInterval
    @AppStorage("statusDisplayMode") private var statusDisplayMode = "fan"
    @State private var showingGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ControlPanel {
                VStack(alignment: .leading, spacing: 16) {
                    row("刷新间隔", "风扇与温度读取的间隔") {
                        Picker("刷新间隔", selection: $refreshInterval) {
                            ForEach(FanModel.refreshIntervals, id: \.self) { interval in
                                Text("每 \(Int(interval)) 秒").tag(interval)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        .onChange(of: refreshInterval) { model.setRefreshInterval($0) }
                    }
                    Divider()
                    row("菜单栏显示", "菜单栏图标旁显示的状态") {
                        Picker("菜单栏显示", selection: $statusDisplayMode) {
                            Text("风扇转速").tag("fan")
                            Text("CPU 温度").tag("cpu")
                            Text("电池温度").tag("battery")
                            Text("倒计时").tag("countdown")
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        .onChange(of: statusDisplayMode) { model.setStatusDisplay($0) }
                    }
                    Divider()
                    row("全部恢复自动", "把所有风扇交回系统控制，并暂停温控接管") {
                        Button("全部恢复自动") { model.restoreAllAutomatic() }
                            .disabled(model.busy || !FanModel.supportsArchitecture)
                    }
                    Divider()
                    row("保养须知", "日常散热建议与清洁注意事项") {
                        Button("查看") { showingGuide.toggle() }
                            .popover(isPresented: $showingGuide, arrowEdge: .trailing) { MaintenanceGuide() }
                    }
                    Divider()
                    row("退出 MFan", "退出时会恢复系统风扇控制") {
                        Button("退出") { model.quit() }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func row<Control: View>(_ title: String, _ subtitle: String,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            control()
        }
    }
}
