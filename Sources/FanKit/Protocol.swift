import Foundation

/// How the daemon is deciding fan speed right now.
public enum ControlMode: String, Codable, Sendable {
    /// Hands off — Apple's SMC controller owns the fans.
    case appleAuto
    /// Fixed RPM the user pinned.
    case fixed
    /// Curve engine drives the fans from sensor input.
    case curve

    public var displayName: String {
        switch self {
        case .appleAuto: return "Auto (system)"
        case .fixed:     return "Fixed"
        case .curve:     return "Curve"
        }
    }
}

public struct FanState: Codable, Sendable, Identifiable {
    public var info: FanInfo
    public var commandedRPM: Double?
    public var safetyEngaged: Bool

    public var id: Int { info.index }

    public init(info: FanInfo, commandedRPM: Double?, safetyEngaged: Bool) {
        self.info = info
        self.commandedRPM = commandedRPM
        self.safetyEngaged = safetyEngaged
    }
}

public struct SystemStatus: Codable, Sendable {
    public var timestamp: Date
    public var fans: [FanState]
    public var groups: [GroupSummary]
    public var controlMode: ControlMode
    public var activeProfileName: String?
    public var cpu: CPULoad
    public var memory: MemoryStats
    public var battery: BatteryStats?
    public var thermalPressure: ThermalPressure
    /// True if any fan is being held up by the safety floor.
    public var safetyEngaged: Bool

    public init(timestamp: Date, fans: [FanState], groups: [GroupSummary],
                controlMode: ControlMode, activeProfileName: String?,
                cpu: CPULoad, memory: MemoryStats, battery: BatteryStats?,
                thermalPressure: ThermalPressure, safetyEngaged: Bool) {
        self.timestamp = timestamp
        self.fans = fans
        self.groups = groups
        self.controlMode = controlMode
        self.activeProfileName = activeProfileName
        self.cpu = cpu
        self.memory = memory
        self.battery = battery
        self.thermalPressure = thermalPressure
        self.safetyEngaged = safetyEngaged
    }

    public func group(_ g: SensorGroup) -> GroupSummary? {
        groups.first { $0.group == g }
    }

    public var cpuTemperature: Double { group(.cpu)?.max ?? 0 }
    public var gpuTemperature: Double { group(.gpu)?.max ?? 0 }
    public var hotspotTemperature: Double { group(.hotspot)?.max ?? 0 }

    public var primaryFanRPM: Double { fans.first?.info.actualRPM ?? 0 }

    public var averageFanRPM: Double {
        guard !fans.isEmpty else { return 0 }
        return fans.map(\.info.actualRPM).reduce(0, +) / Double(fans.count)
    }
}

/// One row of persisted history.
public struct HistorySample: Codable, Sendable {
    public var timestamp: Date
    public var fanRPM: [Double]
    public var cpuCelsius: Double
    public var gpuCelsius: Double
    public var hotspotCelsius: Double
    public var cpuBusy: Double
    public var memoryUsedFraction: Double

    public init(timestamp: Date, fanRPM: [Double], cpuCelsius: Double,
                gpuCelsius: Double, hotspotCelsius: Double,
                cpuBusy: Double, memoryUsedFraction: Double) {
        self.timestamp = timestamp
        self.fanRPM = fanRPM
        self.cpuCelsius = cpuCelsius
        self.gpuCelsius = gpuCelsius
        self.hotspotCelsius = hotspotCelsius
        self.cpuBusy = cpuBusy
        self.memoryUsedFraction = memoryUsedFraction
    }
}

// MARK: - Wire protocol
//
// Line-delimited JSON over a Unix socket. Flat request shape on purpose: it
// stays readable when poking the daemon with `nc`, and the CLI reuses it.

public enum Command: String, Codable, Sendable {
    case ping
    case status
    case sensors
    case history
    case setControlMode
    case setTarget
    case listProfiles
    case applyProfile
    case saveProfile
    case deleteProfile
    case setSafety
    case getSafety
}

public struct Request: Codable, Sendable {
    public var cmd: Command
    public var fan: Int?
    public var rpm: Double?
    public var controlMode: ControlMode?
    public var profileName: String?
    public var profile: Profile?
    public var profileID: UUID?
    public var seconds: Int?
    public var safety: SafetyPolicy?

    public init(cmd: Command, fan: Int? = nil, rpm: Double? = nil,
                controlMode: ControlMode? = nil, profileName: String? = nil,
                profile: Profile? = nil, profileID: UUID? = nil,
                seconds: Int? = nil, safety: SafetyPolicy? = nil) {
        self.cmd = cmd
        self.fan = fan
        self.rpm = rpm
        self.controlMode = controlMode
        self.profileName = profileName
        self.profile = profile
        self.profileID = profileID
        self.seconds = seconds
        self.safety = safety
    }
}

public struct Response: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: SystemStatus?
    public var sensors: [SensorReading]?
    public var profiles: [Profile]?
    public var history: [HistorySample]?
    public var safety: SafetyPolicy?

    public init(ok: Bool, error: String? = nil, status: SystemStatus? = nil,
                sensors: [SensorReading]? = nil, profiles: [Profile]? = nil,
                history: [HistorySample]? = nil, safety: SafetyPolicy? = nil) {
        self.ok = ok
        self.error = error
        self.status = status
        self.sensors = sensors
        self.profiles = profiles
        self.history = history
        self.safety = safety
    }

    public static func failure(_ message: String) -> Response {
        Response(ok: false, error: message)
    }
}

public enum IPC {
    /// Root-owned socket. The daemon chmods it so the console user can talk to it.
    public static let socketPath = "/var/run/fancontrold.sock"

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
