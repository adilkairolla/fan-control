import Foundation
import FanKit

// Plain executable test suite — Command Line Tools ship neither XCTest nor
// swift-testing. Run with `swift run CoreTests` or `make test`.

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("  ✓ \(label)")
    } else {
        failures += 1
        print("  ✗ \(label)")
    }
}

func nearly(_ a: Double, _ b: Double, _ tolerance: Double = 0.001) -> Bool {
    abs(a - b) < tolerance
}

func suite(_ name: String, _ body: () -> Void) {
    print("\n\(name)")
    body()
}

// MARK: - Curve interpolation

suite("FanCurve interpolation") {
    let curve = FanCurve(input: .cpu, points: [
        CurvePoint(celsius: 40, rpm: 2000),
        CurvePoint(celsius: 80, rpm: 6000),
    ])

    check(nearly(curve.rpm(at: 40), 2000), "hits the lower anchor")
    check(nearly(curve.rpm(at: 80), 6000), "hits the upper anchor")
    check(nearly(curve.rpm(at: 60), 4000), "interpolates the midpoint")
    check(nearly(curve.rpm(at: 10), 2000), "clamps flat below the first point")
    check(nearly(curve.rpm(at: 120), 6000), "clamps flat above the last point")

    let unsorted = FanCurve(input: .cpu, points: [
        CurvePoint(celsius: 80, rpm: 6000),
        CurvePoint(celsius: 40, rpm: 2000),
    ])
    check(nearly(unsorted.rpm(at: 60), 4000), "sorts points given out of order")

    let single = FanCurve(input: .cpu, points: [CurvePoint(celsius: 50, rpm: 3000)])
    check(nearly(single.rpm(at: 90), 3000), "single point is constant")

    let empty = FanCurve(input: .cpu, points: [])
    check(nearly(empty.rpm(at: 50), 0), "empty curve does not crash")
}

// MARK: - Safety policy

suite("SafetyPolicy floor") {
    let policy = SafetyPolicy.standard
    let range = 2317.0...7826.0

    check(nearly(policy.floorRPM(dieCelsius: 50, range: range), range.lowerBound),
          "no floor pressure when cool")
    check(policy.floorRPM(dieCelsius: 92, range: range) > range.lowerBound,
          "floor lifts once die temp climbs")
    check(nearly(policy.floorRPM(dieCelsius: 100, range: range), range.upperBound),
          "floor reaches maximum at 100C")
    check(nearly(policy.floorRPM(dieCelsius: 110, range: range), range.upperBound),
          "above critical pins to maximum")

    // Monotonic: hotter must never mean a lower floor.
    var monotonic = true
    var previous = 0.0
    for t in stride(from: 60.0, through: 110.0, by: 0.5) {
        let value = policy.floorRPM(dieCelsius: t, range: range)
        if value < previous - 0.001 { monotonic = false; break }
        previous = value
    }
    check(monotonic, "floor is monotonic in temperature")
}

// MARK: - Evaluator

suite("CurveEvaluator hysteresis and slew") {
    let range = 2000.0...7000.0
    let curve = FanCurve(input: .cpu, points: [
        CurvePoint(celsius: 50, rpm: 2000),
        CurvePoint(celsius: 90, rpm: 7000),
    ])
    // Generous slew so these assertions test hysteresis, not ramping.
    let tuning = EvaluatorTuning(hysteresisCelsius: 3.0, maxRPMPerSecond: 100_000)
    let evaluator = CurveEvaluator(tuning: tuning)

    func run(_ celsius: Double) -> EvaluationResult {
        evaluator.evaluate(curve: curve, inputCelsius: celsius, dieCelsius: 50,
                           safety: .standard, range: range, dt: 1.0)
    }

    let hot = run(80)
    let small = run(78)      // within the 3C band
    check(nearly(hot.commandedRPM, small.commandedRPM),
          "small drop inside the band does not change output")

    let large = run(74)      // clears the band
    check(large.commandedRPM < hot.commandedRPM, "larger drop does lower output")

    let rising = run(85)
    check(rising.commandedRPM > large.commandedRPM, "rises respond immediately")

    // Slew limiting
    let slewEvaluator = CurveEvaluator(
        tuning: EvaluatorTuning(hysteresisCelsius: 0, maxRPMPerSecond: 200))
    _ = slewEvaluator.evaluate(curve: curve, inputCelsius: 50, dieCelsius: 50,
                               safety: .standard, range: range, dt: 1.0)
    let stepped = slewEvaluator.evaluate(curve: curve, inputCelsius: 90, dieCelsius: 50,
                                         safety: .standard, range: range, dt: 1.0)
    check(stepped.commandedRPM <= 2000 + 200 + 1,
          "slew limit caps a one-second jump")
}

