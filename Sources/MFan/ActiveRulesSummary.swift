import SwiftUI

/// Menu bar panel: what is steering the fans now (global curve and live rules),
/// plus a way into the rule settings page.
struct ActiveRulesSummary: View {
    let match: ProcessRuleMatch?
    let rules: [ProcessRule]
    let thermal: ThermalConfiguration
    let cpuTemperature: Double?
    let open: () -> Void

    private struct SummaryItem: Identifiable {
        let id: String
        let name: String
        let detail: String
        let on: Bool
    }

    /// `winners` only contains rules that produced the highest target RPM. It is
    /// not the same as all running rules, so derive the menu summary from the
    /// rule IDs as well and use winners only to describe precedence.
    private var items: [SummaryItem] {
        guard let match else {
            return thermal.enabled
                ? [SummaryItem(id: "global", name: "全局温控", detail: globalDetail, on: true)]
                : []
        }

        let winnerNames = Set(match.winners)
        let activeRules = rules.filter { match.activeIDs.contains($0.id) }
        let armedRules = rules.filter { match.armedIDs.contains($0.id) }
        var result: [SummaryItem] = []

        for rule in activeRules {
            let name = rule.displayName
            let isWinner = winnerNames.contains(name)
            result.append(SummaryItem(
                id: rule.id.uuidString,
                name: name,
                detail: isWinner ? "生效中" : "运行中 · 未超过当前目标",
                on: isWinner
            ))
        }
        for rule in armedRules {
            result.append(SummaryItem(
                id: "armed-\(rule.id.uuidString)",
                name: rule.displayName,
                detail: "等待触发",
                on: false
            ))
        }

        if winnerNames.contains("全局温控") {
            result.append(SummaryItem(id: "global", name: "全局温控", detail: globalDetail, on: thermal.enabled))
        }
        return result
    }

    private var globalDetail: String {
        guard thermal.enabled else { return "未启用" }
        if let cpuTemperature, let percent = thermal.percent(at: cpuTemperature) {
            return String(format: "已启用 · 范围 %.0f%%", percent)
        }
        return "已启用 · 温度不可用"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(match?.targets.isEmpty == false ? .orange : .secondary)
                Text("当前执行")
                    .font(.caption.weight(.medium))
                Spacer()
                if let match, !match.targets.isEmpty {
                    Text(match.rpmSummary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if items.isEmpty {
                line(title: "规则", detail: rules.isEmpty ? "未设置" : "无生效", on: false)
            } else {
                ForEach(items) { item in
                    line(title: item.name, detail: item.detail, on: item.on)
                }
            }
            Button(action: open) {
                Label("打开规则设置", systemImage: "list.bullet.rectangle")
                    .font(.caption2.weight(.medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.vertical, 2)
    }

    private func line(title: String, detail: String, on: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(on ? Color.orange : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(title).font(.caption2).lineLimit(1)
            Spacer()
            Text(detail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
