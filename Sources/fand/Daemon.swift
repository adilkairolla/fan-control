import Foundation
import IOKit
import IOKit.pwr_mgt
import FanKit

struct DaemonConfig: Codable {
    var controlMode: ControlMode = .appleAuto
    var fixedRPM: [Double] = []
    var activeProfileID: UUID?
    var userProfiles: [Profile] = []
    var safety: SafetyPolicy = .standard
    var tuning: EvaluatorTuning = .standard

    static let path = "/Library/Application Support/FanControl/config.json"

    static func load() -> DaemonConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? IPC.decoder().decode(DaemonConfig.self, from: data)
        else { return DaemonConfig() }
        return config
    }

    func save() {
        let directory = (Self.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard let data = try? IPC.encoder().encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.path), options: .atomic)
    }
}

/// The privileged control loop.
///
/// Owns the only writable SMC handle in the system and is the sole authority on
/// fan state. Clients ask; this decides.
final class Daemon {

    private let smc: SMC
    private let sensors: SensorReader
    private let fans: FanController
    private let stats = SystemStatsReader()
    private let history: HistoryStore?

    private var config: DaemonConfig
    private var evaluators: [CurveEvaluator] = []
    private var lastCommanded: [Double?] = []
    private var lastSafetyEngaged: [Bool] = []
    private var lastTick = Date()
    private var lastHistoryWrite = Date.distantPast
    private var lastPrune = Date.distantPast

    private var latestStatus: SystemStatus?
    private let stateLock = NSLock()
    private var timer: DispatchSourceTimer?

    /// The control loop's serial queue. Sleep and wake hop onto it deliberately
    /// — see `prepareForSleep()`.
    private let tickQueue = DispatchQueue(label: "fand.tick")

    /// Why the fans are currently Apple's, or nil if this daemon is driving
    /// them. Written on `tickQueue`, plus once from `shutdown()` on the way out.
    private var pausedFor: String?

    /// Set the moment macOS says it is going to sleep, cleared on wake. Kept
    /// apart from `pausedFor` because the lid can shut and open while the
    /// machine stays awake, and those two conditions clear at different times.
    private var asleep = false

    private let tickInterval: TimeInterval = 1.0
    private let historyInterval: TimeInterval = 5.0

    init() throws {
        smc = try SMC()
        sensors = SensorReader(smc: smc)
        fans = try FanController(smc: smc)
        config = DaemonConfig.load()

        try sensors.discover()

        history = try? HistoryStore(path: "/Library/Application Support/FanControl/history.sqlite")
        if history == nil {
            log("warning: history store unavailable, continuing without it")
        }

        evaluators = (0..<fans.fanCount).map { _ in CurveEvaluator(tuning: config.tuning) }
        lastCommanded = Array(repeating: nil, count: fans.fanCount)
        lastSafetyEngaged = Array(repeating: false, count: fans.fanCount)

        log("SMC ready — \(fans.fanCount) fans, \(sensors.discoveredKeyCount) temperature sensors")
    }

    // MARK: - Lifecycle

    func start() throws {
        // A previous instance may have died with fans forced. Reclaim a known state.
        fans.restoreAllToAuto()

        let timer = DispatchSource.makeTimerSource(queue: tickQueue)
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer

        registerForPowerNotifications()
        log("control loop started (mode: \(config.controlMode.rawValue))")
    }

    /// Hand the fans back. Safe to call repeatedly and from signal context.
    func shutdown() {
        // Latch first, restore second. `cancel()` does not wait for a tick that
        // is already running, so without the latch that tick can re-force manual
        // mode after the restore — and there would be no daemon left to undo it.
        asleep = true
        pausedFor = "stopping"
        timer?.cancel()
        timer = nil
        fans.restoreAllToAuto()
        log("fans restored to auto")
    }

    // MARK: - Control loop

