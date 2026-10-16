import Foundation

struct ThermalPoint: Codable, Equatable {
    var temperature: Double
    /// Percentage of the usable range, not of maximum RPM.
    var percent: Double
}

/// A cubic Bezier the user drags: start, two control handles, end. It is sampled into
/// `ThermalConfiguration.points`, so the resolver and storage still work on a polyline.
/// Constraints keep both axes monotone, which makes the sampled points a valid curve.
struct ThermalBezier: Codable, Equatable {
    enum Handle: Int, CaseIterable { case start, control1, control2, end }

    static let temperatureRange = 20.0...120.0
    static let minimumSpan = 10.0
    static let standard = ThermalBezier(nodes: [
        .init(temperature: 40, percent: 0), .init(temperature: 62, percent: 8),
        .init(temperature: 70, percent: 62), .init(temperature: 90, percent: 100)
    ])

    var nodes: [ThermalPoint]

    subscript(handle: Handle) -> ThermalPoint { nodes[handle.rawValue] }

    var isValid: Bool {
        guard nodes.count == 4, nodes.allSatisfy({
            $0.temperature.isFinite && $0.percent.isFinite
                && Self.temperatureRange.contains($0.temperature) && (0...100).contains($0.percent)
        }) else { return false }
        let t = nodes.map(\.temperature), p = nodes.map(\.percent)
        return t[3] - t[0] >= Self.minimumSpan
            && zip(t, t.dropFirst()).allSatisfy { $0 <= $1 }
            && zip(p, p.dropFirst()).allSatisfy { $0 <= $1 }
    }

    /// Moves one node to whole-degree / whole-percent coordinates, pushing the others
    /// just enough to keep both axes ordered and the endpoints at least `minimumSpan` apart.
    mutating func move(_ handle: Handle, toTemperature rawTemperature: Double, percent rawPercent: Double) {
        guard nodes.count == 4, rawTemperature.isFinite, rawPercent.isFinite else { return }
        var t = rawTemperature.rounded()
        var p = min(100, max(0, rawPercent.rounded()))
        var n = nodes
        switch handle {
        case .start:
            t = min(max(t, Self.temperatureRange.lowerBound), n[3].temperature - Self.minimumSpan)
            p = min(p, n[3].percent)
            n[0] = .init(temperature: t, percent: p)
            n[1].temperature = max(n[1].temperature, t)
            n[2].temperature = max(n[2].temperature, n[1].temperature)
            n[1].percent = max(n[1].percent, p)
            n[2].percent = max(n[2].percent, n[1].percent)
        case .end:
            t = max(min(t, Self.temperatureRange.upperBound), n[0].temperature + Self.minimumSpan)
            p = max(p, n[0].percent)
            n[3] = .init(temperature: t, percent: p)
            n[2].temperature = min(n[2].temperature, t)
            n[1].temperature = min(n[1].temperature, n[2].temperature)
            n[2].percent = min(n[2].percent, p)
            n[1].percent = min(n[1].percent, n[2].percent)
        case .control1:
            t = min(max(t, n[0].temperature), n[3].temperature)
            p = min(max(p, n[0].percent), n[3].percent)
            n[1] = .init(temperature: t, percent: p)
            n[2].temperature = max(n[2].temperature, t)
            n[2].percent = max(n[2].percent, p)
        case .control2:
            t = min(max(t, n[0].temperature), n[3].temperature)
            p = min(max(p, n[0].percent), n[3].percent)
            n[2] = .init(temperature: t, percent: p)
            n[1].temperature = min(n[1].temperature, t)
            n[1].percent = min(n[1].percent, p)
        }
        nodes = n
    }

    /// Range percentage at a temperature; flat beyond both endpoints.
    func percent(at temperature: Double) -> Double {
        guard nodes.count == 4, temperature.isFinite else { return 0 }
        if temperature <= nodes[0].temperature { return nodes[0].percent }
        if temperature >= nodes[3].temperature { return nodes[3].percent }
        return value(\.percent, at: parameter(forTemperature: temperature))
    }

