import FanCore
import SwiftUI

/// Control-center card for one fan. Larger, roomier counterpart of the menu bar row.
struct FanControlCard: View {
    let fan: FanSnapshot
    let busy: Bool
    let heldUnlimited: Bool
    let thermalTarget: Int?
    let startupEnabled: Bool
    let startupFanRPM: Double
    let set: (Int, Int) -> Void
    let restoreAutomatic: () -> Void
    let setStartup: (Int) -> Void
    let cancelStartup: () -> Void
    @State private var rpm: Double
    @State private var seconds = 0

    private let rpmStep = 100.0

    init(
        fan: FanSnapshot, busy: Bool, heldUnlimited: Bool, thermalTarget: Int?,
        startupEnabled: Bool, startupFanRPM: Double,
        set: @escaping (Int, Int) -> Void,
        restoreAutomatic: @escaping () -> Void,
        setStartup: @escaping (Int) -> Void,
        cancelStartup: @escaping () -> Void
    ) {
        self.fan = fan
        self.busy = busy
        self.heldUnlimited = heldUnlimited
        self.thermalTarget = thermalTarget
        self.startupEnabled = startupEnabled
        self.startupFanRPM = startupFanRPM
        self.set = set
        self.restoreAutomatic = restoreAutomatic
        self.setStartup = setStartup
        self.cancelStartup = cancelStartup
        let initial = fan.targetRPM ?? fan.currentRPM
        _rpm = State(initialValue: min(floor(fan.maximumRPM), max(ceil(fan.minimumRPM), initial)))
    }

    private var lower: Double { ceil(fan.minimumRPM) }
    private var upper: Double { floor(fan.maximumRPM) }

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

    private var tint: Color {
        if fan.currentRPM >= 5_000 { return .red }
        if fan.currentRPM >= 3_500 { return .orange }
        return .accentColor
    }

    private var load: Double {
        guard upper > lower else { return 0 }
        return min(1, max(0, (fan.currentRPM - lower) / (upper - lower)))
    }

    private var mode: (text: String, color: Color) {
        if heldUnlimited { return ("手动保持", .orange) }
        if let thermalTarget { return ("温控 \(thermalTarget) RPM", .accentColor) }
        return ("系统自动", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            readout

            if FanSafety.showsHighSpeedWarning(fan: fan, heldUnlimited: heldUnlimited) {
                Label(FanSafety.highSpeedWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.6)
            manualControls
            startupRow
        }
        .disabled(busy)
        .onChange(of: fan.minimumRPM) { _ in rpm = min(upper, max(lower, rpm)) }
        .onChange(of: fan.maximumRPM) { _ in rpm = min(upper, max(lower, rpm)) }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "fan.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.13), in: Circle())
                .accessibilityHidden(true)
            Text("风扇 #\(fan.id)")
                .font(.headline)
            Spacer()
            Text(mode.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(mode.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(mode.color.opacity(0.12), in: Capsule())
        }
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(Int(fan.currentRPM))")
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("RPM")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("当前转速")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ProgressView(value: load)
                .tint(tint)
                .accessibilityLabel("当前转速占可用范围")
            HStack {
                Text("\(Int(lower))")
                Spacer()
                Text("\(Int(upper))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
    }

    private var manualControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("手动目标")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(snappedRPM) RPM")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
            if lower < upper {
                Slider(value: $rpm, in: lower...upper, step: rpmStep)
            }
            HStack(spacing: 9) {
                Picker("期限", selection: $seconds) {
                    Text("不限时").tag(0)
                    ForEach(Array(stride(from: 30, through: 600, by: 30)), id: \.self) { value in
                        Text("\(value) 秒").tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 96)
                Spacer()
                Button("恢复自动") { restoreAutomatic() }
                Button("设定转速") { set(snappedRPM, seconds) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
        }
    }

    private var startupRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "power")
                .font(.caption)
                .foregroundStyle(startupEnabled ? Color.accentColor : .secondary)
            Text(startupEnabled && startupFanRPM > 0
                 ? "启动时设为 \(snappedStartupRPM) RPM"
                 : "未启用启动设定")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if startupEnabled {
                Button("取消") { cancelStartup() }
            }
            Button("以此为启动设定") { setStartup(snappedRPM) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