    private func tick() {
        let now = Date()
        let dt = max(0.05, now.timeIntervalSince(lastTick))
        lastTick = now

        let readings = sensors.readAll()
        let summaries = sensors.summarize(readings)
        let maxima = summaries.mapValues(\.max)

        // Asleep, or shut in a bag. Monitoring carries on — whoever is looking
        // still gets live numbers — but nothing drives the fans.
        if let reason = pauseReason() {
            releaseFans(reason: reason)
            publishStatus(summaries: summaries, now: now)
            recordHistory(maxima: maxima, now: now)
            return
        }
        if pausedFor != nil {
            pausedFor = nil
            log("resuming fan control")
        }

        // Safety keys off the die temperatures that actually govern throttling.
        // Deliberately excludes the `Tf*` hotspot group: it idles in the low 90s
        // on this hardware and would hold the fans up permanently.
        let die = max(maxima[.cpu] ?? 0, maxima[.gpu] ?? 0)

        stateLock.lock()
        let mode = config.controlMode
        let safety = config.safety
        let activeProfile = resolveActiveProfileLocked()
        let fixed = config.fixedRPM
        stateLock.unlock()

        switch mode {
        case .appleAuto:
            if fans.isUnderManualControl() { fans.restoreAllToAuto() }
            for i in 0..<fans.fanCount {
                lastCommanded[i] = nil
                lastSafetyEngaged[i] = false
                evaluators[i].reset()
            }

        case .fixed:
            try? fans.engageManualControl()
            for i in 0..<fans.fanCount {
                guard let range = try? fans.range(i) else { continue }
                let requested = i < fixed.count ? fixed[i] : range.lowerBound
                // The floor still applies to a pinned RPM — that is the point of it.
                let floor = safety.floorRPM(dieCelsius: die, range: range)
                let commanded = max(requested, floor)
                lastSafetyEngaged[i] = floor > requested + 1
                lastCommanded[i] = try? fans.setTarget(i, rpm: commanded)
            }

        case .curve:
            guard let profile = activeProfile else {
                log("curve mode with no active profile — falling back to auto")
                stateLock.lock(); config.controlMode = .appleAuto; stateLock.unlock()
                fans.restoreAllToAuto()
                break
            }
            try? fans.engageManualControl()
            for i in 0..<fans.fanCount {
                guard let curve = profile.curve(forFan: i),
                      let range = try? fans.range(i) else { continue }
                let input = maxima[curve.input] ?? die
                let result = evaluators[i].evaluate(curve: curve,
                                                    inputCelsius: input,
                                                    dieCelsius: die,
                                                    safety: safety,
                                                    range: range,
                                                    dt: dt)
                lastSafetyEngaged[i] = result.safetyEngaged
                lastCommanded[i] = try? fans.setTarget(i, rpm: result.commandedRPM)
            }
        }

        publishStatus(summaries: summaries, now: now)
        recordHistory(maxima: maxima, now: now)
    }

    /// Why fan control should not be running right now, or nil if it should.
    ///
    /// The lid rule is the one users ask for by name: close the laptop and the
    /// fans go back to macOS. It also covers the wakes nobody sees — macOS wakes
    /// a sleeping Mac every twenty minutes or so for maintenance, and without
    /// this the curve would spin the fans up each time, inside a closed bag.
    ///
    /// The cost is that a Mac run in clamshell on an external display gets
    /// Apple's fan control rather than yours. That is the safe direction, and
    /// the temperatures on screen stay live either way.
    private func pauseReason() -> String? {
        if asleep { return "asleep" }
        if PowerState.lidIsClosed() == true { return "lid closed" }
        return nil
    }

    /// Give the fans back to Apple's controller and leave them there.
    ///
    /// Re-checks the SMC every tick rather than trusting one write: a hand-back
    /// that failed once then gets retried, instead of quietly leaving the fans
    /// forced with nothing watching them.
    private func releaseFans(reason: String) {
        if fans.isUnderManualControl() { fans.restoreAllToAuto() }
        for i in 0..<fans.fanCount {
            lastCommanded[i] = nil
            lastSafetyEngaged[i] = false
            evaluators[i].reset()
        }
        if pausedFor != reason {
            pausedFor = reason
            log("\(reason) — fans handed back to macOS")
        }
    }

    private func publishStatus(summaries: [SensorGroup: GroupSummary], now: Date) {
        let fanStates = fans.readAll().map { info in
            FanState(info: info,
                     commandedRPM: info.index < lastCommanded.count ? lastCommanded[info.index] : nil,
                     safetyEngaged: info.index < lastSafetyEngaged.count
                        ? lastSafetyEngaged[info.index] : false)
        }

        stateLock.lock()
        let mode = config.controlMode
        let profileName = resolveActiveProfileLocked()?.name
        stateLock.unlock()

        let status = SystemStatus(
            timestamp: now,
            fans: fanStates,
            groups: SensorGroup.allCases.compactMap { summaries[$0] },
            controlMode: mode,
            activeProfileName: profileName,
            cpu: stats.readCPU(),
            memory: stats.readMemory(),
            battery: stats.readBattery(),
            thermalPressure: stats.readThermalPressure(),
            safetyEngaged: lastSafetyEngaged.contains(true)
        )

        stateLock.lock()
        latestStatus = status
        stateLock.unlock()
    }