    /// Evenly spaced in temperature, so the polyline stays strictly increasing.
    func sampled(count: Int = 13) -> [ThermalPoint] {
        guard nodes.count == 4, count >= 2 else { return nodes }
        let start = nodes[0].temperature, end = nodes[3].temperature
        var result: [ThermalPoint] = []
        for index in 0..<count {
            let temperature = index == count - 1
                ? end : start + (end - start) * Double(index) / Double(count - 1)
            var percent = min(100, max(0, percent(at: temperature)))
            percent = (percent * 10).rounded() / 10
            if let last = result.last { percent = max(percent, last.percent) }
            result.append(.init(temperature: (temperature * 100).rounded() / 100, percent: percent))
        }
        result[0].percent = nodes[0].percent
        result[count - 1].percent = nodes[3].percent
        return result
    }

    /// Closest Bezier to an existing polyline: same endpoints, handles on its 1/3 and 2/3 points.
    static func fitting(_ points: [ThermalPoint]) -> ThermalBezier {
        let polyline = ThermalConfiguration(enabled: false, points: points)
        guard polyline.isValid, let first = points.first, let last = points.last,
              last.temperature - first.temperature >= minimumSpan else { return .standard }
        let span = last.temperature - first.temperature
        func node(_ fraction: Double) -> ThermalPoint {
            let t = first.temperature + span * fraction
            return .init(temperature: t, percent: polyline.percent(at: t) ?? first.percent)
        }
        return ThermalBezier(nodes: [first, node(1.0 / 3), node(2.0 / 3), last])
    }

    private func value(_ key: KeyPath<ThermalPoint, Double>, at t: Double) -> Double {
        let u = 1 - t
        return u * u * u * nodes[0][keyPath: key] + 3 * u * u * t * nodes[1][keyPath: key]
            + 3 * u * t * t * nodes[2][keyPath: key] + t * t * t * nodes[3][keyPath: key]
    }

