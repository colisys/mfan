import XCTest
@testable import MFan

final class ProcessRulesTests: XCTestCase {
    private let fans = [0, 1]

    func testNormalizationIgnoresCaseWhitespaceAndAppSuffix() {
        XCTAssertEqual(ProcessRuleResolver.normalized("  UTM.app "), "utm")
        XCTAssertEqual(ProcessRuleResolver.normalized("UTM"), "utm")
        XCTAssertEqual(ProcessRuleResolver.normalized("   "), "")
    }

    func testNoMatchWhenProcessNotRunning() {
        let rules = [ProcessRule(name: "UTM", rpm: 4000)]
        XCTAssertNil(ProcessRuleResolver.resolve(rules: rules, running: ["Safari"], fanIDs: fans))
    }

    func testMatchIsExactNotSubstring() {
        let rules = [ProcessRule(name: "UTM", rpm: 4000)]
        XCTAssertNil(ProcessRuleResolver.resolve(rules: rules, running: ["utmpd"], fanIDs: fans))
        XCTAssertNotNil(ProcessRuleResolver.resolve(rules: rules, running: ["utm"], fanIDs: fans))
    }

    func testAllFansRuleTargetsEveryFan() {
        let rules = [ProcessRule(name: "UTM", rpm: 3000)]
        let match = ProcessRuleResolver.resolve(rules: rules, running: ["UTM"], fanIDs: fans)
        XCTAssertEqual(match?.targets, [0: 3000, 1: 3000])
        XCTAssertEqual(match?.rpmSummary, "3000 RPM")
    }

    func testHighestRPMWinsWhenSeveralMatch() {
        let utm = ProcessRule(name: "UTM", rpm: 3000)
        let ffmpeg = ProcessRule(name: "ffmpeg", rpm: 5200)
        let idle = ProcessRule(name: "Xcode", rpm: 6000)
        let match = ProcessRuleResolver.resolve(rules: [utm, ffmpeg, idle], running: ["UTM", "ffmpeg"], fanIDs: fans)
        XCTAssertEqual(match?.targets, [0: 5200, 1: 5200])
        XCTAssertEqual(match?.winners, ["ffmpeg"])
        XCTAssertEqual(match?.activeIDs, [utm.id, ffmpeg.id])
    }

    func testTieListsAllWinners() {
        let a = ProcessRule(name: "A", rpm: 4000)
        let b = ProcessRule(name: "B", rpm: 4000)
        let match = ProcessRuleResolver.resolve(rules: [a, b], running: ["a", "b"], fanIDs: fans)
        XCTAssertEqual(match?.targets[0], 4000)
        XCTAssertEqual(match?.winners, ["A", "B"])
    }

    func testPerFanRuleOnlyAffectsThatFan() {
        let rules = [ProcessRule(name: "UTM", rpm: 4000, fanID: 1)]
        let match = ProcessRuleResolver.resolve(rules: rules, running: ["UTM"], fanIDs: fans)
        XCTAssertEqual(match?.targets, [1: 4000])
    }

    func testHighestWinsIndependentlyPerFan() {
        let all = ProcessRule(name: "UTM", rpm: 3000)
        let fan1 = ProcessRule(name: "ffmpeg", rpm: 5000, fanID: 1)
        let match = ProcessRuleResolver.resolve(rules: [all, fan1], running: ["UTM", "ffmpeg"], fanIDs: fans)
        XCTAssertEqual(match?.targets, [0: 3000, 1: 5000])
        XCTAssertEqual(match?.rpmSummary, "#0 3000 · #1 5000 RPM")
        XCTAssertEqual(match?.activeIDs, [all.id, fan1.id])
    }

    func testLowerPerFanRuleDoesNotLowerAllFansRule() {
        let all = ProcessRule(name: "UTM", rpm: 4000)
        let fan0 = ProcessRule(name: "Notes", rpm: 2500, fanID: 0)
        let match = ProcessRuleResolver.resolve(rules: [all, fan0], running: ["UTM", "Notes"], fanIDs: fans)
        XCTAssertEqual(match?.targets, [0: 4000, 1: 4000])
        XCTAssertEqual(match?.winners, ["UTM"])
    }

    func testRuleForUnknownFanIsInert() {
        let rules = [ProcessRule(name: "UTM", rpm: 4000, fanID: 7)]
        XCTAssertNil(ProcessRuleResolver.resolve(rules: rules, running: ["UTM"], fanIDs: fans))
    }

    func testDisabledRulesAreIgnored() {
        let high = ProcessRule(name: "ffmpeg", rpm: 6000, enabled: false)
        let low = ProcessRule(name: "UTM", rpm: 3000)
        let match = ProcessRuleResolver.resolve(rules: [high, low], running: ["ffmpeg", "UTM"], fanIDs: fans)
        XCTAssertEqual(match?.targets[0], 3000)
    }

    func testExitingHighestFallsBackToRemainingRule() {
        let rules = [ProcessRule(name: "UTM", rpm: 3000), ProcessRule(name: "ffmpeg", rpm: 5200)]
        XCTAssertEqual(ProcessRuleResolver.resolve(rules: rules, running: ["UTM", "ffmpeg"], fanIDs: fans)?.targets[0], 5200)
        XCTAssertEqual(ProcessRuleResolver.resolve(rules: rules, running: ["UTM"], fanIDs: fans)?.targets[0], 3000)
        XCTAssertNil(ProcessRuleResolver.resolve(rules: rules, running: [], fanIDs: fans))
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
