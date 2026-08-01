import Foundation
import FanKit

enum CLI {

    static let usage = """
    fanctl — control and inspect the fan daemon

    USAGE
      fanctl status                  current fans, temps, load
      fanctl watch [interval]        live status, refreshed (default 1s)
      fanctl sensors [group]         all sensor readings, optionally one group
      fanctl auto                    hand fans back to the system controller
      fanctl set <rpm> [--fan N]     pin a fixed RPM (all fans, or just N)
      fanctl profile <name>          activate a curve profile
      fanctl profiles                list available profiles
      fanctl curve [name]            show a profile's curve points
      fanctl safety                  show the enforced safety floor
      fanctl history [seconds]       dump recorded history as CSV (default 3600)
      fanctl version                 what is installed, and how to update it

    GROUPS
      \(SensorGroup.allCases.map(\.rawValue).joined(separator: ", "))
    """

    static func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            print(usage)
            return 0
        }

        let client = FanControlClient()
        let rest = Array(arguments.dropFirst())

        do {
            switch command {
            case "status":   return try showStatus(client)
            case "watch":    return try watch(client, interval: Double(rest.first ?? "") ?? 1.0)
            case "sensors":  return try showSensors(client, group: rest.first)
            case "auto":     return try setMode(client, .appleAuto)
            case "set":      return try setFixed(client, rest)
            case "profile":  return try applyProfile(client, rest)
            case "profiles": return try listProfiles(client)
            case "curve":    return try showCurve(client, name: rest.first)
            case "safety":   return try showSafety(client)
            case "history":  return try dumpHistory(client, seconds: Int(rest.first ?? "") ?? 3600)
            case "version", "--version", "-v": return showVersion()
            case "-h", "--help", "help":
                print(usage)
                return 0
            default:
                fail("unknown command '\(command)'\n\n\(usage)")
                return 2
            }
        } catch {
            fail("\(error)")
            return 1
        }
    }

    // MARK: - Commands

    private static func showStatus(_ client: FanControlClient) throws -> Int32 {
        let response = try client.send(Request(cmd: .status))
        guard response.ok, let status = response.status else {
            fail(response.error ?? "no status"); return 1
        }
        print(render(status))
        return 0
    }

    private static func watch(_ client: FanControlClient, interval: Double) throws -> Int32 {
        // Alternate screen buffer, restored on exit so the scrollback survives.
        print("\u{1B}[?1049h", terminator: "")
        defer { print("\u{1B}[?1049l", terminator: "") }

        signal(SIGINT) { _ in
            print("\u{1B}[?1049l", terminator: "")
            exit(0)
        }

        while true {
            let response = try client.send(Request(cmd: .status))
            guard response.ok, let status = response.status else {
                fail(response.error ?? "no status"); return 1
            }
            print("\u{1B}[H\u{1B}[2J", terminator: "")
            print(render(status))
            print("\n  ctrl-c to exit")
            fflush(stdout)
            Thread.sleep(forTimeInterval: max(0.2, interval))
        }
    }

    private static func showSensors(_ client: FanControlClient, group: String?) throws -> Int32 {
        let response = try client.send(Request(cmd: .sensors))
        guard response.ok, let sensors = response.sensors else {
            fail(response.error ?? "no sensors"); return 1
        }

        let filter = group.flatMap { SensorGroup(rawValue: $0) }
        if group != nil && filter == nil {
            fail("unknown group '\(group!)'. Valid: \(SensorGroup.allCases.map(\.rawValue).joined(separator: ", "))")
            return 2
        }

        let shown = filter.map { f in sensors.filter { $0.group == f } } ?? sensors
        let grouped = Dictionary(grouping: shown, by: \.group)

        for g in SensorGroup.allCases {
            guard let items = grouped[g], !items.isEmpty else { continue }
            let values = items.map(\.celsius)
            print("\n\(g.displayName)  —  \(items.count) sensors, "
                  + "max \(fmt(values.max() ?? 0))°C, mean \(fmt(values.reduce(0,+) / Double(values.count)))°C")
            for reading in items.sorted(by: { $0.celsius > $1.celsius }) {
                print("  \(reading.key)   \(pad(fmt(reading.celsius), 6))°C")
            }
        }
        return 0
    }

    private static func setMode(_ client: FanControlClient, _ mode: ControlMode) throws -> Int32 {
        let response = try client.send(Request(cmd: .setControlMode, controlMode: mode))
        guard response.ok else { fail(response.error ?? "failed"); return 1 }
        print("control mode → \(mode.displayName)")
        return 0
    }

    private static func setFixed(_ client: FanControlClient, _ args: [String]) throws -> Int32 {
        guard let rpmArg = args.first, let rpm = Double(rpmArg) else {
            fail("usage: fanctl set <rpm> [--fan N]"); return 2
        }
        var fan: Int?
        if let flagIndex = args.firstIndex(of: "--fan"), flagIndex + 1 < args.count {
            fan = Int(args[flagIndex + 1])
        }
        let response = try client.send(Request(cmd: .setTarget, fan: fan, rpm: rpm))
        guard response.ok else { fail(response.error ?? "failed"); return 1 }
        print("target → \(Int(rpm)) RPM\(fan.map { " (fan \($0))" } ?? " (all fans)")")
        print("note: the safety floor can still raise this if die temps climb")
        return 0
    }

    private static func applyProfile(_ client: FanControlClient, _ args: [String]) throws -> Int32 {
        guard let name = args.first else { fail("usage: fanctl profile <name>"); return 2 }
        let response = try client.send(Request(cmd: .applyProfile, profileName: name))
        guard response.ok else { fail(response.error ?? "failed"); return 1 }
        print("profile → \(name)")
        return 0
    }

    private static func listProfiles(_ client: FanControlClient) throws -> Int32 {
        let response = try client.send(Request(cmd: .listProfiles))
        guard response.ok, let profiles = response.profiles else {
            fail(response.error ?? "failed"); return 1
        }
        let status = try? client.send(Request(cmd: .status)).status
        for profile in profiles {
            let active = profile.name == status?.activeProfileName ? " ← active" : ""
            let kind = profile.isBuiltin ? "built-in" : "custom"
            print("  \(pad(profile.name, 12)) \(pad(kind, 9)) \(profile.curves.first?.points.count ?? 0) points\(active)")
        }
        return 0
    }

    private static func showCurve(_ client: FanControlClient, name: String?) throws -> Int32 {
        let response = try client.send(Request(cmd: .listProfiles))
        guard response.ok, let profiles = response.profiles else {
            fail(response.error ?? "failed"); return 1
        }
        let target: Profile?
        if let name {
            target = profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        } else {
            let status = try? client.send(Request(cmd: .status)).status
            target = profiles.first { $0.name == status?.activeProfileName }
        }
        guard let profile = target else {
            fail("no such profile. Available: \(profiles.map(\.name).joined(separator: ", "))")
            return 1
        }

        print("\(profile.name)\n")
        for (index, curve) in profile.curves.enumerated() {
            print("  fan \(index) — driven by \(curve.input.displayName)")
            for point in curve.points {
                print("    \(pad(fmt(point.celsius), 6))°C → \(Int(point.rpm)) RPM")
            }
        }
        return 0
    }

    private static func showSafety(_ client: FanControlClient) throws -> Int32 {
        let response = try client.send(Request(cmd: .getSafety))
        guard response.ok, let safety = response.safety else {
            fail(response.error ?? "failed"); return 1
        }
        print("Safety floor — enforced under every curve, driven by max(CPU, GPU) die temp.\n")
        for point in safety.floorPoints {
            print("  \(pad(fmt(point.celsius), 6))°C → minimum \(Int(point.rpm * 100))% of fan range")
        }
        print("\n  critical: \(fmt(safety.criticalCelsius))°C → 100%")
        return 0
    }

    /// Reports the two halves separately rather than printing one number.
    /// They are installed by different scripts and can genuinely diverge — an
    /// app rebuilt while the helper stayed behind is a real state, and one you
    /// cannot diagnose if the tool insists there is only one version.
    private static func showVersion() -> Int32 {
        let helper = BuildInfo.installed()
        let app = BuildInfo.app()

        // A helper binary with no version file is not an absent helper — it is
        // one installed before this existed. Saying "not installed" about a
        // daemon that is currently driving the fans would be a lie.
        let helperLabel = helper?.short
            ?? (FileManager.default.isExecutableFile(atPath: BuildInfo.helperPath)
                ? "unknown — installed before version tracking"
                : "not installed")

        print("  helper  \(helperLabel)\(helper.map { "   \($0.date)" } ?? "")")
        print("  app     \(app?.short ?? "not installed")\(app.map { "   \($0.date)" } ?? "")")

        if let helper, let app, helper.commit != app.commit {
            print("\n  ! these were built from different commits — `make up` reconciles them")
        }

        let root = helper?.sourceRoot ?? app?.sourceRoot
        print("\n  update")
        if let script = BuildInfo.updateScript(sourceRoot: root) {
            print("    \(script)          pull and reinstall")
            print("    \(script) --check  see what would change")
        } else {
            print("    \(BuildInfo.bootstrapCommand)")
        }
        return 0
    }

    private static func dumpHistory(_ client: FanControlClient, seconds: Int) throws -> Int32 {
        let response = try client.send(Request(cmd: .history, seconds: seconds))
        guard response.ok, let history = response.history else {
            fail(response.error ?? "failed"); return 1
        }
        print("timestamp,fan0_rpm,fan1_rpm,cpu_c,gpu_c,hotspot_c,cpu_busy,mem_used")
        let formatter = ISO8601DateFormatter()
        for sample in history {
            let fan0 = sample.fanRPM.first.map { String(Int($0)) } ?? ""
            let fan1 = sample.fanRPM.count > 1 ? String(Int(sample.fanRPM[1])) : ""
            print([formatter.string(from: sample.timestamp), fan0, fan1,
                   fmt(sample.cpuCelsius), fmt(sample.gpuCelsius), fmt(sample.hotspotCelsius),
                   fmt(sample.cpuBusy * 100), fmt(sample.memoryUsedFraction * 100)]
                .joined(separator: ","))
        }
        return 0
    }

    // MARK: - Rendering

    private static func render(_ status: SystemStatus) -> String {
        var lines: [String] = []

        var header = "  mode: \(status.controlMode.displayName)"
        if let profile = status.activeProfileName, status.controlMode == .curve {
            header += " · \(profile)"
        }
        header += "   thermal: \(status.thermalPressure.rawValue)"
        if status.safetyEngaged { header += "   ⚠ SAFETY FLOOR ACTIVE" }
        lines.append(header)
        lines.append("")

        lines.append("  FANS")
        for fan in status.fans {
            let info = fan.info
            let bar = meter(info.loadFraction, width: 24)
            var line = "    fan \(info.index)  \(pad(String(Int(info.actualRPM)), 5)) RPM  \(bar) "
                     + "\(pad(String(Int(info.loadFraction * 100)), 3))%  [\(info.mode.displayName)]"
            if fan.safetyEngaged { line += "  ⚠" }
            lines.append(line)
        }

        lines.append("")
        lines.append("  TEMPERATURES")
        for group in SensorGroup.curveInputs {
            guard let summary = status.group(group) else { continue }
            lines.append("    \(pad(group.displayName, 16)) \(pad(fmt(summary.max), 6))°C max   "
                         + "\(pad(fmt(summary.mean), 6))°C mean   (\(summary.count) sensors)")
        }

        lines.append("")
        lines.append("  SYSTEM")
        lines.append("    CPU              \(pad(fmt(status.cpu.busy * 100), 6))%  busy   "
                     + "(user \(fmt(status.cpu.user * 100))%, sys \(fmt(status.cpu.system * 100))%)")
        let usedGB = Double(status.memory.usedBytes) / 1_073_741_824
        let totalGB = Double(status.memory.totalBytes) / 1_073_741_824
        lines.append("    Memory           \(pad(fmt(usedGB), 6)) GB / \(fmt(totalGB)) GB   "
                     + "(\(Int(status.memory.usedFraction * 100))%)")
        if let battery = status.battery {
            let state = battery.isPluggedIn ? (battery.isCharging ? "charging" : "AC") : "battery"
            var line = "    Battery          \(pad(fmt(battery.percentage), 6))%  \(state)"
            if let minutes = battery.minutesRemaining {
                line += "   \(minutes / 60)h\(minutes % 60)m left"
            }
            if let cycles = battery.cycleCount { line += "   \(cycles) cycles" }
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }

    private static func meter(_ fraction: Double, width: Int) -> String {
        let filled = Int((fraction.clamped(to: 0...1) * Double(width)).rounded())
        return "[" + String(repeating: "█", count: filled)
                   + String(repeating: "·", count: width - filled) + "]"
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write("fanctl: \(message)\n".data(using: .utf8)!)
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
