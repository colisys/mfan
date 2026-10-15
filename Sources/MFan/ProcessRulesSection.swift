import SwiftUI

/// The RPM span one fan can reach.
struct RuleFanRange: Equatable, Identifiable {
    let id: Int
    let lower: Int
    let upper: Int
}

/// Collapsible "launch rules" section: while a named process runs, hold the
/// chosen fan (or all fans) at the rule's RPM. Per fan, the highest RPM among
/// running matches wins.
struct ProcessRulesSection: View {
    let rules: [ProcessRule]
    let match: ProcessRuleMatch?
    let fans: [RuleFanRange]
    let busy: Bool
    let add: (String, Int, Int?) -> Void
    let remove: (UUID) -> Void
    let setEnabled: (UUID, Bool) -> Void
    let setRPM: (UUID, Int) -> Void

    @State private var expanded = false
    @State private var newName = ""
    @State private var newFan: Int?
    @State private var newRPM: Double
    @State private var candidates: [String] = []

    private let rpmStep = 100.0

    init(
        rules: [ProcessRule], match: ProcessRuleMatch?, fans: [RuleFanRange], busy: Bool,
        add: @escaping (String, Int, Int?) -> Void,
        remove: @escaping (UUID) -> Void,
        setEnabled: @escaping (UUID, Bool) -> Void,
        setRPM: @escaping (UUID, Int) -> Void
    ) {
        self.rules = rules
        self.match = match
        self.fans = fans
        self.busy = busy
        self.add = add
        self.remove = remove
        self.setEnabled = setEnabled
        self.setRPM = setRPM
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
        !ProcessRuleResolver.normalized(newName).isEmpty
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
                    Text("进程规则")
                        .font(.caption.weight(.medium))
                    Spacer()
                    if let match {
                        Label("\(match.winners.joined(separator: "、")) · \(match.rpmSummary)",
                              systemImage: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else {
                        Text(rules.isEmpty ? "未设置" : "\(rules.count) 条 · 无匹配")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("进程规则")
            .accessibilityValue(expanded ? "已展开" : "已折叠")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("指定进程运行时，把所选风扇（或全部风扇）设为规则转速；同一风扇被多条规则命中时取最高转速。规则结束后，该风扇回到启动设定的转速；没有启动设定时才恢复自动。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(rules) { rule in
                        let ruleBounds = Self.bounds(for: rule.fanID, in: fans)
                        ProcessRuleRow(
                            rule: rule,
                            isActive: match?.activeIDs.contains(rule.id) ?? false,
                            lower: ruleBounds.lower,
                            upper: ruleBounds.upper,
                            remove: { remove(rule.id) },
                            setEnabled: { setEnabled(rule.id, $0) },
                            setRPM: { setRPM(rule.id, $0) }
                        )
                    }

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
                Button("添加规则", action: commitNew)
                    .controlSize(.small)
                    .disabled(!canAdd)
            }
        }
    }

    private func commitNew() {
        guard canAdd else { return }
        add(newName.trimmingCharacters(in: .whitespacesAndNewlines), snappedNewRPM, newFan)
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
    let lower: Int
    let upper: Int
    let remove: () -> Void
    let setEnabled: (Bool) -> Void
    let setRPM: (Int) -> Void

    @State private var draft: Double
    @State private var editing = false

    private let rpmStep = 100.0

    init(
        rule: ProcessRule, isActive: Bool, lower: Int, upper: Int,
        remove: @escaping () -> Void,
        setEnabled: @escaping (Bool) -> Void,
        setRPM: @escaping (Int) -> Void
    ) {
        self.rule = rule
        self.isActive = isActive
        self.lower = lower
        self.upper = upper
        self.remove = remove
        self.setEnabled = setEnabled
        self.setRPM = setRPM
        _draft = State(initialValue: Double(rule.rpm))
    }

    private var snappedDraft: Int {
        guard upper > lower else { return rule.rpm }
        let stepped = Double(lower) + ((draft - Double(lower)) / rpmStep).rounded() * rpmStep
        return Int(min(Double(upper), max(Double(lower), stepped)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Toggle("", isOn: Binding(get: { rule.enabled }, set: setEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel("启用规则 \(rule.name)")
                Text(rule.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(rule.enabled ? .primary : .secondary)
                Text(rule.fanID.map { "#\($0)" } ?? "全部")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    .accessibilityLabel(rule.fanID.map { "风扇 \($0)" } ?? "全部风扇")
                if isActive {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                        .accessibilityLabel("正在运行")
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
                .accessibilityLabel("删除规则 \(rule.name)")
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
        }
        .onChange(of: rule.rpm) { value in
            if !editing { draft = Double(value) }
        }
    }
}
