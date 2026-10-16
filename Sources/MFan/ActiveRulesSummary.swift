import SwiftUI

/// Menu bar panel: what is steering the fans now (global curve and live rules),
/// plus a way into the rule settings page.
struct ActiveRulesSummary: View {
    let match: ProcessRuleMatch?
    let rules: [ProcessRule]
    let thermal: ThermalConfiguration
    let cpuTemperature: Double?
    let open: () -> Void

    private var effectiveRules: [(name: String, isGlobal: Bool)] {
        guard let match else { return [] }
        let all = match.winners.map { ($0, $0 == "全局温控") }
        let nonGlobal = all.filter { !$0.1 }
        // Show only rules when they override the global curve.
        return nonGlobal.isEmpty ? all : nonGlobal
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
            line(title: "全局温控", detail: globalDetail, on: thermal.enabled)
            if effectiveRules.isEmpty {
                line(title: "规则", detail: waitingCount > 0 ? "\(waitingCount) 条等待触发"
                     : (rules.isEmpty ? "未设置" : "无生效"), on: false)
            } else {
                ForEach(effectiveRules, id: \.name) { item in
                    line(title: item.name, detail: "生效中", on: true)
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
