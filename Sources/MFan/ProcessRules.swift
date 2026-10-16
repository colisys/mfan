import Darwin
import Foundation

enum RuleTemperature {
    static let range = 40...100
    static let step = 5
    static let defaultCelsius = 80
    /// Once fired, a rule holds until the CPU falls this far below its threshold,
    /// so the fan does not flap on and off around the threshold.
    static let hysteresis = 5.0
}

/// "While this process runs (and/or the CPU is hot enough), hold the fan(s) at `rpm`."
struct ProcessRule: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var rpm: Int
    var enabled: Bool
    /// nil applies to every fan. Rules saved before per-fan support decode as nil.
    var fanID: Int?
    /// CPU °C at which the rule fires. nil fires as soon as the process runs.
    /// Rules saved before temperature support decode as nil.
    var triggerTemp: Int?

    init(id: UUID = UUID(), name: String, rpm: Int, enabled: Bool = true, fanID: Int? = nil,
         triggerTemp: Int? = nil) {
        self.id = id
        self.name = name
        self.rpm = rpm
        self.enabled = enabled
        self.fanID = fanID
        self.triggerTemp = triggerTemp
    }

    /// An empty name means no process condition: the rule depends on temperature alone.
    var isTemperatureOnly: Bool { ProcessRuleResolver.normalized(name).isEmpty }
    var displayName: String { isTemperatureOnly ? "温度触发" : name }
}

enum ProcessRuleStore {
    static let defaultsKey = "processRules"

    static func load(from defaults: UserDefaults = .standard) -> [ProcessRule] {
        guard let data = defaults.data(forKey: defaultsKey),
              let rules = try? JSONDecoder().decode([ProcessRule].self, from: data) else { return [] }
        return rules.filter { rule in
            let validTemperature = rule.triggerTemp.map { (20...120).contains($0) } ?? true
            // A rule needs a process, a temperature, or both.
            let hasCondition = !rule.isTemperatureOnly || rule.triggerTemp != nil
            return validTemperature && hasCondition && rule.rpm > 0 && (rule.fanID ?? 0) >= 0
        }
    }

    static func save(_ rules: [ProcessRule], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

/// The outcome of evaluating all rules against the running processes.
struct ProcessRuleMatch: Equatable {
    /// Target RPM per fan ID, for fans with at least one matching rule.
    let targets: [Int: Int]
    /// Names of the rules which set a fan's highest RPM.
    let winners: [String]
    /// Every enabled rule whose process is currently running.
    let activeIDs: Set<UUID>
    /// Rules whose process runs but whose temperature has not been reached yet.
    let armedIDs: Set<UUID>

    /// "3000 RPM" when all fans share one target, otherwise "#0 3000 · #1 4000 RPM".
    var rpmSummary: String {
        if targets.isEmpty { return "" }
        let values = Set(targets.values)
        if values.count == 1, let only = values.first { return "\(only) RPM" }
        return targets.sorted { $0.key < $1.key }
            .map { "#\($0.key) \($0.value)" }.joined(separator: " · ") + " RPM"
    }
}

enum ProcessRuleResolver {
    /// Case-insensitive, whitespace-trimmed, and tolerant of a trailing ".app".
    static func normalized(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".app") { value.removeLast(4) }
        return value
    }

    /// Per fan, every live rule (process running, or temperature-only) joins one
    /// effective rule with the LOWEST trigger temperature and the HIGHEST RPM. A rule
    /// without a temperature fires at launch, which counts as the lowest threshold.
    /// A rule with a nil `fanID` applies to every fan in `fanIDs`; one for an unknown
    /// fan is inert. `wasTriggered` adds hysteresis for fans already held.
    static func resolve(
        rules: [ProcessRule], running: Set<String>, fanIDs: [Int],
        temperature: Double? = nil, wasTriggered: Set<Int> = []
    ) -> ProcessRuleMatch? {
        let normalizedRunning = Set(running.map(normalized))
        let live = rules.filter {
            $0.enabled && $0.rpm > 0 && ($0.isTemperatureOnly
                ? $0.triggerTemp != nil
                : normalizedRunning.contains(normalized($0.name)))
        }
        var targets: [Int: Int] = [:]
        var winners: [String] = []
        var active = Set<UUID>()
        var armed = Set<UUID>()
        for fan in fanIDs {
            let applicable = live.filter { $0.fanID == nil || $0.fanID == fan }
            guard let top = applicable.map(\.rpm).max() else { continue }
            let threshold: Int? = applicable.contains { $0.triggerTemp == nil }
                ? nil : applicable.compactMap(\.triggerTemp).min()
            let fires: Bool
            if let threshold {
                let release = wasTriggered.contains(fan) ? RuleTemperature.hysteresis : 0
                // An unreadable temperature never fires a temperature condition.
                fires = (temperature ?? -.infinity) >= Double(threshold) - release
            } else {
                fires = true
            }
            if fires {
                targets[fan] = top
                for rule in applicable {
                    active.insert(rule.id)
                    if rule.rpm == top && !winners.contains(rule.displayName) { winners.append(rule.displayName) }
                }
            } else {
                armed.formUnion(applicable.map(\.id))
            }
        }
        armed.subtract(active)
        guard !targets.isEmpty || !armed.isEmpty else { return nil }
        return ProcessRuleMatch(targets: targets, winners: winners, activeIDs: active, armedIDs: armed)
    }
}

/// What to send to the control service to move from the last accepted state to
/// the desired one, touching only the fans whose target changed.
struct ProcessRulePlan: Equatable {
    /// Fans to hold at a rule's RPM.
    var sets: [Int: Int] = [:]
    /// Fans whose rules ended and which return to the startup setting's RPM.
    var restores: [Int: Int] = [:]
    /// Fans whose rules ended and which return to system (automatic) control.
    var releases: Set<Int> = []
    var isEmpty: Bool { sets.isEmpty && restores.isEmpty && releases.isEmpty }

