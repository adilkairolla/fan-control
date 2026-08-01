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

// MARK: - Build provenance
//
// The version a build reports is produced by shell and consumed by Swift, so
// nothing in the compiler connects the two. Drift is silent and it fails in the
// worst way: `fanctl version` reports "not installed" for a daemon that is
// running, and the app's Update button loses the checkout it was built from.
// These checks are the join.

suite("Build provenance") {
    let sample = """
        {
          "version": "0.1.0",
          "commit": "a1b2c3d4e",
          "date": "2026-08-02",
          "sourceRoot": "/Users/someone/.fan-control"
        }
        """
    if let info = try? JSONDecoder().decode(BuildInfo.self, from: Data(sample.utf8)) {
        check(info.version == "0.1.0" && info.commit == "a1b2c3d4e"
              && info.sourceRoot == "/Users/someone/.fan-control",
              "the JSON install.sh writes decodes into BuildInfo")
        check(info.short == "0.1.0 (a1b2c3d4e)", "short form names the commit")
    } else {
        check(false, "version.json decodes")
    }

    check(BuildInfo(version: "0.1.0", commit: "unknown", date: "unknown",
                    sourceRoot: "").short == "0.1.0",
          "a build from outside a checkout claims no commit")

    // CoreTests is a bare executable with no Info.plist — the app-bundle path
    // has to degrade to nil rather than trap.
    check(BuildInfo.bundled() == nil, "bundle lookup returns nil without a bundle")
    check(BuildInfo.app(at: "/Applications/Nothing.app") == nil,
          "a missing app bundle reports no version")

    // Source-level contract. Skipped if the tests were built somewhere the
    // repository no longer sits.
    let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // Tests/CoreTests
        .deletingLastPathComponent()    // Tests
        .deletingLastPathComponent()    // repository root
    let scripts = repo.appendingPathComponent("scripts")

    if let install = try? String(contentsOf: scripts.appendingPathComponent("install.sh"),
                                 encoding: .utf8),
       let buildApp = try? String(contentsOf: scripts.appendingPathComponent("build-app.sh"),
                                  encoding: .utf8) {
        let directory = (BuildInfo.installedPath as NSString).deletingLastPathComponent
        let file = (BuildInfo.installedPath as NSString).lastPathComponent
        check(install.contains("SUPPORT=\"\(directory)\""),
              "install.sh writes into \(directory)")
        check(install.contains("$SUPPORT/\(file)"), "install.sh writes \(file)")
        check(install.contains("\"version\"") && install.contains("\"commit\"")
              && install.contains("\"date\"") && install.contains("\"sourceRoot\""),
              "install.sh emits every field BuildInfo decodes")

        for key in ["CFBundleShortVersionString", "FCSourceCommit", "FCSourceDate", "FCSourceRoot"] {
            check(buildApp.contains(key), "build-app.sh stamps \(key)")
        }

        check(FileManager.default.isExecutableFile(
                atPath: scripts.appendingPathComponent("update.sh").path),
              "update.sh is executable")
        check(BuildInfo.updateScript(sourceRoot: repo.path) != nil,
              "the updater is discoverable from a source root")
        check(BuildInfo.updateScript(sourceRoot: "/nonexistent") == nil
              || FileManager.default.isExecutableFile(
                    atPath: NSHomeDirectory() + "/.fan-control/scripts/update.sh"),
              "a bogus source root falls back to ~/.fan-control or nothing")
    } else {
        print("  – repository not at #filePath, source contract checks skipped")
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

// MARK: - Power state

suite("Lid state") {
    // Cross-check against the registry rather than asserting a fixed value:
    // whether the lid is open depends on how the tests are being run, and a
    // test that assumed "open" would fail over SSH for the wrong reason.
    func clamshellPerIoreg() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-n", "IOPMrootDomain", "-r", "-d", "1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let line = text.split(separator: "\n").first(where: {
            $0.contains("\"AppleClamshellState\"")
        }) else { return nil }
        return line.contains("Yes")
    }

    let reported = PowerState.lidIsClosed()
    let registry = clamshellPerIoreg()

    check(reported == registry,
          "lidIsClosed() agrees with IOPMrootDomain (reported \(reported.map(String.init(describing:)) ?? "nil"))")

    // The daemon treats only an explicit `true` as a reason to stop driving the
    // fans, so a desktop Mac — where the property is absent — keeps working.
    check(PowerState.lidIsClosed() != true || registry == true,
          "never reports a closed lid the registry does not confirm")

    // Two reads in a row must agree; the daemon calls this every second and a
    // flapping answer would hand the fans back and forth.
    check(PowerState.lidIsClosed() == reported, "stable across consecutive reads")
}

// MARK: - Fan key resolution
//
// The bug this suite exists for: `read()` demanded five SMC keys, all with the
// types this one Mac happens to use. On any Mac where one differed, `readAll()`
// returned nothing — fan speed disappeared from the entire UI and the presets
// silently did nothing, with no error anywhere. So the contract under test is
// "one unrecognised key costs you that key, not the fan".

suite("Fan key resolution") {
    do {
        let smc = try SMC()
        let fans = try FanController(smc: smc)

        // Names are looked up, not assumed. The mode key is the one that is
        // genuinely known to differ between Macs.
        check(FanController.FanKeys.candidates(.mode, fan: 0) == ["F0md", "F0Md"],
              "both spellings of the mode key are tried")
        check(FanController.FanKeys.candidates(.actual, fan: 1) == ["F1Ac"],
              "candidate names are per-fan")

        check(fans.fanCount == fans.fanKeys.count, "one key set per fan")

        for keys in fans.fanKeys {
            check(keys.actual != nil, "fan \(keys.index): found \(keys.actual ?? "no") RPM key")
            check(keys.resolved(.mode) == keys.mode, "fan \(keys.index): resolved(_:) matches")
        }

        // Every key a probe claims to have found must actually read back.
        for index in 0..<fans.fanCount {
            let probes = fans.probe(index)
            check(probes.count == FanController.FanKeys.Role.allCases.count,
                  "fan \(index): probed all \(probes.count) roles")
            check(probes.allSatisfy { !$0.exists || $0.error == nil },
                  "fan \(index): every key found also reads")
        }

        // The four numeric encodings go through one accessor now, and the
        // trailing space in a padded four-character type name has to survive
        // it — `ui8 ` is not `ui8`, and matching the padded form once already
        // made every mode-key read fail.
        if let mode = fans.fanKeys.first?.mode {
            check((try? smc.readNumber(mode)) != nil,
                  "readNumber handles '\((try? smc.keyInfo(mode))?.type ?? "?")' (\(mode))")
        }
        if let actual = fans.fanKeys.first?.actual {
            let viaNumber = try? smc.readNumber(actual)
            check(viaNumber != nil && viaNumber! > 0,
                  "readNumber handles '\((try? smc.keyInfo(actual))?.type ?? "?")' (\(actual))")
        }
        // And it refuses what it cannot decode, rather than returning a number
        // built out of whatever bytes happened to be there.
        let numeric: Set<String> = ["flt", "fpe2", "ui8", "ui16", "ui32"]
        let nonNumeric = ((try? smc.allKeys()) ?? []).first { key in
            guard let type = try? smc.keyInfo(key).type else { return false }
            return !numeric.contains(type.trimmingCharacters(in: .whitespaces))
        }
        if let nonNumeric {
            check((try? smc.readNumber(nonNumeric)) == nil,
                  "readNumber refuses '\((try? smc.keyInfo(nonNumeric))?.type ?? "?")' (\(nonNumeric))")
        }

        // A range is reported or it is nil — never a fabricated 0...0, which
        // would clamp every command to a standstill.
        for index in 0..<fans.fanCount {
            if let range = fans.range(index) {
                check(range.upperBound > range.lowerBound, "fan \(index): range is non-degenerate")
            }
        }

        check(fans.controllableFanCount <= fans.fanCount, "controllable never exceeds found")
    } catch {
        print("  – skipped (no SMC access: \(error))")
    }
}

// MARK: - Single instance
//
// `make up` bootstrapped the LaunchAgent (RunAtLoad) and then also ran `open`,
// which raced LaunchServices and started a second copy — two identical menu bar
// items. flock is what makes that impossible rather than merely unlikely.

suite("Single instance guard") {
    let path = NSTemporaryDirectory() + "fancontrol-test-\(getpid())/app.lock"
    defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

    // Two open() calls make two file descriptions even inside one process, and
    // flock conflicts between descriptions — so this is a faithful stand-in for
    // two processes starting at once.
    var held = SingleInstance.claim(at: path)
    check(held != nil, "first claim takes the lock")
    check(SingleInstance.claim(at: path) == nil, "second claim is refused while it is held")

    check(FileManager.default.fileExists(atPath: path), "lock file created, parents and all")

    // Releasing has to actually release, or a crashed app would lock the user
    // out of their own menu bar until a reboot.
    held = nil
    check(SingleInstance.claim(at: path) != nil, "released once the token goes away")

    check(SingleInstance.appLockPath.hasSuffix("/Library/Application Support/FanControl/app.lock"),
          "app locks under the per-user support directory")
}

// MARK: - Summary

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
exit(0)
