import Foundation

/// In-process, unprivileged monitoring.
///
/// Every SMC *read* works as a normal user — sensors, fan RPM, fan mode, the
/// hardware range, all of it. Only writes come back `kIOReturnNotPrivileged`.
/// So the app does not need the daemon to show you what your machine is doing;
/// it needs the daemon only to change it.
///
/// This is the fallback the UI uses when `fand` isn't installed, which lets the
/// app be useful the moment you launch it with no setup at all.
public final class LocalMonitor {

    private let smc: SMC
    private let sensors: SensorReader
    private let fans: FanController
    private let stats = SystemStatsReader()

    /// Charts still need something to draw when there's no SQLite history, so
    /// keep a session-length ring buffer in memory.
    private var samples: [HistorySample] = []
    private let maxSamples = 4320   // 6 hours at one sample per 5s
    private var lastSampleAt = Date.distantPast
    private let lock = NSLock()

    public init() throws {
        smc = try SMC()
        sensors = SensorReader(smc: smc)
        fans = try FanController(smc: smc)
        try sensors.discover()
    }

    public var fanCount: Int { fans.fanCount }
    public var sensorCount: Int { sensors.discoveredKeyCount }

    /// Reads everything and returns the same shape the daemon publishes, so the
    /// views don't need to know which source they're rendering.
    public func readStatus() -> SystemStatus {
        let readings = sensors.readAll()
        let summaries = sensors.summarize(readings)

        let fanStates = fans.readAll().map {
            FanState(info: $0, commandedRPM: nil, safetyEngaged: false)
        }

        // Without the daemon we aren't controlling anything — report whatever
        // the hardware says it is doing.
        let anyManual = fanStates.contains { $0.info.mode == .manual }

        let status = SystemStatus(
            timestamp: Date(),
            fans: fanStates,
            groups: SensorGroup.allCases.compactMap { summaries[$0] },
            controlMode: anyManual ? .fixed : .appleAuto,
            activeProfileName: nil,
            cpu: stats.readCPU(),
            memory: stats.readMemory(),
            battery: stats.readBattery(),
            thermalPressure: stats.readThermalPressure(),
            safetyEngaged: false
        )

        record(status: status, maxima: summaries.mapValues(\.max))
        return status
    }

    public func readSensors() -> [SensorReading] {
        sensors.readAll()
    }

    public func history() -> [HistorySample] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func record(status: SystemStatus, maxima: [SensorGroup: Double]) {
        let now = Date()
        guard now.timeIntervalSince(lastSampleAt) >= 5 else { return }
        lastSampleAt = now

        lock.lock(); defer { lock.unlock() }
        samples.append(HistorySample(
            timestamp: now,
            fanRPM: status.fans.map(\.info.actualRPM),
            cpuCelsius: maxima[.cpu] ?? 0,
            gpuCelsius: maxima[.gpu] ?? 0,
            hotspotCelsius: maxima[.hotspot] ?? 0,
            cpuBusy: status.cpu.busy,
            memoryUsedFraction: status.memory.usedFraction
        ))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }
}
