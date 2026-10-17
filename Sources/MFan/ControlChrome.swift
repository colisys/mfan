import AppKit
import SwiftUI

private struct ControlPageHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Height available to a page, so a page can fill the window instead of scrolling.
    var controlPageHeight: CGFloat {
        get { self[ControlPageHeightKey.self] }
        set { self[ControlPageHeightKey.self] = newValue }
    }
}

/// A strip with no controls that drags the window; the title bar is hidden.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: event) }
        }
    }
}

/// Hides the title and makes the window background see-through, so the sidebar
/// material shows what is behind the window.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfigView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private static var usesModernTitleBar: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }

    private final class ConfigView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear

            // On macOS 13, hiddenTitleBar removes the traffic-light buttons.
            // Keep the title-bar container and only hide the buttons on 14+.
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                let buttons = [
                    window.standardWindowButton(.closeButton),
                    window.standardWindowButton(.miniaturizeButton),
                    window.standardWindowButton(.zoomButton)
                ]
                buttons.forEach { $0?.isHidden = WindowConfigurator.usesModernTitleBar }
            }
        }
    }
}

struct ControlPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.primary.opacity(0.07), lineWidth: 1)
            }
    }
}

/// Always-visible bottom bar: activity, errors, last update and the takeover button.
struct ControlStatusBar: View {
    @ObservedObject var model: FanModel

    private var message: (text: String, isError: Bool)? {
        if let error = model.readError { return (error, true) }
        if let error = model.controlConnectionError { return (error, true) }
        if let text = model.commandMessage { return (text, model.commandFailed) }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            if model.busy {
                ProgressView().controlSize(.small)
                Text(model.operation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if let message {
                Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(message.isError ? .red : .green)
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? .red : .secondary)
                    .lineLimit(2)
                    .help(message.text)
            } else if let lastRead = model.lastRead {
                Text("最后更新 \(lastRead.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            Button {
                model.resumeThermalControl()
            } label: {
                Label("恢复温控接管", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .help("手动调速或恢复自动会暂停该风扇的温控接管；点击后重新启用。关闭窗口不会停止温控。")
            .disabled(model.busy || model.readError != nil)
        }
        .padding(.horizontal, 22)
        .frame(height: 46)
        .background(.bar)
    }
}
