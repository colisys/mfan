import Darwin
import Foundation

enum RuleTemperature {
    static let range = 40...100
    static let step = 5
    static let defaultCelsius = 80
}

/// Persisted rule. The high-temperature target is `percent` of each fan's own usable
/// range, so fans with different limits (e.g. CPU side vs GPU side) scale separately.
/// Rules saved before that decode with `percent == nil` and keep their absolute `rpm`,
/// clamped per fan.
struct ProcessRule: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// Legacy absolute high-temperature target; unused (0) once `percent` is set.
    var rpm: Int
    var enabled: Bool
    /// nil applies to every fan. Rules saved before per-fan support decode as nil.
    var fanID: Int?
    /// Starting CPU °C for continuous control; nil uses 40°C in ThermalResolver.
    /// Rules saved before temperature support decode as nil.
    var triggerTemp: Int?
    /// High-temperature target as a share (1–100) of each fan's minimum-to-maximum range.
    var percent: Int?

    init(id: UUID = UUID(), name: String, rpm: Int, enabled: Bool = true, fanID: Int? = nil,
         triggerTemp: Int? = nil, percent: Int? = nil) {
        self.id = id
        self.name = name
        self.rpm = rpm
        self.enabled = enabled
        self.fanID = fanID
        self.triggerTemp = triggerTemp
        self.percent = percent
    }

    /// An empty name means no process condition: the rule depends on temperature alone.
    var isTemperatureOnly: Bool { ProcessRuleResolver.normalized(name).isEmpty }
    var displayName: String { isTemperatureOnly ? "温度触发" : name }

    var isValid: Bool {
        let validTemperature = triggerTemp.map { (20...120).contains($0) } ?? true
        let validTarget = percent.map { (1...100).contains($0) } ?? (rpm > 0)
        return validTemperature && (!isTemperatureOnly || triggerTemp != nil)
            && validTarget && (fanID ?? 0) >= 0
    }
}

enum ProcessRuleStore {
    static let defaultsKey = "processRules"

    static func load(from defaults: UserDefaults = .standard) -> [ProcessRule] {
        guard let data = defaults.data(forKey: defaultsKey),
              let rules = try? JSONDecoder().decode([ProcessRule].self, from: data) else { return [] }
        return rules.filter(\.isValid)
    }

    static func save(_ rules: [ProcessRule], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(rules.filter(\.isValid)) else { return }
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
        startupSettings: [Int: Int] = [:],
        startup: (fan: Int, rpm: Int)? = nil
    ) -> ProcessRulePlan {
        var plan = ProcessRulePlan()
        for (fan, rpm) in desired where knownFans.contains(fan) && applied[fan] != rpm {
            plan.sets[fan] = rpm
        }
        for fan in owned where desired[fan] == nil && knownFans.contains(fan) {
            if let rpm = startupSettings[fan], rpm > 0 {
                plan.restores[fan] = rpm
            } else if let startup, startup.fan == fan, startup.rpm > 0 {
                // Compatibility for existing callers and older persisted tests.
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
