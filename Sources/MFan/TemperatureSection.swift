import SwiftUI
import FanCore

struct TemperatureSection: View {
    let temperatures: [TemperatureSnapshot]

    private var visibleTemperatures: [TemperatureSnapshot] {
        let preferred = ["CPU Die", "CPU Proximity", "GPU Die", "GPU Proximity", "Heatsink", "Memory"]
        return temperatures.sorted { lhs, rhs in
            let left = preferred.firstIndex(of: lhs.name) ?? preferred.count
            let right = preferred.firstIndex(of: rhs.name) ?? preferred.count
            return left == right ? lhs.name < rhs.name : left < right
        }.prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("温度")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(visibleTemperatures) { temperature in
                HStack(spacing: 6) {
                    Image(systemName: icon(for: temperature.name))
                        .frame(width: 16)
                        .foregroundStyle(color(for: temperature.celsius))
                    Text(displayName(for: temperature.name))
                    Spacer()
                    Text(String(format: "%.1f°C", temperature.celsius))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(color(for: temperature.celsius))
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func displayName(for name: String) -> String {
        switch name {
        case "CPU Die", "CPU Proximity": return "CPU"
        case "GPU Die", "GPU Proximity": return "GPU"
        case "Heatsink": return "散热器"
        case "Memory": return "内存"
        case "Battery": return "电池"
        case "Palm Rest": return "掌托"
        default: return name
        }
    }

    private func icon(for name: String) -> String {
        if name.contains("CPU") { return "cpu" }
        if name.contains("GPU") { return "rectangle.3.group" }
        if name == "Battery" { return "battery.100" }
        return "thermometer.medium"
    }

    private func color(for temperature: Double) -> Color {
        if temperature >= 90 { return .red }
        if temperature >= 75 { return .orange }
        if temperature >= 60 { return .yellow }
        return .primary
    }
}
