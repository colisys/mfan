import SwiftUI

/// Menu bar panel: what is steering the fans now (global curve and live rules),
/// plus a way into the rule settings page.
struct ActiveRulesSummary: View {
    let match: ProcessRuleMatch?
    let rules: [ProcessRule]
    let thermal: ThermalConfiguration
    let cpuTemperature: Double?
    let open: () -> Void

    private var effectiveRules: [(name: String, detail: String, on: Bool)] {
        guard let match else { return [] }
        let all = match.winners.map { ($0, $0 == "全局温控") }
        let nonGlobal = all.filter { !$0.1 }
        
        if !nonGlobal.isEmpty {
            // Rules override global: show only rules
            return nonGlobal.map { ($0.0, "生效中", true) }
        } else if !all.isEmpty {
            // Only global is winning: show it with status
            return [("全局温控", globalDetail, thermal.enabled)]
        } else {
            return []
        }
    }

    private var waitingCount: Int { match?.armedIDs.count ?? 0 }

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
            if effectiveRules.isEmpty {
                line(title: "规则", detail: waitingCount > 0 ? "\(waitingCount) 条等待触发"
                     : (rules.isEmpty ? "未设置" : "无生效"), on: false)
            } else {
                ForEach(effectiveRules, id: \.name) { item in
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
