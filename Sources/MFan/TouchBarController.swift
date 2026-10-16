import AppKit
import Combine
import FanCore

/// Native Touch Bar for the control center window: one button per fan, a speed slider,
/// a live RPM readout and "restore automatic". It subscribes to the model itself, because
/// the SwiftUI view that hosts it is not re-evaluated when the model publishes.
@MainActor
final class TouchBarCoordinator: NSObject, NSTouchBarDelegate {
    weak var model: FanModel? {
        didSet {
            guard oldValue !== model else { return }
            subscription = model?.objectWillChange.sink { [weak self] _ in
                // objectWillChange fires before the change lands; refresh on the next turn.
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
    }

    private var subscription: AnyCancellable?
    private weak var installedWindow: NSWindow?
    private var fanButtons = NSStackView()
    private var shownFanIDs: [Int] = []
    private var slider = NSSlider()
    private var valueLabel = NSTextField(labelWithString: "")
    private var restoreButton = NSButton(title: "恢复自动", target: nil, action: nil)
    private var resumeButton = NSButton(title: "恢复接管", target: nil, action: nil)
    /// A slider value not yet sent. The slider is continuous so the readout follows the
    /// finger; the hardware write happens once the value has stopped changing.
    private var pending: (fanID: Int, rpm: Int)?
    private var pendingTask: Task<Void, Never>?

    private var selectedFanID: Int {
        get { model?.touchBarFanID ?? 0 }
        set { model?.touchBarFanID = newValue }
    }

    func detach() {
        pendingTask?.cancel()
        pendingTask = nil
        pending = nil
        installedWindow?.touchBar = nil
        installedWindow = nil
    }

    func install(on window: NSWindow) {
        installedWindow = window
        window.touchBar = makeTouchBar()
        refresh()
    }

    func refresh() {
        guard let model else { return }
        let ids = model.fans.map(\.id)
        if !ids.contains(selectedFanID), let first = ids.first { selectedFanID = first }
        if ids != shownFanIDs { rebuildFanButtons(ids) }
        for case let button as NSButton in fanButtons.arrangedSubviews {
            button.bezelColor = button.tag == selectedFanID ? .controlAccentColor : nil
            button.isEnabled = !model.busy
        }
        guard let fan = model.fans.first(where: { $0.id == selectedFanID }) else {
            slider.isEnabled = false
            restoreButton.isEnabled = false
            resumeButton.isEnabled = false
            valueLabel.stringValue = "无风扇数据"
            return
        }
        let snapshot = model.controlSnapshot(fan)
        let lower = ceil(snapshot.minimumRPM)
        let upper = floor(snapshot.maximumRPM)
        slider.minValue = lower
        slider.maxValue = max(lower, upper)
        slider.isEnabled = !model.busy && upper > lower
        restoreButton.isEnabled = !model.busy
        resumeButton.isEnabled = !model.busy
        // While a change is pending the user is driving the slider and readout.
        if pending == nil {
            slider.doubleValue = min(slider.maxValue, max(lower, snapshot.targetRPM ?? snapshot.currentRPM))
            valueLabel.stringValue = "\(Int(snapshot.currentRPM.rounded())) RPM"
        }
    }

    private func rebuildFanButtons(_ ids: [Int]) {
        shownFanIDs = ids
        for view in fanButtons.arrangedSubviews {
            fanButtons.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for id in ids {
            let button = NSButton(title: "风扇 #\(id)", target: self, action: #selector(selectFan(_:)))
            button.tag = id
            fanButtons.addArrangedSubview(button)
        }
    }

    private func makeTouchBar() -> NSTouchBar {
        fanButtons = NSStackView()
        fanButtons.orientation = .horizontal
        fanButtons.spacing = 8
        shownFanIDs = []
        slider = NSSlider(target: self, action: #selector(sliderChanged(_:)))
        slider.isContinuous = true
        valueLabel = NSTextField(labelWithString: "")
        valueLabel.alignment = .right
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.widthAnchor.constraint(equalToConstant: 96).isActive = true
        restoreButton = NSButton(title: "恢复自动", target: self, action: #selector(restoreAutomatic(_:)))
        resumeButton = NSButton(title: "恢复接管", target: self, action: #selector(resumeControl(_:)))
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [.fanSelector, .fanSlider, .fanValue, .fanRestore, .fanResume]
        return bar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        switch identifier {
        case .fanSelector: item.view = fanButtons
        case .fanSlider: item.view = slider
        case .fanValue: item.view = valueLabel
        case .fanRestore: item.view = restoreButton
        case .fanResume: item.view = resumeButton
        default: return nil
        }
        return item
    }

    @objc private func selectFan(_ sender: NSButton) {
        if model?.busy == false { flush() }
        pendingTask?.cancel()
        pendingTask = nil
        pending = nil
        selectedFanID = sender.tag
        refresh()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let rpm = Int(sender.doubleValue.rounded())
        pending = (selectedFanID, rpm)
        valueLabel.stringValue = "→ \(rpm) RPM"
        scheduleFlush(after: 400_000_000)
    }

    @objc private func restoreAutomatic(_ sender: NSButton) {
        pendingTask?.cancel()
        pendingTask = nil
        pending = nil
        model?.restoreAutomatic(fanID: selectedFanID)
    }

    /// Hands every fan back to the global curve and rules, like the window's button.
    @objc private func resumeControl(_ sender: NSButton) {
        pendingTask?.cancel()
        pendingTask = nil
        pending = nil
        model?.resumeThermalControl()
    }

    private func scheduleFlush(after nanoseconds: UInt64) {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Sends the pending speed, or tries again shortly if a control request is running.
    private func flush() {
        pendingTask?.cancel()
        pendingTask = nil
        guard let target = pending else { return }
        guard let model else { pending = nil; return }
        if model.busy {
            scheduleFlush(after: 300_000_000)
            return
        }
        pending = nil
        model.set(fanID: target.fanID, rpm: target.rpm, seconds: 0)
        refresh()
    }
}

private extension NSTouchBarItem.Identifier {
    static let fanSelector = NSTouchBarItem.Identifier("local.mfan.fan-selector")
    static let fanSlider = NSTouchBarItem.Identifier("local.mfan.fan-slider")
    static let fanValue = NSTouchBarItem.Identifier("local.mfan.fan-value")
    static let fanRestore = NSTouchBarItem.Identifier("local.mfan.fan-restore")
    static let fanResume = NSTouchBarItem.Identifier("local.mfan.fan-resume")
}
