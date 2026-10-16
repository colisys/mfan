import FanCore

enum TemperatureSource {
    static let cpuSensorNames = ["CPU Die", "CPU Proximity", "CPU Core"]

    /// The CPU temperature shared by the menu bar and the rules, or nil if no sensor is readable.
    static func cpuCelsius(_ temperatures: [TemperatureSnapshot]) -> Double? {
        cpuSensorNames.lazy.compactMap { name in
            temperatures.first(where: { $0.name == name })?.celsius
        }.first
    }
}
