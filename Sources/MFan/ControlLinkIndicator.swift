import SwiftUI

/// State of the link to the privileged `fanctl` service.
enum ControlLinkState: Equatable {
    /// No service connection yet, or the last heartbeat failed.
    case disconnected
    /// A control request, authorization, or heartbeat is in progress.
    case communicating
    /// Connected, idle, and the last heartbeat succeeded.
    case healthy

    /// Activity wins over connection state, so authorizing or reconnecting reads
    /// as "communicating" rather than flashing red first.
    static func resolve(connected: Bool, hasError: Bool, busy: Bool, heartbeatInFlight: Bool) -> ControlLinkState {
        if busy || heartbeatInFlight { return .communicating }
        if !connected || hasError { return .disconnected }
        return .healthy
    }

    var color: Color {
        switch self {
        case .disconnected: return .red
        case .communicating: return .yellow
        case .healthy: return .green
        }
    }

    var label: String {
        switch self {
        case .disconnected: return "未连接控制服务"
        case .communicating: return "控制服务通信中"
        case .healthy: return "控制服务正常，心跳正常"
        }
    }
}

/// Keeps each displayed state on screen for a minimum time, so a sub-second
/// heartbeat shows as a visible flash and the light does not flicker.
/// Pure and clock-agnostic: the caller supplies `now` and re-calls after the
/// returned delay.
struct ControlLinkDisplayFilter {
    let minimumHold: TimeInterval
    private(set) var displayed: ControlLinkState
    private var since: TimeInterval

    init(minimumHold: TimeInterval, initial: ControlLinkState = .disconnected) {
        self.minimumHold = minimumHold
        self.displayed = initial
        // The first real state may replace the initial one immediately.
        self.since = -.infinity
    }

    /// Returns nil when the display is settled; otherwise the delay after which
    /// the caller should call `update` again with the then-current raw state.
    @discardableResult
    mutating func update(raw: ControlLinkState, now: TimeInterval) -> TimeInterval? {
        guard raw != displayed else { return nil }
        let elapsed = now - since
        if elapsed >= minimumHold {
            displayed = raw
            since = now
            return nil
        }
        return minimumHold - elapsed
    }
}

struct ControlLinkIndicator: View {
    let state: ControlLinkState

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 7, height: 7)
            .animation(.easeInOut(duration: 0.25), value: state)
            .help(state.label)
            .accessibilityElement()
            .accessibilityLabel("控制服务状态")
            .accessibilityValue(state.label)
    }
}
