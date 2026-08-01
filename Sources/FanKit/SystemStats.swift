import Foundation
import IOKit.ps

public struct CPULoad: Codable, Sendable {
    public var user: Double
    public var system: Double
    public var idle: Double
    public var nice: Double
    public var perCore: [Double]

    /// Fraction of capacity in use, 0...1.
    public var busy: Double { (1.0 - idle).clamped(to: 0...1) }
}

public struct MemoryStats: Codable, Sendable {
    public var totalBytes: UInt64
    public var usedBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var freeBytes: UInt64
    /// 1 = normal, 2 = warning, 4 = critical (kernel's own classification).
    public var pressureLevel: Int

    public var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
}

public struct BatteryStats: Codable, Sendable {
    public var percentage: Double
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var cycleCount: Int?
    public var healthPercent: Double?
    public var minutesRemaining: Int?
}

public enum ThermalPressure: String, Codable, Sendable {
    case nominal, fair, serious, critical, unknown

    static func current() -> ThermalPressure {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }
}

/// CPU, memory, battery and thermal-pressure readings from public APIs.
/// None of this needs root.
public final class SystemStatsReader {

    private var previousTicks: [[UInt32]] = []
    private let lock = NSLock()

    public init() {}

    // MARK: - CPU

    public func readCPU() -> CPULoad {
        var cpuInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0

        let rc = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &cpuInfo, &infoCount)
        guard rc == KERN_SUCCESS, let info = cpuInfo else {
            return CPULoad(user: 0, system: 0, idle: 1, nice: 0, perCore: [])
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        let states = Int(CPU_STATE_MAX)
        var current: [[UInt32]] = []
        current.reserveCapacity(Int(cpuCount))
        for c in 0..<Int(cpuCount) {
            var ticks = [UInt32](repeating: 0, count: states)
            for s in 0..<states {
                ticks[s] = UInt32(bitPattern: info[c * states + s])
            }
            current.append(ticks)
        }

        lock.lock()
        let previous = previousTicks
        previousTicks = current
        lock.unlock()

        guard previous.count == current.count else {
            // First sample has no baseline to diff against.
            return CPULoad(user: 0, system: 0, idle: 1, nice: 0,
                           perCore: [Double](repeating: 0, count: current.count))
        }

        var totals = [Double](repeating: 0, count: states)
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)

        for c in 0..<current.count {
            var deltas = [Double](repeating: 0, count: states)
            var sum = 0.0
            for s in 0..<states {
                let d = Double(current[c][s] &- previous[c][s])
                deltas[s] = d
                sum += d
                totals[s] += d
            }
            let idle = sum > 0 ? deltas[Int(CPU_STATE_IDLE)] / sum : 1
            perCore.append((1 - idle).clamped(to: 0...1))
        }

        let grand = totals.reduce(0, +)
        guard grand > 0 else {
            return CPULoad(user: 0, system: 0, idle: 1, nice: 0, perCore: perCore)
        }
        return CPULoad(user: totals[Int(CPU_STATE_USER)] / grand,
                       system: totals[Int(CPU_STATE_SYSTEM)] / grand,
                       idle: totals[Int(CPU_STATE_IDLE)] / grand,
                       nice: totals[Int(CPU_STATE_NICE)] / grand,
                       perCore: perCore)
    }

    // MARK: - Memory

    public func readMemory() -> MemoryStats {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let total = ProcessInfo.processInfo.physicalMemory
        guard rc == KERN_SUCCESS else {
            return MemoryStats(totalBytes: total, usedBytes: 0, wiredBytes: 0,
                               compressedBytes: 0, freeBytes: total, pressureLevel: 1)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let active = UInt64(stats.active_count) * pageSize
        let free = UInt64(stats.free_count) * pageSize

        return MemoryStats(totalBytes: total,
                           usedBytes: active + wired + compressed,
                           wiredBytes: wired,
                           compressedBytes: compressed,
                           freeBytes: free,
                           pressureLevel: Self.memoryPressureLevel())
    }

    private static func memoryPressureLevel() -> Int {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            return Int(level)
        }
        return 1
    }

    // MARK: - Battery

    public func readBattery() -> BatteryStats? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }

            let state = desc[kIOPSPowerSourceStateKey] as? String
            let minutes = desc[kIOPSTimeToEmptyKey] as? Int

            return BatteryStats(
                percentage: Double(current) / Double(max) * 100.0,
                isCharging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                isPluggedIn: state == kIOPSACPowerValue,
                cycleCount: Self.batteryCycleCount(),
                healthPercent: nil,
                minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil
            )
        }
        return nil
    }

    private static func batteryCycleCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString,
                                                          kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int else { return nil }
        return value
    }

    // MARK: - Thermal

    public func readThermalPressure() -> ThermalPressure { .current() }
}