    private func recordHistory(maxima: [SensorGroup: Double], now: Date) {
        guard let history else { return }
        guard now.timeIntervalSince(lastHistoryWrite) >= historyInterval else { return }
        lastHistoryWrite = now

        let status = currentStatus()
        history.insert(HistorySample(
            timestamp: now,
            fanRPM: status?.fans.map(\.info.actualRPM) ?? [],
            cpuCelsius: maxima[.cpu] ?? 0,
            gpuCelsius: maxima[.gpu] ?? 0,
            hotspotCelsius: maxima[.hotspot] ?? 0,
            cpuBusy: status?.cpu.busy ?? 0,
            memoryUsedFraction: status?.memory.usedFraction ?? 0
        ))

        if now.timeIntervalSince(lastPrune) > 3600 {
            lastPrune = now
            history.prune()
        }
    }

    // MARK: - Profiles

    private func allProfilesLocked() -> [Profile] {
        let range = (try? fans.range(0)) ?? 2000...7000
        return Profile.builtins(range: range) + config.userProfiles
    }

    private func resolveActiveProfileLocked() -> Profile? {
        guard let id = config.activeProfileID else { return nil }
        return allProfilesLocked().first { $0.id == id }
    }

    private func currentStatus() -> SystemStatus? {
        stateLock.lock(); defer { stateLock.unlock() }
        return latestStatus
    }

    // MARK: - Request handling

