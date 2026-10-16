import XCTest
@testable import MFan

final class ThermalTests: XCTestCase {
    let fans = [RuleFanRange(id: 0, lower: 1000, upper: 5000),
                RuleFanRange(id: 1, lower: 2000, upper: 8000)]
    let curve = ThermalConfiguration(enabled: true, points: [
        .init(temperature: 40, percent: 0), .init(temperature: 80, percent: 100)
    ])

    func testCurveInterpolationAndEndpoints() {
        XCTAssertEqual(curve.percent(at: 20), 0)
        XCTAssertEqual(curve.percent(at: 60), 50)
        XCTAssertEqual(curve.percent(at: 100), 100)
        XCTAssertEqual(resolve(60)?.targets, [0: 3000, 1: 5000])
    }

    func testInvalidTemperatureNeverProducesTargets() {
        for temperature: Double? in [nil, .nan, .infinity, -.infinity, -1, 151] {
            XCTAssertNil(resolve(temperature, rules: [ProcessRule(name: "app", rpm: 4000)]))
        }
    }

    func testRulesRampIndependentlyAndClampPerFan() {
        let rules = [ProcessRule(name: "APP.app", rpm: 6000, triggerTemp: 60),
                     ProcessRule(name: "app", rpm: 8000, fanID: 1, triggerTemp: 90)]
        let config = ThermalConfiguration()
        XCTAssertEqual(resolve(80, rules: rules, config: config)?.targets, [0: 3000, 1: 4000])
        XCTAssertEqual(resolve(110, rules: rules, config: config)?.targets, [0: 5000, 1: 8000])
        XCTAssertEqual(resolve(59, rules: rules, config: config)?.targets, [:])
        XCTAssertEqual(resolve(60, rules: rules, config: config)?.targets, [0: 1000, 1: 2000])
    }

    func testLegacyJSONUsesDefaultStartAndNoFixedRPM() throws {
        let data = Data("[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"app\",\"rpm\":4000,\"enabled\":true}]".utf8)
        let rules = try JSONDecoder().decode([ProcessRule].self, from: data)
        XCTAssertNil(rules[0].fanID)
        XCTAssertNil(rules[0].triggerTemp)
        XCTAssertEqual(resolve(70, rules: rules, config: ThermalConfiguration())?.targets, [0: 2500, 1: 3000])
    }

    func testGlobalAndRulesTakeMaximum() {
        let rules = [ProcessRule(name: "app", rpm: 8000, triggerTemp: 40)]
        XCTAssertEqual(resolve(60, rules: rules)?.targets, [0: 3000, 1: 5000])
        XCTAssertNil(ThermalResolver.resolve(configuration: ThermalConfiguration(), rules: rules,
            running: ["application"], fans: fans, temperature: 80))
        XCTAssertNil(resolve(80, rules: [ProcessRule(name: "app", rpm: 4000, enabled: false)], config: ThermalConfiguration()))
    }

    func testValidationPersistenceAndCorruption() {
        let defaults = UserDefaults(suiteName: "ThermalTests.\(UUID())")!
        defer { defaults.removeObject(forKey: ThermalStore.defaultsKey) }
        XCTAssertTrue(ThermalStore.save(curve, to: defaults))
        XCTAssertEqual(ThermalStore.load(from: defaults), curve)
        var invalid = curve
        invalid.points[1].temperature = 40
        XCTAssertFalse(ThermalStore.save(invalid, to: defaults))
        XCTAssertEqual(ThermalStore.load(from: defaults), curve)
        invalid.points[1].temperature = .nan
        XCTAssertFalse(invalid.isValid)
        invalid = curve
        invalid.points[0].percent = 101
        XCTAssertFalse(invalid.isValid)
        invalid.points = []
        XCTAssertFalse(invalid.isValid)
        defaults.set(Data("broken".utf8), forKey: ThermalStore.defaultsKey)
        XCTAssertEqual(ThermalStore.load(from: defaults), ThermalConfiguration())
    }

    func testBadBoundsAndInvalidRulesAreIgnored() {
        let badFans = [RuleFanRange(id: 0, lower: 5000, upper: 1000),
                       RuleFanRange(id: 1, lower: 0, upper: Int.max)]
        XCTAssertNil(ThermalResolver.resolve(configuration: curve, rules: [], running: [], fans: badFans, temperature: 60))
        XCTAssertNil(resolve(80, rules: [ProcessRule(name: "app", rpm: 4000, triggerTemp: 121)], config: ThermalConfiguration()))
        XCTAssertNil(ThermalResolver.resolve(configuration: curve, rules: [], running: [], fans: [fans[0], fans[0]], temperature: 60))
    }