suite("Safety overrides the user curve") {
    let range = 2000.0...7000.0
    // A deliberately reckless curve: minimum RPM no matter how hot.
    let reckless = FanCurve(input: .cpu, points: [
        CurvePoint(celsius: 0, rpm: 2000),
        CurvePoint(celsius: 120, rpm: 2000),
    ])
    let evaluator = CurveEvaluator(tuning: EvaluatorTuning(hysteresisCelsius: 0,
                                                           maxRPMPerSecond: 100_000))

    let cool = evaluator.evaluate(curve: reckless, inputCelsius: 50, dieCelsius: 50,
                                  safety: .standard, range: range, dt: 1.0)
    check(nearly(cool.commandedRPM, 2000), "curve is honoured while cool")
    check(!cool.safetyEngaged, "safety reports disengaged while cool")

    let hot = evaluator.evaluate(curve: reckless, inputCelsius: 50, dieCelsius: 98,
                                 safety: .standard, range: range, dt: 1.0)
    check(hot.commandedRPM > 2000, "safety floor overrides a reckless curve")
    check(hot.safetyEngaged, "safety reports engaged")

    let critical = evaluator.evaluate(curve: reckless, inputCelsius: 50, dieCelsius: 105,
                                      safety: .standard, range: range, dt: 1.0)
    check(nearly(critical.commandedRPM, range.upperBound),
          "critical temperature forces maximum")
}

// MARK: - Sensor classification

suite("SensorGroup classification") {
    check(SensorGroup.classify("Tp01") == .cpu, "Tp* is CPU")
    check(SensorGroup.classify("Tg0A") == .gpu, "Tg* is GPU")
    check(SensorGroup.classify("Tm02") == .memory, "Tm* is memory")
    check(SensorGroup.classify("Tf16") == .hotspot, "Tf* is hotspot")
    check(SensorGroup.classify("TB1T") == .battery, "TB* is battery")
    check(SensorGroup.classify("TAOP") == .ambient, "TAO* is ambient")
    check(SensorGroup.classify("TW0P") == .wireless, "TW0* is wireless")
    check(SensorGroup.classify("F0Ac") == .other, "non-T keys are not sensors")
    check(!SensorGroup.curveInputs.contains(.battery),
          "battery is not offered as a curve input")
}

// MARK: - Profiles

suite("Built-in profiles") {
    let range = 2317.0...7826.0
    let builtins = Profile.builtins(range: range)

    check(builtins.count == 4, "four built-ins")
    check(builtins.allSatisfy(\.isBuiltin), "all flagged built-in")
    check(Set(builtins.map(\.id)).count == 4, "ids are distinct")

    // Stability across calls is what lets a saved activeProfileID survive a
    // daemon restart.
    let again = Profile.builtins(range: range)
    check(builtins.map(\.id) == again.map(\.id), "ids are stable across calls")

    for profile in builtins {
        guard let curve = profile.curves.first else { continue }
        let inRange = curve.points.allSatisfy {
            $0.rpm >= range.lowerBound - 0.001 && $0.rpm <= range.upperBound + 0.001
        }
        check(inRange, "\(profile.name) stays inside the hardware range")
    }

    if let max = builtins.first(where: { $0.name == "Max" })?.curves.first {
        check(nearly(max.rpm(at: 30), range.upperBound), "Max is full speed even when cold")
    }

    // A profile with fewer curves than fans reuses the last one.
    let single = Profile(name: "t", curves: [FanCurve(input: .cpu, points: [
        CurvePoint(celsius: 50, rpm: 3000)])])
    check(single.curve(forFan: 5) != nil, "fan index beyond curve count still resolves")
}

// MARK: - Wire protocol

