import SwiftUI

/// The RPM span one fan can reach.
struct RuleFanRange: Equatable, Identifiable {
    let id: Int
    let lower: Int
    let upper: Int
}

/// Rules page: rule cards on the left, a composer for a new rule on the right.
/// A rule raises the chosen fan (or all fans) while a named process runs, once the
/// CPU reaches a temperature, or both. Per fan, live rules combine with the global curve.
struct ProcessRulesSection: View {
    let rules: [ProcessRule]
    let match: ProcessRuleMatch?
    let fans: [RuleFanRange]
    let busy: Bool
    let cpuTemperature: Double?
    let add: (String, Int, Int?, Int?) -> Void
    let remove: (UUID) -> Void
    let setEnabled: (UUID, Bool) -> Void
    let setPercent: (UUID, Int) -> Void
    let setTriggerTemp: (UUID, Int?) -> Void

    @Environment(\.controlPageHeight) private var pageHeight

    /// The fans a rule for `fanID` acts on: nil means every fan.
    static func applicableFans(for fanID: Int?, in fans: [RuleFanRange]) -> [RuleFanRange] {
        fanID == nil ? fans : fans.filter { $0.id == fanID }
    }

    /// "#0 4200 · #1 6100 RPM": what a percentage comes to on each fan.
    static func preview(percent: Int, fans: [RuleFanRange]) -> String {
        guard !fans.isEmpty else { return "" }
        return fans.map { "#\($0.id) \(ThermalResolver.highTarget(percent: percent, on: $0))" }
            .joined(separator: " · ") + " RPM"
    }

    private var hasTemperatureRules: Bool {
        rules.contains { $0.enabled && $0.triggerTemp != nil }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ControlPanel { listPanel.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
            ControlPanel {
                RuleComposer(fans: fans, add: add)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: 320)
        }
        .frame(height: max(pageHeight, 440))
        .disabled(busy)
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("规则").font(.title3.weight(.semibold))
                    Text("从起始温度的最低转速，线性升到高温目标；与全局曲线逐风扇取较高值。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                status
            }
            if hasTemperatureRules {
                if let cpuTemperature {
                    Label(String(format: "当前 CPU %.1f°C", cpuTemperature), systemImage: "thermometer.medium")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("读不到 CPU 温度，温度条件不会触发", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            if rules.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("还没有规则").font(.headline)
                    Text("在右侧添加：某个 App 运行时，或 CPU 达到指定温度时提高风扇转速。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 10) {
                        ForEach(rules) { rule in
                            RuleCard(
                                rule: rule,
                                isActive: match?.activeIDs.contains(rule.id) ?? false,
                                isArmed: match?.armedIDs.contains(rule.id) ?? false,
                                fans: Self.applicableFans(for: rule.fanID, in: fans),
                                remove: { remove(rule.id) },
                                setEnabled: { setEnabled(rule.id, $0) },
                                setPercent: { setPercent(rule.id, $0) },
                                setTriggerTemp: { setTriggerTemp(rule.id, $0) }
                            )
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let match, !match.targets.isEmpty {
            Label("\(match.winners.joined(separator: "、")) · \(match.rpmSummary)", systemImage: "bolt.fill")
                .font(.caption.weight(.medium)).foregroundStyle(.orange).lineLimit(1)
        } else {
            Text(rules.isEmpty ? "未设置" : "\(rules.count) 条 · 无匹配")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