    /// - applied: targets last sent by the rule engine, per fan.
    /// - owned: fans the engine may still be holding (manual actions drop a fan from it).
    /// - startup: the saved startup setting, if enabled. When a rule ends on that fan it
    ///   goes back to this RPM; every other fan goes back to automatic.
    static func make(
        desired: [Int: Int], applied: [Int: Int], owned: Set<Int>, knownFans: Set<Int>,
        startup: (fan: Int, rpm: Int)? = nil
    ) -> ProcessRulePlan {
        var plan = ProcessRulePlan()
        for (fan, rpm) in desired where knownFans.contains(fan) && applied[fan] != rpm {
            plan.sets[fan] = rpm
        }
        for fan in owned where desired[fan] == nil && knownFans.contains(fan) {
            if let startup, startup.fan == fan, startup.rpm > 0 {
                plan.restores[fan] = startup.rpm
            } else {
                plan.releases.insert(fan)
            }
        }
        return plan
    }
}

enum ProcessScanner {
    /// Names which identify a process by its executable path: the executable
    /// file name, plus the outermost enclosing ".app" bundle name if any.
    /// "/Applications/UTM.app/Contents/MacOS/UTM" yields ["UTM", "UTM"].
    static func names(forPath path: String) -> [String] {
        var result: [String] = []
        let executable = (path as NSString).lastPathComponent
        if !executable.isEmpty { result.append(executable) }
        if let app = appName(forPath: path) { result.append(app) }
        return result
    }

    static func appName(forPath path: String) -> String? {
        guard let bundle = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) else { return nil }
        let name = String(bundle.dropLast(4))
        return name.isEmpty ? nil : name
    }

    /// Names of every process visible to this user. Cheap enough (no subprocess)
    /// to call on each refresh from a background queue.
    static func runningNames() -> Set<String> {
        var result = Set<String>()
        for path in runningPaths() { result.formUnion(names(forPath: path)) }
        return result
    }

    /// Sorted names of running third-party apps, for the rule picker.
    static func runningAppNames() -> [String] {
        let apps = Set(runningPaths().filter { !$0.hasPrefix("/System/") }.compactMap(appName(forPath:)))
        return apps.filter { $0 != "MFan" }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func runningPaths() -> [String] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return [] }

        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN; the macro is not imported into Swift.
        var buffer = [CChar](repeating: 0, count: 4096)
        var paths: [String] = []
        for pid in pids.prefix(min(count, pids.count)) where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
            paths.append(String(decoding: bytes, as: UTF8.self))
        }
        return paths
    }
}