    func testPercentRuleScalesToEachFansOwnRange() {
        let rules = [ProcessRule(name: "app", rpm: 0, triggerTemp: 40, percent: 50)]
        let config = ThermalConfiguration()
        // At full ramp the target is 50% of each fan's own range, not one shared RPM.
        XCTAssertEqual(resolve(100, rules: rules, config: config)?.targets, [0: 3000, 1: 5000])
        // Halfway up the ramp each fan is halfway between its minimum and that target.
        XCTAssertEqual(resolve(70, rules: rules, config: config)?.targets, [0: 2000, 1: 3500])
        let full = [ProcessRule(name: "app", rpm: 0, triggerTemp: 40, percent: 100)]
        XCTAssertEqual(resolve(100, rules: full, config: config)?.targets, [0: 5000, 1: 8000])
    }

    func testPercentRuleOnOneFanLeavesTheOtherAlone() {
        let rules = [ProcessRule(name: "app", rpm: 0, fanID: 1, triggerTemp: 40, percent: 50)]
        XCTAssertEqual(resolve(100, rules: rules, config: ThermalConfiguration())?.targets, [1: 5000])
    }

    func testPercentRuleValidationAndPersistence() throws {
        XCTAssertTrue(ProcessRule(name: "app", rpm: 0, percent: 1).isValid)
        XCTAssertTrue(ProcessRule(name: "app", rpm: 0, percent: 100).isValid)
        XCTAssertFalse(ProcessRule(name: "app", rpm: 0, percent: 0).isValid)
        XCTAssertFalse(ProcessRule(name: "app", rpm: 4000, percent: 101).isValid)
        XCTAssertFalse(ProcessRule(name: "app", rpm: 0).isValid)
        XCTAssertTrue(ProcessRule(name: "app", rpm: 4000).isValid)

        let defaults = UserDefaults(suiteName: "ThermalTests.\(UUID())")!
        let rule = ProcessRule(name: "app", rpm: 0, triggerTemp: 60, percent: 40)
        ProcessRuleStore.save([rule], to: defaults)
        XCTAssertEqual(ProcessRuleStore.load(from: defaults), [rule])
    }

    func testStandardBezierIsValidAndSamplesToAValidPolyline() {
        XCTAssertTrue(ThermalBezier.standard.isValid)
        let config = ThermalConfiguration()
        XCTAssertTrue(config.isValid)
        XCTAssertEqual(config.curve, ThermalBezier.standard)
        XCTAssertEqual(config.points.count, 13)
        XCTAssertEqual(config.points.first?.temperature, 40)
        XCTAssertEqual(config.points.first?.percent, 0)
        XCTAssertEqual(config.points.last?.temperature, 90)
        XCTAssertEqual(config.points.last?.percent, 100)
    }

    func testBezierMovesKeepBothAxesOrdered() {
        let moves: [(ThermalBezier.Handle, Double, Double)] = [
            (.control1, 300, -50), (.control2, -10, 500), (.start, 200, 90), (.end, 0, 0),
            (.control1, 85, 100), (.control2, 30, 5), (.start, 20, 0), (.end, 120, 100)
        ]
        var curve = ThermalBezier.standard
        for (handle, temperature, percent) in moves {
            curve.move(handle, toTemperature: temperature, percent: percent)
            XCTAssertTrue(curve.isValid, "\(handle) -> \(temperature), \(percent)")
            XCTAssertTrue(ThermalConfiguration(enabled: true, curve: curve).isValid)
        }
        var ignored = ThermalBezier.standard
        ignored.move(.start, toTemperature: .nan, percent: 10)
        XCTAssertEqual(ignored, ThermalBezier.standard)
    }

    func testBezierEndpointsKeepMinimumSpan() {
        var curve = ThermalBezier.standard
        curve.move(.start, toTemperature: 119, percent: 0)
        XCTAssertEqual(curve[.start].temperature, curve[.end].temperature - ThermalBezier.minimumSpan)
        XCTAssertTrue(curve.isValid)
    }

