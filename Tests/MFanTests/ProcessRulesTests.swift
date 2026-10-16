import FanCore
import XCTest
@testable import MFan

final class ProcessRulesTests: XCTestCase {
    private let fans = [0, 1]

    func testNormalizationIgnoresCaseWhitespaceAndAppSuffix() {
        XCTAssertEqual(ProcessRuleResolver.normalized("  UTM.app "), "utm")
        XCTAssertEqual(ProcessRuleResolver.normalized("UTM"), "utm")
        XCTAssertEqual(ProcessRuleResolver.normalized("   "), "")
    }

    // MARK: Planner

    func testPlanSetsOnlyChangedFans() {
        let plan = ProcessRulePlan.make(
            desired: [0: 3000, 1: 4000], applied: [0: 3000], owned: [0], knownFans: [0, 1]
        )
        XCTAssertEqual(plan.sets, [1: 4000])
        XCTAssertTrue(plan.releases.isEmpty)
    }

    func testPlanReleasesOnlyFansNoLongerWanted() {
        let plan = ProcessRulePlan.make(
            desired: [0: 3000], applied: [0: 3000, 1: 4000], owned: [0, 1], knownFans: [0, 1]
        )
        XCTAssertTrue(plan.sets.isEmpty)
        XCTAssertEqual(plan.releases, [1])
    }

    func testPlanIsEmptyWhenNothingChanged() {
        let plan = ProcessRulePlan.make(desired: [0: 3000], applied: [0: 3000], owned: [0], knownFans: [0])
        XCTAssertTrue(plan.isEmpty)
    }

    func testManualOverrideIsNotReplayedUntilTargetChanges() {
        // Fan 0 was taken over manually: it is no longer owned, but the applied target stays.
        var plan = ProcessRulePlan.make(desired: [0: 3000], applied: [0: 3000], owned: [], knownFans: [0])
        XCTAssertTrue(plan.isEmpty)
        plan = ProcessRulePlan.make(desired: [0: 3500], applied: [0: 3000], owned: [], knownFans: [0])
        XCTAssertEqual(plan.sets, [0: 3500])
    }

    func testPlanRestoresStartupFanAndReleasesTheOthers() {
        let plan = ProcessRulePlan.make(
            desired: [:], applied: [0: 5000, 1: 5000], owned: [0, 1], knownFans: [0, 1],
            startup: (fan: 0, rpm: 2500)
        )
        XCTAssertEqual(plan.restores, [0: 2500])
        XCTAssertEqual(plan.releases, [1])
    }

    func testPlanWithoutStartupReleasesEveryFan() {
        let plan = ProcessRulePlan.make(
            desired: [:], applied: [0: 5000], owned: [0], knownFans: [0]
        )
        XCTAssertTrue(plan.restores.isEmpty)
        XCTAssertEqual(plan.releases, [0])
    }

    func testPlanIgnoresUnknownFans() {
        let plan = ProcessRulePlan.make(desired: [5: 3000], applied: [:], owned: [6], knownFans: [0])
        XCTAssertTrue(plan.isEmpty)
    }

    // MARK: Temperature source and store

    func testCPUTemperaturePrefersDieSensor() {
        let sensors = [
            TemperatureSnapshot(id: "a", name: "CPU Proximity", celsius: 50),
            TemperatureSnapshot(id: "b", name: "CPU Die", celsius: 70),
        ]
        XCTAssertEqual(TemperatureSource.cpuCelsius(sensors), 70)
        XCTAssertNil(TemperatureSource.cpuCelsius([TemperatureSnapshot(id: "c", name: "Battery", celsius: 30)]))
    }

    func testTemperatureRuleStoreValidation() throws {
        let suite = "ProcessRulesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tempOnly = ProcessRule(name: "", rpm: 4000, triggerTemp: 80)
        let withApp = ProcessRule(name: "UTM", rpm: 3000, triggerTemp: 70)
        ProcessRuleStore.save([
            tempOnly, withApp,
            ProcessRule(name: "", rpm: 4000),
            ProcessRule(name: "X", rpm: 4000, triggerTemp: 5),
            ProcessRule(name: "Y", rpm: 4000, triggerTemp: 500),
        ], to: defaults)
        XCTAssertEqual(ProcessRuleStore.load(from: defaults), [tempOnly, withApp])
    }

    // MARK: Scanner and store

    func testNamesFromAppBundleHelperPath() {
        let path = "/Applications/UTM.app/Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMUHelper"
        XCTAssertEqual(ProcessScanner.names(forPath: path), ["QEMUHelper", "UTM"])
        XCTAssertEqual(ProcessScanner.appName(forPath: "/usr/bin/ssh"), nil)
        XCTAssertEqual(ProcessScanner.names(forPath: "/usr/local/bin/ffmpeg"), ["ffmpeg"])
    }

    func testStoreRoundTripDropsInvalidRules() throws {
        let suite = "ProcessRulesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let good = ProcessRule(name: "UTM", rpm: 3000, fanID: 1)
        ProcessRuleStore.save([
            good,
            ProcessRule(name: " ", rpm: 3000),
            ProcessRule(name: "X", rpm: 0),
            ProcessRule(name: "Y", rpm: 3000, fanID: -1),
        ], to: defaults)
        XCTAssertEqual(ProcessRuleStore.load(from: defaults), [good])
    }

    func testRulesSavedWithoutFanIDStillLoadAsAllFans() throws {
        let suite = "ProcessRulesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let legacy = "[{\"id\":\"\(id.uuidString)\",\"name\":\"UTM\",\"rpm\":3000,\"enabled\":true}]"
        defaults.set(Data(legacy.utf8), forKey: ProcessRuleStore.defaultsKey)
        XCTAssertEqual(ProcessRuleStore.load(from: defaults), [ProcessRule(id: id, name: "UTM", rpm: 3000)])
    }

    func testScannerFindsCurrentProcess() {
        XCTAssertFalse(ProcessScanner.runningNames().isEmpty)
    }
}