suite("IPC round-trip") {
    let request = Request(cmd: .setTarget, fan: 1, rpm: 4200)
    if let data = try? IPC.encoder().encode(request),
       let decoded = try? IPC.decoder().decode(Request.self, from: data) {
        check(decoded.cmd == .setTarget && decoded.fan == 1 && decoded.rpm == 4200,
              "request survives encode/decode")
        if let json = String(data: data, encoding: .utf8) {
            check(json.contains("\"cmd\":\"setTarget\""), "wire format stays flat and readable")
        }
    } else {
        check(false, "request round-trip")
    }

    let profile = Profile(name: "Custom", curves: [FanCurve(input: .gpu, points: [
        CurvePoint(celsius: 60, rpm: 3000), CurvePoint(celsius: 90, rpm: 6000)])])
    if let data = try? IPC.encoder().encode(profile),
       let decoded = try? IPC.decoder().decode(Profile.self, from: data) {
        check(decoded == profile, "profile survives encode/decode")
    } else {
        check(false, "profile round-trip")
    }
}

// MARK: - Live hardware (read-only, skipped if unavailable)

suite("Live SMC reads") {
    do {
        let smc = try SMC()
        let fans = try FanController(smc: smc)
        check(fans.fanCount > 0, "found \(fans.fanCount) fans")

        if let first = try? fans.read(0) {
            check(first.actualRPM > 0, "fan 0 reports \(Int(first.actualRPM)) RPM")
            check(first.maxRPM > first.minRPM,
                  "fan 0 range \(Int(first.minRPM))–\(Int(first.maxRPM)) RPM")
            check((0...1).contains(first.loadFraction), "load fraction is normalised")
        }

        let sensors = SensorReader(smc: smc)
        try sensors.discover()
        let readings = sensors.readAll()
        check(readings.count > 50, "read \(readings.count) temperature sensors")

        let summaries = sensors.summarize(readings)
        check(summaries[.cpu] != nil, "CPU group is populated")
        if let cpu = summaries[.cpu] {
            check(cpu.max > 10 && cpu.max < 120,
                  "CPU max \(String(format: "%.1f", cpu.max))C is plausible")
        }

        check(!SMC.canWrite || getuid() == 0, "canWrite agrees with euid")
    } catch {
        print("  – skipped (no SMC access: \(error))")
    }
}

// MARK: - Unprivileged monitoring path
//
// This is what the app falls back to when fand isn't installed. It must work
// as a normal user, because being useful with zero setup is the whole point.

suite("LocalMonitor (no daemon, no root)") {
    check(getuid() != 0, "running unprivileged (uid \(getuid()))")
    do {
        let monitor = try LocalMonitor()
        check(monitor.fanCount > 0, "sees \(monitor.fanCount) fans without root")
        check(monitor.sensorCount > 50, "discovered \(monitor.sensorCount) sensors without root")

        let status = monitor.readStatus()
        check(!status.fans.isEmpty, "status carries fan state")
        check(status.fans.allSatisfy { $0.info.actualRPM > 0 }, "every fan reports RPM")
        check(!status.groups.isEmpty, "status carries \(status.groups.count) sensor groups")
        check(status.cpuTemperature > 10 && status.cpuTemperature < 120,
              "CPU temp \(String(format: "%.1f", status.cpuTemperature))C is plausible")
        check(status.memory.totalBytes > 0, "memory stats populated")
        check(!status.safetyEngaged, "monitor-only never claims to be controlling")

        // Reads must never mutate. Confirm the fans stay in whatever mode they
        // were in before we looked at them.
        let modesBefore = status.fans.map(\.info.mode)
        let modesAfter = monitor.readStatus().fans.map(\.info.mode)
        check(modesBefore == modesAfter, "reading does not disturb fan mode")

        // Discovered keys and live readings are not the same number: some
        // sensors are unpopulated or powered down and report values outside
        // the plausible range, which readAll() filters out on purpose.
        let live = monitor.readSensors().count
        check(live > 50 && live <= monitor.sensorCount,
              "\(live) of \(monitor.sensorCount) discovered sensors report plausible values")
    } catch {
        check(false, "LocalMonitor init failed: \(error)")
    }
}

// MARK: - Summary

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
exit(0)
