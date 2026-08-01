import Foundation

/// Classification of the ~360 `T*` temperature keys the SMC exposes on Apple Silicon.
///
/// Key prefixes were mapped empirically on Mac17,7 (M5 Max). Apple does not
/// document these, so treat the groupings as well-informed inference: the
/// *values* are real, the *labels* are our best reading of them.
public enum SensorGroup: String, CaseIterable, Codable, Sendable {
    case cpu
    case gpu
    case memory
    case hotspot
    case powerDelivery
    case storage
    case battery
    case ambient
    case wireless
    case other

    public var displayName: String {
        switch self {
        case .cpu:           return "CPU"
        case .gpu:           return "GPU"
        case .memory:        return "Memory"
        case .hotspot:       return "Hotspot"
        case .powerDelivery: return "Power Delivery"
        case .storage:       return "Storage"
        case .battery:       return "Battery"
        case .ambient:       return "Ambient"
        case .wireless:      return "Wireless"
        case .other:         return "Other"
        }
    }

    /// Groups worth driving a fan curve from, in the order we present them.
    public static var curveInputs: [SensorGroup] {
        [.cpu, .gpu, .hotspot, .memory, .powerDelivery, .storage]
    }

    /// Classify by key prefix. Order matters — longer prefixes are tested first.
    public static func classify(_ key: String) -> SensorGroup {
        guard key.hasPrefix("T") else { return .other }
        let p3 = String(key.prefix(3))
        let p2 = String(key.prefix(2))

        switch p3 {
        case "TAO":               return .ambient
        case "TW0":               return .wireless
        case "TCM", "TCD", "TCH": return .powerDelivery
        case "TVV", "TMV":        return .powerDelivery
        default: break
        }

        switch p2 {
        case "Tp": return .cpu          // performance-core clusters
        case "Tg": return .gpu
        case "Tm": return .memory
        case "Tf": return .hotspot      // runs hottest of everything on this machine
        case "TV": return .powerDelivery
        case "TD", "TN": return .storage
        case "TB": return .battery
        case "Ta", "Ts": return .ambient  // skin / airflow
        default: return .other
        }
    }
}

public struct SensorReading: Codable, Sendable, Identifiable {
    public let key: String
    public let celsius: Double
    public let group: SensorGroup

    public var id: String { key }

    public init(key: String, celsius: Double, group: SensorGroup) {
        self.key = key
        self.celsius = celsius
        self.group = group
    }
}

/// A per-group aggregate. The curve engine consumes `max`, since the hottest
/// die in a cluster is what throttles, not the average.
public struct GroupSummary: Codable, Sendable, Identifiable {
    public let group: SensorGroup
    public let max: Double
    public let mean: Double
    public let count: Int

    public var id: String { group.rawValue }

    public init(group: SensorGroup, max: Double, mean: Double, count: Int) {
        self.group = group
        self.max = max
        self.mean = mean
        self.count = count
    }
}

/// Reads and caches the machine's temperature sensor set.
public final class SensorReader {
    private let smc: SMC
    private var temperatureKeys: [String] = []
    private var groupByKey: [String: SensorGroup] = [:]

    /// Readings outside this range are sensors that are unpopulated, powered
    /// down, or reporting a sentinel. Filtering here keeps aggregates honest.
    private static let plausibleRange: ClosedRange<Double> = 1.0...150.0

    public init(smc: SMC) {
        self.smc = smc
    }

    /// Enumerate the SMC once and keep the `flt`-typed `T*` keys.
    public func discover() throws {
        let all = try smc.allKeys()
        var keys: [String] = []
        var groups: [String: SensorGroup] = [:]

        for key in all where key.hasPrefix("T") {
            guard let info = try? smc.keyInfo(key), info.type == "flt ", info.size == 4 else { continue }
            keys.append(key)
            groups[key] = SensorGroup.classify(key)
        }

        temperatureKeys = keys.sorted()
        groupByKey = groups
    }

    public var discoveredKeyCount: Int { temperatureKeys.count }

    public func readAll() -> [SensorReading] {
        var out: [SensorReading] = []
        out.reserveCapacity(temperatureKeys.count)
        for key in temperatureKeys {
            guard let value = try? smc.readFloat(key) else { continue }
            let celsius = Double(value)
            guard Self.plausibleRange.contains(celsius) else { continue }
            out.append(SensorReading(key: key, celsius: celsius, group: groupByKey[key] ?? .other))
        }
        return out
    }

    public func summarize(_ readings: [SensorReading]) -> [SensorGroup: GroupSummary] {
        var buckets: [SensorGroup: [Double]] = [:]
        for r in readings { buckets[r.group, default: []].append(r.celsius) }

        var out: [SensorGroup: GroupSummary] = [:]
        for (group, values) in buckets where !values.isEmpty {
            out[group] = GroupSummary(group: group,
                                      max: values.max()!,
                                      mean: values.reduce(0, +) / Double(values.count),
                                      count: values.count)
        }
        return out
    }

    /// Convenience for the control loop: one read, straight to per-group maxima.
    public func readGroupMaxima() -> [SensorGroup: Double] {
        summarize(readAll()).mapValues(\.max)
    }
}
