import SwiftUI

/// The RPM span one fan can reach.
struct RuleFanRange: Equatable, Identifiable {
    let id: Int
    let lower: Int
    let upper: Int
}

/// Collapsible "rules" section. A rule holds the chosen fan (or all fans) at its RPM
/// while a named process runs, once the CPU reaches a temperature, or both. Per fan,
/// live rules combine: lowest trigger temperature, highest RPM.
struct ProcessRulesSection: View {
    let rules: [ProcessRule]
    let match: ProcessRuleMatch?
    let fans: [RuleFanRange]
    let busy: Bool
    let cpuTemperature: Double?
    let add: (String, Int, Int?, Int?) -> Void
    let remove: (UUID) -> Void
    let setEnabled: (UUID, Bool) -> Void
    let setRPM: (UUID, Int) -> Void
    let setTriggerTemp: (UUID, Int?) -> Void

    @State private var expanded = false
    @State private var newName = ""
    @State private var newTemperatureOnly = false
    @State private var newUsesTemp = false
    @State private var newTemp = Double(RuleTemperature.defaultCelsius)
    @State private var newFan: Int?
    @State private var newRPM: Double
    @State private var candidates: [String] = []

    private let rpmStep = 100.0

    init(
        rules: [ProcessRule], match: ProcessRuleMatch?, fans: [RuleFanRange], busy: Bool,
        cpuTemperature: Double?,
        add: @escaping (String, Int, Int?, Int?) -> Void,
        remove: @escaping (UUID) -> Void,
        setEnabled: @escaping (UUID, Bool) -> Void,
        setRPM: @escaping (UUID, Int) -> Void,
        setTriggerTemp: @escaping (UUID, Int?) -> Void
    ) {
        self.rules = rules
        self.match = match
        self.fans = fans
        self.busy = busy
        self.cpuTemperature = cpuTemperature
        self.add = add
        self.remove = remove
        self.setEnabled = setEnabled
        self.setRPM = setRPM
        self.setTriggerTemp = setTriggerTemp
        let bounds = Self.bounds(for: nil, in: fans)
        _newRPM = State(initialValue: Double((bounds.lower + bounds.upper) / 2))
    }

    /// A specific fan uses its own range; nil (all fans) or an unknown fan uses the
    /// span covering every fan, and each fan clamps on apply.
    static func bounds(for fanID: Int?, in fans: [RuleFanRange]) -> (lower: Int, upper: Int) {
        if let fanID, let fan = fans.first(where: { $0.id == fanID }) { return (fan.lower, fan.upper) }
        guard let lower = fans.map(\.lower).min(), let upper = fans.map(\.upper).max() else { return (0, 0) }
        return (lower, upper)
    }

    private var newBounds: (lower: Int, upper: Int) { Self.bounds(for: newFan, in: fans) }
    private var lower: Int { newBounds.lower }
    private var upper: Int { newBounds.upper }

    private var snappedNewRPM: Int {
        guard upper > lower else { return lower }
        let stepped = Double(lower) + ((newRPM - Double(lower)) / rpmStep).rounded() * rpmStep
        return Int(min(Double(upper), max(Double(lower), stepped)))
    }

    private var canAdd: Bool {
        newTemperatureOnly || !ProcessRuleResolver.normalized(newName).isEmpty
    }

