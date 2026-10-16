import SwiftUI

/// One rule: what triggers it, how hard it pushes the fans, and when it starts.
struct RuleCard: View {
    let rule: ProcessRule
    let isActive: Bool
    let isArmed: Bool
    let fans: [RuleFanRange]
    let remove: () -> Void
    let setEnabled: (Bool) -> Void
    let setPercent: (Int) -> Void
    let setTriggerTemp: (Int?) -> Void

    @State private var draft: Double
    @State private var editing = false
    @State private var tempDraft: Double
    @State private var tempEditing = false

    private let percentStep = 5.0

    /// A legacy absolute-RPM rule is shown as the average share of each fan's range
    /// its RPM amounts to; dragging the slider converts it to a percentage rule.
    static func effectivePercent(of rule: ProcessRule, fans: [RuleFanRange]) -> Int {
        if let percent = rule.percent { return percent }
        let shares = fans.filter { $0.upper > $0.lower }.map {
            (Double(rule.rpm - $0.lower) / Double($0.upper - $0.lower)) * 100
        }
        guard !shares.isEmpty else { return 50 }
        let mean = shares.reduce(0, +) / Double(shares.count)
        return Int(min(100, max(5, (mean / 5).rounded() * 5)))
    }

    init(rule: ProcessRule, isActive: Bool, isArmed: Bool, fans: [RuleFanRange],
         remove: @escaping () -> Void, setEnabled: @escaping (Bool) -> Void,
         setPercent: @escaping (Int) -> Void, setTriggerTemp: @escaping (Int?) -> Void) {
        self.rule = rule
        self.isActive = isActive
        self.isArmed = isArmed
        self.fans = fans
        self.remove = remove
        self.setEnabled = setEnabled
        self.setPercent = setPercent
        self.setTriggerTemp = setTriggerTemp
        _draft = State(initialValue: Double(Self.effectivePercent(of: rule, fans: fans)))
        _tempDraft = State(initialValue: Double(rule.triggerTemp ?? RuleTemperature.defaultCelsius))
    }

    private var snappedDraft: Int {
        Int(min(100, max(percentStep, (draft / percentStep).rounded() * percentStep)))
    }

    private var snappedTemp: Int {
        let step = Double(RuleTemperature.step), base = Double(RuleTemperature.range.lowerBound)
        let stepped = base + ((tempDraft - base) / step).rounded() * step
        return Int(min(Double(RuleTemperature.range.upperBound), max(base, stepped)))
    }

    private var shownPercent: Int { editing ? snappedDraft : Self.effectivePercent(of: rule, fans: fans) }
    private var startTemp: Int { tempEditing ? snappedTemp : (rule.triggerTemp ?? 40) }

    private var subtitle: String {
        let target = rule.fanID.map { "风扇 #\($0)" } ?? "全部风扇"
        let when = rule.isTemperatureOnly ? "CPU ≥ \(startTemp)°C"
            : (rule.triggerTemp == nil ? "运行时 · 默认起温 40°C" : "运行时 · CPU ≥ \(startTemp)°C")
        return "\(when) · \(target)"
    }

    private var chip: (text: String, color: Color)? {
        if !rule.enabled { return ("已停用", .secondary) }
        if isActive { return ("生效中", .orange) }
        if isArmed { return ("等待触发", .blue) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: rule.isTemperatureOnly ? "thermometer.medium" : "macwindow")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? Color.orange : Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background((isActive ? Color.orange : Color.accentColor).opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let chip {
                    Text(chip.text).font(.caption2.weight(.semibold)).foregroundStyle(chip.color)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(chip.color.opacity(0.14), in: Capsule())
                }
                Toggle("启用规则 \(rule.displayName)", isOn: Binding(get: { rule.enabled }, set: setEnabled))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                Button(action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("删除规则").accessibilityLabel("删除规则 \(rule.displayName)")
            }
            HStack(spacing: 14) {
                RuleRampGlyph(start: startTemp, percent: shownPercent)
                    .frame(width: 70, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("高温目标").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(shownPercent)%").font(.caption.weight(.semibold).monospacedDigit())
                    }
                    // Commit on release: each change may trigger a hardware write.
                    Slider(value: $draft, in: percentStep...100, step: percentStep) { isEditing in
                        editing = isEditing
                        if !isEditing, snappedDraft != Self.effectivePercent(of: rule, fans: fans) {
                            setPercent(snappedDraft)
                        }
                    }
                    .controlSize(.small)
                }
            }
            if !fans.isEmpty {
                Text(rule.percent == nil && !editing
                     ? "旧规则：固定 \(rule.rpm) RPM（拖动滑块改为按风扇范围百分比）"
                     : ProcessRulesSection.preview(percent: shownPercent, fans: fans))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            temperatureRow
        }
        .padding(14)
        .opacity(rule.enabled ? 1 : 0.6)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(isActive ? Color.orange.opacity(0.55) : Color.primary.opacity(0.06), lineWidth: 1)
        }
        .onChange(of: rule.percent) { _ in
            if !editing { draft = Double(Self.effectivePercent(of: rule, fans: fans)) }
        }
        .onChange(of: rule.triggerTemp) { value in
            if !tempEditing, let value { tempDraft = Double(value) }
        }
    }

    // Temperature-only rules always have a threshold; process rules may add or drop one.
    @ViewBuilder private var temperatureRow: some View {
        if rule.isTemperatureOnly || rule.triggerTemp != nil {
            HStack(spacing: 8) {
                Text("起始温度").font(.caption).foregroundStyle(.secondary)
                Slider(value: $tempDraft,
                       in: Double(RuleTemperature.range.lowerBound)...Double(RuleTemperature.range.upperBound),
                       step: Double(RuleTemperature.step)) { isEditing in
                    tempEditing = isEditing
                    if !isEditing, snappedTemp != rule.triggerTemp { setTriggerTemp(snappedTemp) }
                }
                .controlSize(.small).disabled(!rule.enabled)
                Text("\(startTemp)°C").font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
                if !rule.isTemperatureOnly {
                    Button { setTriggerTemp(nil) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("使用默认起始温度 40°C")
                        .accessibilityLabel("去掉温度条件 \(rule.displayName)")
                }
            }
        } else {
            Button("自定义起始温度") { setTriggerTemp(snappedTemp) }
                .buttonStyle(.borderless).font(.caption).disabled(!rule.enabled)
        }
    }
}

/// Tiny ramp: flat until the start temperature, then rising to the target share.
private struct RuleRampGlyph: View {
    let start: Int
    let percent: Int

    var body: some View {
        Canvas { context, size in
            let low = 20.0, span = 100.0
            let x0 = size.width * (Double(start) - low) / span
            let x1 = size.width * (max(100.0, Double(start) + 20) - low) / span
            let top = size.height * (1 - Double(percent) / 100) * 0.8 + 3
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height - 3))
            line.addLine(to: CGPoint(x: min(x0, size.width), y: size.height - 3))
            line.addLine(to: CGPoint(x: min(x1, size.width), y: top))
            line.addLine(to: CGPoint(x: size.width, y: top))
            context.stroke(line, with: .color(.accentColor),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }
}
