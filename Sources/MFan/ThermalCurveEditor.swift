import SwiftUI

/// Draggable cubic Bezier: x is CPU temperature, y is the share of each fan's range.
/// Moves go through `ThermalBezier.move`, which keeps both axes monotone.
struct ThermalCurveEditor: View {
    @Binding var curve: ThermalBezier
    let currentTemperature: Double?
    let enabled: Bool

    @State private var active: ThermalBezier.Handle?
    @State private var grabOffset = CGSize.zero

    private let insets = EdgeInsets(top: 14, leading: 38, bottom: 26, trailing: 16)
    private let hitRadius = 18.0

    var body: some View {
        GeometryReader { proxy in
            let plot = CGRect(
                x: insets.leading, y: insets.top,
                width: max(1, proxy.size.width - insets.leading - insets.trailing),
                height: max(1, proxy.size.height - insets.top - insets.bottom)
            )
            Canvas { context, _ in draw(&context, plot: plot) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in handleDrag(drag, plot: plot) }
                        .onEnded { _ in active = nil }
                )
        }
        .accessibilityElement()
        .accessibilityLabel("全局温控曲线编辑器")
        .accessibilityValue("起点 \(Int(curve[.start].temperature))°C，终点 \(Int(curve[.end].temperature))°C")
        .accessibilityHint("拖动曲线上的圆点调整风扇随温度变化的比例")
    }

    private func point(_ node: ThermalPoint, in plot: CGRect) -> CGPoint {
        CGPoint(
            x: plot.minX + plot.width * (node.temperature - ThermalBezier.temperatureRange.lowerBound) / 100,
            y: plot.maxY - plot.height * node.percent / 100
        )
    }

    private func handleDrag(_ drag: DragGesture.Value, plot: CGRect) {
        if active == nil {
            // Control handles win ties so overlapping nodes can be pulled apart.
            let order: [ThermalBezier.Handle] = [.control1, .control2, .start, .end]
            let nearest = order
                .map { ($0, point(curve[$0], in: plot)) }
                .map { ($0.0, $0.1, hypot($0.1.x - drag.startLocation.x, $0.1.y - drag.startLocation.y)) }
                .filter { $0.2 <= hitRadius }
                .min { $0.2 < $1.2 }
            guard let nearest else { return }
            active = nearest.0
            grabOffset = CGSize(width: nearest.1.x - drag.startLocation.x, height: nearest.1.y - drag.startLocation.y)
        }
        guard let active, enabled else { return }
        let x = drag.location.x + grabOffset.width
        let y = drag.location.y + grabOffset.height
        let temperature = ThermalBezier.temperatureRange.lowerBound + 100 * (x - plot.minX) / plot.width
        let percent = 100 * (plot.maxY - y) / plot.height
        var next = curve
        next.move(active, toTemperature: temperature, percent: percent)
        if next != curve { curve = next }
    }

    private func draw(_ context: inout GraphicsContext, plot: CGRect) {
        let accent = Color.accentColor
        let muted = Color.secondary

        for percent in [0.0, 25, 50, 75, 100] {
            let y = plot.maxY - plot.height * percent / 100
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(muted.opacity(percent == 0 ? 0.3 : 0.14)), lineWidth: 1)
            if percent.truncatingRemainder(dividingBy: 50) == 0 {
                context.draw(Text("\(Int(percent))%").font(.caption2.monospacedDigit()).foregroundColor(.secondary.opacity(0.7)),
                             at: CGPoint(x: plot.minX - 8, y: y), anchor: .trailing)
            }
        }
        for temperature in stride(from: 20.0, through: 120.0, by: 20.0) {
            let x = plot.minX + plot.width * (temperature - 20) / 100
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: .color(muted.opacity(0.1)), lineWidth: 1)
            context.draw(Text("\(Int(temperature))°").font(.caption2.monospacedDigit()).foregroundColor(.secondary.opacity(0.7)),
                         at: CGPoint(x: x, y: plot.maxY + 13), anchor: .center)
        }

        let p0 = point(curve[.start], in: plot), p1 = point(curve[.control1], in: plot)
        let p2 = point(curve[.control2], in: plot), p3 = point(curve[.end], in: plot)

        var shape = Path()
        shape.move(to: CGPoint(x: plot.minX, y: p0.y))
        shape.addLine(to: p0)
        shape.addCurve(to: p3, control1: p1, control2: p2)
        shape.addLine(to: CGPoint(x: plot.maxX, y: p3.y))
        var fill = shape
        fill.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        fill.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        fill.closeSubpath()
        context.fill(fill, with: .linearGradient(
            Gradient(colors: [accent.opacity(enabled ? 0.26 : 0.1), accent.opacity(0.0)]),
            startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
        context.stroke(shape, with: .color(accent.opacity(enabled ? 1 : 0.45)),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

        for (anchor, control) in [(p0, p1), (p3, p2)] {
            var tangent = Path()
            tangent.move(to: anchor)
            tangent.addLine(to: control)
            context.stroke(tangent, with: .color(muted.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        if let temperature = currentTemperature,
           ThermalBezier.temperatureRange.contains(temperature) {
            let marker = point(.init(temperature: temperature, percent: curve.percent(at: temperature)), in: plot)
            var guide = Path()
            guide.move(to: CGPoint(x: marker.x, y: plot.minY))
            guide.addLine(to: CGPoint(x: marker.x, y: plot.maxY))
            context.stroke(guide, with: .color(.orange.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            context.fill(Path(ellipseIn: CGRect(x: marker.x - 5, y: marker.y - 5, width: 10, height: 10)), with: .color(.orange))
        }

        for handle in ThermalBezier.Handle.allCases {
            let center = point(curve[handle], in: plot)
            let isControl = handle == .control1 || handle == .control2
            let radius: CGFloat = active == handle ? 9 : 7
            let dot = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: dot), with: .color(isControl ? Color(nsColor: .windowBackgroundColor) : accent))
            context.stroke(Path(ellipseIn: dot), with: .color(accent), lineWidth: 2.5)
        }
    }
}