    private var hasTemperatureRules: Bool {
        rules.contains { $0.enabled && $0.triggerTemp != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                if expanded { reloadCandidates() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                    Text("规则")
                        .font(.caption.weight(.medium))
                    Spacer()
                    if let match, !match.targets.isEmpty {
                        Label("\(match.winners.joined(separator: "、")) · \(match.rpmSummary)",
                              systemImage: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else if let match, !match.armedIDs.isEmpty {
                        Text("等待触发")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(rules.isEmpty ? "未设置" : "\(rules.count) 条 · 无匹配")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("规则")
            .accessibilityValue(expanded ? "已展开" : "已折叠")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("规则可由应用/进程运行、CPU 温度达到阈值或两者共同触发，触发后把所选风扇设为规则转速。同一风扇上多条规则同时成立时，触发温度取最低、转速取最高。温度回落 \(Int(RuleTemperature.hysteresis))°C 后释放，风扇回到启动设定的转速；没有启动设定时才交回系统控制。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if hasTemperatureRules {
                        if let cpuTemperature {
                            Label(String(format: "当前 CPU %.1f°C", cpuTemperature), systemImage: "thermometer.medium")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("读不到 CPU 温度，温度条件不会触发", systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }

                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(rules) { rule in
                                let ruleBounds = Self.bounds(for: rule.fanID, in: fans)
                                ProcessRuleRow(
                                    rule: rule,
                                    isActive: match?.activeIDs.contains(rule.id) ?? false,
                                    isArmed: match?.armedIDs.contains(rule.id) ?? false,
                                    lower: ruleBounds.lower,
                                    upper: ruleBounds.upper,
                                    remove: { remove(rule.id) },
                                    setEnabled: { setEnabled(rule.id, $0) },
                                    setRPM: { setRPM(rule.id, $0) },
                                    setTriggerTemp: { setTriggerTemp(rule.id, $0) }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 132)

                    addForm
                }
                .padding(.leading, 16)
                .disabled(busy)
            }
        }
        .padding(.vertical, 2)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !rules.isEmpty { Divider() }
            Picker("触发方式", selection: $newTemperatureOnly) {
                Text("应用/进程").tag(false)
                Text("仅温度").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            if !newTemperatureOnly {
            HStack(spacing: 6) {
                TextField("进程或 App 名称，如 UTM", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(commitNew)
                Menu {
                    if candidates.isEmpty {
                        Text("未找到运行中的 App")
                    }
                    ForEach(candidates, id: \.self) { name in
                        Button(name) { newName = name }
                    }
                    Divider()
                    Button("刷新列表") { reloadCandidates() }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("从运行中的 App 选择")
            }
            Toggle("同时要求 CPU 温度达到阈值", isOn: $newUsesTemp)
                .font(.caption2)
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }
            if newTemperatureOnly || newUsesTemp {
                HStack(spacing: 8) {
                    Text("≥")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $newTemp,
                        in: Double(RuleTemperature.range.lowerBound)...Double(RuleTemperature.range.upperBound),
                        step: Double(RuleTemperature.step)
                    )
                    Text("\(Int(newTemp))°C")
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                }
            }
            HStack(spacing: 6) {
                Text("作用于")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("作用风扇", selection: $newFan) {
                    Text("全部风扇").tag(Int?.none)
                    ForEach(fans) { fan in
                        Text("风扇 #\(fan.id)").tag(Int?.some(fan.id))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Spacer()
            }
            .onChange(of: newFan) { _ in
                newRPM = min(Double(upper), max(Double(lower), newRPM))
            }
            if lower < upper {
                HStack(spacing: 8) {
                    Slider(value: $newRPM, in: Double(lower)...Double(upper), step: rpmStep)
                    Text("\(snappedNewRPM)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                }
            }
            HStack {
                Spacer()
                Button(action: commitNew) {
                    Text("添加规则")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
                .opacity(canAdd ? 1 : 0.55)
            }
        }
    }

    private func commitNew() {
        guard canAdd else { return }
        let usesTemp = newTemperatureOnly || newUsesTemp
        add(
            newTemperatureOnly ? "" : newName.trimmingCharacters(in: .whitespacesAndNewlines),
            snappedNewRPM, newFan, usesTemp ? Int(newTemp) : nil
        )
        newName = ""
    }

    private func reloadCandidates() {
        Task {
            let names = await Task.detached(priority: .utility) { ProcessScanner.runningAppNames() }.value
            candidates = names
        }
    }
}

private struct ProcessRuleRow: View {
    let rule: ProcessRule
    let isActive: Bool
    let isArmed: Bool
    let lower: Int
    let upper: Int
    let remove: () -> Void
    let setEnabled: (Bool) -> Void
    let setRPM: (Int) -> Void
    let setTriggerTemp: (Int?) -> Void

    @State private var draft: Double
    @State private var editing = false
    @State private var tempDraft: Double
    @State private var tempEditing = false

    private let rpmStep = 100.0

    init(
        rule: ProcessRule, isActive: Bool, isArmed: Bool, lower: Int, upper: Int,
        remove: @escaping () -> Void,
        setEnabled: @escaping (Bool) -> Void,
        setRPM: @escaping (Int) -> Void,
        setTriggerTemp: @escaping (Int?) -> Void
    ) {
        self.rule = rule
        self.isActive = isActive
        self.isArmed = isArmed
        self.lower = lower
        self.upper = upper
        self.remove = remove
        self.setEnabled = setEnabled
        self.setRPM = setRPM
        self.setTriggerTemp = setTriggerTemp
        _draft = State(initialValue: Double(rule.rpm))
        _tempDraft = State(initialValue: Double(rule.triggerTemp ?? RuleTemperature.defaultCelsius))
    }

    private var snappedTempDraft: Int {
        let step = Double(RuleTemperature.step)
        let base = Double(RuleTemperature.range.lowerBound)
        let stepped = base + ((tempDraft - base) / step).rounded() * step
        return Int(min(Double(RuleTemperature.range.upperBound), max(base, stepped)))
    }

    private var snappedDraft: Int {
        guard upper > lower else { return rule.rpm }
        let stepped = Double(lower) + ((draft - Double(lower)) / rpmStep).rounded() * rpmStep
        return Int(min(Double(upper), max(Double(lower), stepped)))
    }

    // Temperature-only rules always have a threshold; process rules may add or drop one.
    @ViewBuilder private var temperatureControls: some View {
        if rule.isTemperatureOnly || rule.triggerTemp != nil {
            HStack(spacing: 8) {
                Text("≥")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // Commit on release, like the RPM slider.
                Slider(
                    value: $tempDraft,
                    in: Double(RuleTemperature.range.lowerBound)...Double(RuleTemperature.range.upperBound),
                    step: Double(RuleTemperature.step)
                ) { isEditing in
                    tempEditing = isEditing
                    if !isEditing, snappedTempDraft != rule.triggerTemp { setTriggerTemp(snappedTempDraft) }
                }
                .controlSize(.small)
                .disabled(!rule.enabled)
                Text("\(tempEditing ? snappedTempDraft : (rule.triggerTemp ?? snappedTempDraft))°C")
                    .font(.caption.monospacedDigit())
                    .frame(width: 48, alignment: .trailing)
                if !rule.isTemperatureOnly {
                    Button { setTriggerTemp(nil) } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("去掉温度条件（进程一运行就触发）")
                    .accessibilityLabel("去掉温度条件 \(rule.displayName)")
                }
            }
        } else {
            Button("添加温度条件") { setTriggerTemp(snappedTempDraft) }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                .disabled(!rule.enabled)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Toggle("", isOn: Binding(get: { rule.enabled }, set: setEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel("启用规则 \(rule.displayName)")
                if rule.isTemperatureOnly {
                    Image(systemName: "thermometer.medium")
                        .font(.caption)
                        .foregroundStyle(rule.enabled ? .primary : .secondary)
                }
                Text(rule.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(rule.enabled ? .primary : .secondary)
                HStack(spacing: 2) {
                    Image(systemName: "fan.fill")
                    Text(rule.fanID.map { "#\($0)" } ?? "全部")
                }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    .accessibilityLabel(rule.fanID.map { "风扇 \($0)" } ?? "全部风扇")
                if isActive {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                        .help("已触发")
                        .accessibilityLabel("已触发")
                } else if isArmed {
                    Circle().strokeBorder(.orange, lineWidth: 1).frame(width: 6, height: 6)
                        .help("已就绪，等待温度达到阈值")
                        .accessibilityLabel("等待触发")
                }
                Spacer()
                Text("\(editing ? snappedDraft : rule.rpm) RPM")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("删除规则")
                .accessibilityLabel("删除规则 \(rule.displayName)")
            }
            if lower < upper {
                // Only commit on release: each change may trigger a hardware write.
                Slider(value: $draft, in: Double(lower)...Double(upper), step: rpmStep) { isEditing in
                    editing = isEditing
                    if !isEditing, snappedDraft != rule.rpm { setRPM(snappedDraft) }
                }
                .controlSize(.small)
                .disabled(!rule.enabled)
            }
            temperatureControls
        }
        .onChange(of: rule.rpm) { value in
            if !editing { draft = Double(value) }
        }
        .onChange(of: rule.triggerTemp) { value in
            if !tempEditing, let value { tempDraft = Double(value) }
        }
    }
}