    func handle(_ request: Request) -> Response {
        switch request.cmd {
        case .ping:
            return Response(ok: true)

        case .status:
            guard let status = currentStatus() else {
                return .failure("no status yet — daemon still warming up")
            }
            return Response(ok: true, status: status)

        case .sensors:
            return Response(ok: true, sensors: sensors.readAll())

        case .history:
            guard let history else { return .failure("history store unavailable") }
            let seconds = TimeInterval(request.seconds ?? 3600)
            return Response(ok: true, history: history.query(since: Date().addingTimeInterval(-seconds)))

        case .setControlMode:
            guard let mode = request.controlMode else { return .failure("controlMode required") }
            stateLock.lock()
            config.controlMode = mode
            if mode == .curve && config.activeProfileID == nil {
                config.activeProfileID = allProfilesLocked().first { $0.name == "Balanced" }?.id
            }
            let snapshot = config
            stateLock.unlock()
            snapshot.save()
            for evaluator in evaluators { evaluator.reset() }
            log("control mode -> \(mode.rawValue)")
            return Response(ok: true)

        case .setTarget:
            guard let rpm = request.rpm else { return .failure("rpm required") }
            stateLock.lock()
            if config.fixedRPM.count != fans.fanCount {
                config.fixedRPM = Array(repeating: rpm, count: fans.fanCount)
            }
            if let index = request.fan {
                guard index >= 0 && index < fans.fanCount else {
                    stateLock.unlock()
                    return .failure("fan index \(index) out of range (0..<\(fans.fanCount))")
                }
                config.fixedRPM[index] = rpm
            } else {
                config.fixedRPM = Array(repeating: rpm, count: fans.fanCount)
            }
            config.controlMode = .fixed
            let snapshot = config
            stateLock.unlock()
            snapshot.save()
            return Response(ok: true)

        case .listProfiles:
            stateLock.lock(); let profiles = allProfilesLocked(); stateLock.unlock()
            return Response(ok: true, profiles: profiles)

        case .applyProfile:
            guard let name = request.profileName else { return .failure("profileName required") }
            stateLock.lock()
            guard let match = allProfilesLocked().first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                let available = allProfilesLocked().map(\.name).joined(separator: ", ")
                stateLock.unlock()
                return .failure("no profile named '\(name)'. Available: \(available)")
            }
            config.activeProfileID = match.id
            config.controlMode = .curve
            let snapshot = config
            stateLock.unlock()
            snapshot.save()
            for evaluator in evaluators { evaluator.reset() }
            log("profile -> \(match.name)")
            return Response(ok: true)

        case .saveProfile:
            guard let profile = request.profile else { return .failure("profile required") }
            guard !profile.isBuiltin else { return .failure("built-in profiles cannot be overwritten") }
            stateLock.lock()
            if let existing = config.userProfiles.firstIndex(where: { $0.id == profile.id }) {
                config.userProfiles[existing] = profile
            } else {
                config.userProfiles.append(profile)
            }
            let snapshot = config
            stateLock.unlock()
            snapshot.save()
            return Response(ok: true, profiles: snapshot.userProfiles)

        case .deleteProfile:
            guard let id = request.profileID else { return .failure("profileID required") }
            stateLock.lock()
            config.userProfiles.removeAll { $0.id == id }
            if config.activeProfileID == id {
                config.activeProfileID = nil
                config.controlMode = .appleAuto
            }
            let snapshot = config
            stateLock.unlock()
            snapshot.save()
            return Response(ok: true)

        case .getSafety:
            stateLock.lock(); let safety = config.safety; stateLock.unlock()
            return Response(ok: true, safety: safety)

        case .setSafety:
            guard let safety = request.safety else { return .failure("safety required") }
            // The floor may be raised but never removed. Reject anything weaker
            // than the standard policy at any temperature.
            let standard = SafetyPolicy.standard
            let probes = stride(from: 80.0, through: 105.0, by: 1.0)
            let weaker = probes.contains { t in
                let candidate = FanCurve(input: .cpu, points: safety.floorPoints).rpm(at: t)
                let baseline = FanCurve(input: .cpu, points: standard.floorPoints).rpm(at: t)
                return candidate < baseline - 0.001
            }
            if weaker || safety.criticalCelsius > standard.criticalCelsius {
                return .failure("safety policy may be strengthened but not weakened")
            }
            stateLock.lock(); config.safety = safety; let snapshot = config; stateLock.unlock()
            snapshot.save()
            return Response(ok: true, safety: safety)
        }
    }

    // MARK: - Power notifications

    /// Hand the fans back before letting the machine sleep, and make it stick.
    ///
    /// Synchronously, and on `tickQueue`, both on purpose. macOS spends about
    /// five seconds between this notification and the SoC actually going down —
    /// measured on this hardware, consistently, across every clamshell sleep in
    /// the log. The control loop runs at 1 Hz and re-arms manual mode on every
    /// pass, so a hand-back that merely wrote the SMC and returned was undone
    /// five times over before the machine went under. It then slept with the
    /// fans pinned to the curve's last target, and the SMC has no deadman: they
    /// stayed spinning in the bag until something woke the Mac up again.
    ///
    /// Hopping onto the control loop's own queue is what closes it. A tick that
    /// is already running finishes first, this runs next, and no further tick
    /// starts while `asleep` is set.
    private func prepareForSleep() {
        tickQueue.sync {
            asleep = true
            releaseFans(reason: "asleep")
        }
    }

    private func wakeUp() {
        tickQueue.sync {
            asleep = false
            for evaluator in evaluators { evaluator.reset() }
        }
    }

    private func registerForPowerNotifications() {
        var notifyPort: IONotificationPortRef?
        var notifierObject: io_object_t = 0

        let callback: IOServiceInterestCallback = { _, _, messageType, argument in
            switch messageType {
            case PowerMessage.systemWillSleep:
                // Hand the fans back *and latch them*, then allow the sleep.
                // Order matters: once IOAllowPowerChange returns there is no
                // guarantee this process runs again before the machine is down.
                gDaemon?.prepareForSleep()
                IOAllowPowerChange(gRootPort, Int(bitPattern: argument))
            case PowerMessage.canSystemSleep:
                IOAllowPowerChange(gRootPort, Int(bitPattern: argument))
            case PowerMessage.systemHasPoweredOn:
                log("woke")
                gDaemon?.wakeUp()
            default:
                break
            }
        }

        gRootPort = IORegisterForSystemPower(nil, &notifyPort, callback, &notifierObject)
        guard gRootPort != 0, let notifyPort else {
            log("warning: could not register for sleep/wake notifications")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
                           .defaultMode)
    }
}

/// IOKit's power messages are C macros (`iokit_common_msg(0x280)`), which Swift
/// cannot import. Values confirmed against the SDK headers by compiling them.
enum PowerMessage {
    static let canSystemSleep: UInt32     = 0xE000_0270
    static let systemWillSleep: UInt32    = 0xE000_0280
    static let systemHasPoweredOn: UInt32 = 0xE000_0300
    static let systemWillPowerOn: UInt32  = 0xE000_0320
}

// Signal handlers and C callbacks cannot capture context, so the daemon needs
// a file-scope handle.
var gDaemon: Daemon?
var gRootPort: io_connect_t = 0

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(stamp)] \(message)\n".data(using: .utf8)!)
}