    func testBezierPercentIsMonotoneAndFlatOutsideEndpoints() {
        let curve = ThermalBezier.standard
        XCTAssertEqual(curve.percent(at: 0), 0)
        XCTAssertEqual(curve.percent(at: 40), 0)
        XCTAssertEqual(curve.percent(at: 90), 100)
        XCTAssertEqual(curve.percent(at: 150), 100)
        var previous = -1.0
        for temperature in stride(from: 40.0, through: 90.0, by: 0.5) {
            let value = curve.percent(at: temperature)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testBezierConfigurationPersistsAndLegacyPolylineStillLoads() throws {
        let defaults = UserDefaults(suiteName: "ThermalTests.\(UUID())")!
        var curve = ThermalBezier.standard
        curve.move(.control1, toTemperature: 55, percent: 20)
        let config = ThermalConfiguration(enabled: true, curve: curve)
        XCTAssertTrue(ThermalStore.save(config, to: defaults))
        XCTAssertEqual(ThermalStore.load(from: defaults), config)

        let legacy = Data("{\"enabled\":true,\"points\":[{\"temperature\":40,\"percent\":0},{\"temperature\":80,\"percent\":100}]}".utf8)
        let decoded = try JSONDecoder().decode(ThermalConfiguration.self, from: legacy)
        XCTAssertNil(decoded.curve)
        XCTAssertTrue(decoded.isValid)
        // Fitting a straight polyline reproduces its endpoints.
        let fitted = ThermalBezier.fitting(decoded.points)
        XCTAssertEqual(fitted[.start], decoded.points[0])
        XCTAssertEqual(fitted[.end], decoded.points[1])
        XCTAssertTrue(fitted.isValid)
        XCTAssertEqual(ThermalBezier.fitting([]), ThermalBezier.standard)
    }

    func testRuleForUnknownFanIsInert() {
        let rules = [ProcessRule(name: "app", rpm: 0, fanID: 7, triggerTemp: 40, percent: 50)]
        XCTAssertNil(resolve(100, rules: rules, config: ThermalConfiguration()))
    }

    func testTieListsAllWinnersInRuleOrder() {
        let rules = [ProcessRule(name: "A", rpm: 0, triggerTemp: 40, percent: 50),
                     ProcessRule(name: "B", rpm: 0, triggerTemp: 40, percent: 50)]
        let match = ThermalResolver.resolve(configuration: ThermalConfiguration(), rules: rules,
                                            running: ["a", "b"], fans: fans, temperature: 100)
        XCTAssertEqual(match?.targets, [0: 3000, 1: 5000])
        XCTAssertEqual(match?.winners, ["A", "B"])
    }

    func testRuleBelowStartTemperatureIsArmedNotActive() {
        let rule = ProcessRule(name: "app", rpm: 0, triggerTemp: 70, percent: 50)
        let match = resolve(60, rules: [rule], config: ThermalConfiguration())
        XCTAssertEqual(match?.targets, [:])
        XCTAssertEqual(match?.armedIDs, [rule.id])
        XCTAssertEqual(match?.activeIDs, [])
    }

    func testTemperatureOnlyRuleNeedsNoProcess() {
        let rule = ProcessRule(name: "", rpm: 0, triggerTemp: 40, percent: 50)
        let match = ThermalResolver.resolve(configuration: ThermalConfiguration(), rules: [rule],
                                            running: [], fans: fans, temperature: 100)
        XCTAssertEqual(match?.targets, [0: 3000, 1: 5000])
        XCTAssertEqual(match?.winners, ["温度触发"])
    }

    func testRPMSummaryJoinsSharedOrPerFanTargets() {
        func match(_ targets: [Int: Int]) -> ProcessRuleMatch {
            ProcessRuleMatch(targets: targets, winners: [], activeIDs: [], armedIDs: [])
        }
        XCTAssertEqual(match([0: 3000, 1: 3000]).rpmSummary, "3000 RPM")
        XCTAssertEqual(match([0: 3000, 1: 5000]).rpmSummary, "#0 3000 · #1 5000 RPM")
        XCTAssertEqual(match([:]).rpmSummary, "")
    }

    func testPreviewShowsEachFansRPM() {
        XCTAssertEqual(ProcessRulesSection.preview(percent: 50, fans: fans), "#0 3000 · #1 5000 RPM")
        XCTAssertEqual(ProcessRulesSection.applicableFans(for: 1, in: fans), [fans[1]])
        XCTAssertEqual(ProcessRulesSection.applicableFans(for: nil, in: fans), fans)
    }

    private func resolve(_ temperature: Double?, rules: [ProcessRule] = [],
                         config: ThermalConfiguration? = nil) -> ProcessRuleMatch? {
        ThermalResolver.resolve(configuration: config ?? curve, rules: rules, running: ["app"],
                                fans: fans, temperature: temperature)
    }
}
