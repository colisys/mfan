import AppKit
import FanCore
import SwiftUI

enum ControlPage: String, CaseIterable, Identifiable {
    case overview, thermal, rules, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .thermal: return "温控曲线"
        case .rules: return "规则"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .thermal: return "waveform.path"
        case .rules: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

extension FanModel {
    var cpuTemperature: Double? { TemperatureSource.cpuCelsius(temperatures) }

    var fanRanges: [RuleFanRange] {
        fans.map(controlSnapshot).map {
            RuleFanRange(id: $0.id, lower: Int(ceil($0.minimumRPM)), upper: Int(floor($0.maximumRPM)))
        }
    }
}

/// Sidebar of pages on the left; on the right one page per screen above a status bar
/// that stays visible. A page taller than the window scrolls instead of being clipped,
/// so it can never push the sidebar or the status bar out of view.
struct ControlCenterView: View {
    @ObservedObject var model: FanModel
    private var page: ControlPage { model.controlPage }

    var body: some View {
        HStack(spacing: 0) {
            ControlSidebar(model: model, selection: $model.controlPage)
                .frame(width: 190)
            Divider().ignoresSafeArea()
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    ScrollView {
                        content
                            .padding(EdgeInsets(top: 22, leading: 22, bottom: 22, trailing: 22))
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                            .environment(\.controlPageHeight, max(0, proxy.size.height - 52))
                    }
                    .id(page)
                }
                Divider()
                ControlStatusBar(model: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

        }
        .frame(minWidth: 900, minHeight: 640)
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .overview: OverviewPage(model: model)
        case .thermal: ThermalPage(model: model)
        case .rules: RulesPage(model: model)
        case .settings: SettingsPage(model: model)
        }
    }
}

private struct ControlSidebar: View {
    @ObservedObject var model: FanModel
    @Binding var selection: ControlPage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "fan.fill").foregroundStyle(Color.accentColor)
                Text("MFan").font(.headline)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)

            ForEach(ControlPage.allCases) { item in
                Button {
                    selection = item
                } label: {
                    Label(item.title, systemImage: item.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .foregroundColor(selection == item ? Color.accentColor : Color.primary)
                        .background(
                            selection == item ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                ControlLinkIndicator(state: model.linkState)
                Text(model.linkState.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
        }
        .padding(EdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SidebarMaterial())

    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
