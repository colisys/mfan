import SwiftUI

/// Embed in the control center. The parent owns persistence and re-evaluation.
struct ThermalSection: View {
    let configuration: ThermalConfiguration
    let currentTemperature: Double?
    let busy: Bool
    let save: (ThermalConfiguration) -> Void
    @State private var draftEnabled = false
    @State private var draftCurve = ThermalBezier.standard
    /// What the last "apply" sent, so the model echoing it back does not overwrite the draft.
    @State private var submitted: ThermalConfiguration?

    private var savedCurve: ThermalBezier {
        configuration.curve ?? ThermalBezier.fitting(configuration.points)
    }

    private var hasChanges: Bool {
        draftEnabled != configuration.enabled || draftCurve != savedCurve
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("全局温控曲线")
                        .font(.title3.weight(.semibold))
                    Text("拖动曲线上的圆点：横轴是 CPU 温度，纵轴是风扇在自身转速范围内的比例。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("启用全局温度曲线", isOn: $draftEnabled)
                    .labelsHidden()
                    .help("启用或停用全局温度曲线")
                    .disabled(busy)
            }

            ThermalCurveEditor(curve: $draftCurve, currentTemperature: currentTemperature, enabled: draftEnabled)
                .frame(height: 210)
                .padding(.horizontal, 6)
                .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 14) {
                readout("起点", draftCurve[.start])
                readout("终点", draftCurve[.end])
                if let temperature = currentTemperature, ThermalResolver.validTemperature(temperature) {
                    Label(String(format: "当前 %.0f°C → 范围 %.0f%%", temperature, draftCurve.percent(at: temperature)),
                          systemImage: "circle.fill")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("恢复默认曲线") { draftCurve = .standard }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Button("应用温控") {
                    let config = ThermalConfiguration(enabled: draftEnabled, curve: draftCurve)
                    submitted = config
                    save(config)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!draftCurve.isValid || !hasChanges || busy)
            }

            Text("0% 为风扇最低转速，并非停转。曲线之外的温度保持端点的比例。需点击“应用温控”后生效。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: load)
        .onChange(of: configuration) { new in
            if new == submitted {
                submitted = nil
            } else {
                load()
            }
        }
    }

    private func load() {
        draftEnabled = configuration.enabled
        draftCurve = savedCurve
    }

    private func readout(_ title: String, _ node: ThermalPoint) -> some View {
        Text("\(title) \(Int(node.temperature))°C · \(Int(node.percent))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: Capsule())
    }
}
