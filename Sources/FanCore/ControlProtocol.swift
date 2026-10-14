import Foundation

public struct FanControlRequest: Codable, Sendable {
    public let command: String
    public let fan: Int?
    public let rpm: Double?
    public let seconds: Int?

    public init(command: String, fan: Int? = nil, rpm: Double? = nil, seconds: Int? = nil) {
        self.command = command
        self.fan = fan
        self.rpm = rpm
        self.seconds = seconds
    }
}

public struct FanControlResponse: Codable, Sendable {
    public let success: Bool
    public let message: String?
    public let error: String?

    public init(success: Bool, message: String? = nil, error: String? = nil) {
        self.success = success
        self.message = message
        self.error = error
    }
}