    /// Temperature is monotone in t, so bisection finds the matching parameter.
    private func parameter(forTemperature temperature: Double) -> Double {
        var low = 0.0, high = 1.0
        for _ in 0..<48 {
            let mid = (low + high) / 2
            if value(\.temperature, at: mid) < temperature { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }
}

struct ThermalConfiguration: Codable, Equatable {
    var enabled: Bool
    var points: [ThermalPoint]
    /// The draggable shape `points` were sampled from; nil for polylines saved before it existed.
    var curve: ThermalBezier?

    /// Without explicit points the configuration starts from the standard Bezier.
    init(enabled: Bool = false, points: [ThermalPoint]? = nil, curve: ThermalBezier? = nil) {
        self.enabled = enabled
        if let points {
            self.points = points
            self.curve = curve
        } else {
            let shape = curve ?? .standard
            self.points = shape.sampled()
            self.curve = shape
        }
    }

    var isValid: Bool {
        guard curve?.isValid ?? true else { return false }
        guard (2...16).contains(points.count) else { return false }
        guard points.allSatisfy({ $0.temperature.isFinite && (20...120).contains($0.temperature)
            && $0.percent.isFinite && (0...100).contains($0.percent) }) else { return false }
        return zip(points, points.dropFirst()).allSatisfy {
            $0.temperature < $1.temperature && $0.percent <= $1.percent
        }
    }

    func percent(at temperature: Double) -> Double? {
        guard isValid, ThermalResolver.validTemperature(temperature) else { return nil }
        if temperature <= points[0].temperature { return points[0].percent }
        for (a, b) in zip(points, points.dropFirst()) where temperature <= b.temperature {
            return a.percent + (b.percent - a.percent) * (temperature - a.temperature)
                / (b.temperature - a.temperature)
        }
        return points.last?.percent
    }
}

enum ThermalStore {
    static let defaultsKey = "thermalConfiguration.v1"

    static func load(from defaults: UserDefaults = .standard) -> ThermalConfiguration {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(ThermalConfiguration.self, from: data),
              value.isValid else { return ThermalConfiguration() }
        return value
    }

    @discardableResult
    static func save(_ value: ThermalConfiguration, to defaults: UserDefaults = .standard) -> Bool {
        guard value.isValid, let data = try? JSONEncoder().encode(value) else { return false }
        defaults.set(data, forKey: defaultsKey)
        return true
    }
}

/// Stateless calculation only: no hardware access, persistence or process scanning.
/// The caller must supply fresh CPU temperature and original (not raised) fan minima.
enum ThermalResolver {
    static func validTemperature(_ value: Double) -> Bool {
        value.isFinite && (0...150).contains(value)
    }

    static func resolve(configuration: ThermalConfiguration, rules: [ProcessRule],
                        running: Set<String>, fans: [RuleFanRange],
                        temperature: Double?) -> ProcessRuleMatch? {
        guard let temperature, validTemperature(temperature) else { return nil }
        let names = Set(running.map(ProcessRuleResolver.normalized))
        let live = rules.filter { $0.enabled && $0.isValid &&
            ($0.isTemperatureOnly || names.contains(ProcessRuleResolver.normalized($0.name))) }
        let percent = configuration.enabled ? configuration.percent(at: temperature) : nil
        var targets: [Int: Int] = [:]
        var winners: [String] = []
        var active = Set<UUID>()
        var armed = Set<UUID>()
        // Reject ambiguous duplicate IDs instead of depending on input order.
        let counts = Dictionary(grouping: fans, by: \.id).mapValues(\.count)
        for fan in fans where fan.id >= 0 && fan.lower >= 0 && fan.upper >= fan.lower
            && fan.upper <= 100_000 && counts[fan.id] == 1 {
            var candidates: [(String, Int)] = []
            if let percent {
                candidates.append(("全局温控", rpm(fan: fan, fraction: percent / 100, high: fan.upper)))
            }
            for rule in live where rule.fanID == nil || rule.fanID == fan.id {
                let start = Double(rule.triggerTemp ?? 40)
                guard temperature >= start else { armed.insert(rule.id); continue }
                // Preserve legacy thresholds through 120°C without a zero-width ramp.
                let end = max(100, start + 20)
                let fraction = min(1, (temperature - start) / (end - start))
                candidates.append((rule.displayName, rpm(fan: fan, fraction: fraction, high: highTarget(of: rule, on: fan))))
                active.insert(rule.id)
            }
            if let top = candidates.map({ $0.1 }).max() {
                targets[fan.id] = top
                for (name, value) in candidates where value == top && !winners.contains(name) {
                    winners.append(name)
                }
            }
        }
        armed.subtract(active)
        guard !targets.isEmpty || !armed.isEmpty else { return nil }
        return ProcessRuleMatch(targets: targets, winners: winners, activeIDs: active, armedIDs: armed)
    }

    /// RPM that `percent` of this fan's own range comes to.
    static func highTarget(percent: Int, on fan: RuleFanRange) -> Int {
        Int((Double(fan.lower) + Double(fan.upper - fan.lower) * Double(percent) / 100).rounded())
    }

    /// A percentage rule scales to each fan; a legacy rule keeps its absolute RPM.
    static func highTarget(of rule: ProcessRule, on fan: RuleFanRange) -> Int {
        rule.percent.map { highTarget(percent: $0, on: fan) } ?? rule.rpm
    }

    private static func rpm(fan: RuleFanRange, fraction: Double, high: Int) -> Int {
        let ceiling = min(fan.upper, max(fan.lower, high))
        return Int((Double(fan.lower) + Double(ceiling - fan.lower) * fraction).rounded())
    }
}
