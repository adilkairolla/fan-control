import Foundation

public enum FanMode: UInt8, Codable, Sendable {
    case auto = 0
    case manual = 1

    public var displayName: String { self == .auto ? "Auto" : "Manual" }
}

public struct FanInfo: Codable, Sendable, Identifiable {
    public let index: Int
    public let actualRPM: Double
    public let targetRPM: Double
    public let minRPM: Double
    public let maxRPM: Double
    public let mode: FanMode

    public var id: Int { index }

    /// Position within the hardware range, 0...1. Zero when the fan does not
    /// advertise a range, which is the honest answer — not a full meter.
    public var loadFraction: Double {
        guard maxRPM > minRPM else { return 0 }
        return ((actualRPM - minRPM) / (maxRPM - minRPM)).clamped(to: 0...1)
    }
}

/// Reads and drives the system fans.
///
/// The keys are resolved against the running machine rather than hardcoded,
/// and every one except `F<n>Ac` is optional. That is not defensive
/// programming for its own sake — the first version assumed one Mac's names
/// and types, and on any other Mac a single unrecognised key made
/// `readAll()` return nothing at all. Fan speed vanished from the whole UI
/// and the presets silently did nothing, with no error anywhere to say why.
///
/// Two things this hardware taught, both now treated as *this machine's*
/// answer rather than the answer:
///  - The mode key is `F0md` (lowercase `d`) here; every Intel-era sample uses
///    `F0Md`. Both are tried.
///  - RPM keys are `flt ` here and `fpe2` on older Macs. `SMC.readNumber`
///    handles whichever the key declares.
///
/// Unchanged and still true everywhere: writing `F<n>Tg` and reading it
/// straight back returns the **old** value. The register is eventually
/// consistent; confirm control took effect by watching `F<n>Ac` converge.
public final class FanController {

    /// One fan's SMC keys as they exist on this Mac. Nil means every candidate
    /// name for that role was absent.
    public struct FanKeys: Sendable {
        public let index: Int
        public let actual: String?
        public let target: String?
        public let minimum: String?
        public let maximum: String?
        public let mode: String?

        public enum Role: String, CaseIterable, Sendable {
            case actual, target, minimum, maximum, mode
        }

        /// Every name tried for a role, in order. A diagnostic needs these so
        /// it can report what was looked for, not merely that nothing matched.
        public static func candidates(_ role: Role, fan index: Int) -> [String] {
            switch role {
            case .actual:  return ["F\(index)Ac"]
            case .target:  return ["F\(index)Tg"]
            case .minimum: return ["F\(index)Mn"]
            case .maximum: return ["F\(index)Mx"]
            case .mode:    return ["F\(index)md", "F\(index)Md"]
            }
        }

        public func resolved(_ role: Role) -> String? {
            switch role {
            case .actual:  return actual
            case .target:  return target
            case .minimum: return minimum
            case .maximum: return maximum
            case .mode:    return mode
            }
        }
    }

    /// How far to probe when `FNum` is missing. The Mac Pro tops out at six.
    private static let maxProbedFans = 8

    private let smc: SMC
    public let fanCount: Int

    /// What `FNum` claimed, before any probing. Kept for diagnostics: `FNum`
    /// absent and `FNum` reporting zero are different machines with the same
    /// symptom.
    public let declaredFanCount: Int?

    public let fanKeys: [FanKeys]

    public init(smc: SMC) throws {
        self.smc = smc

        let declared = (try? smc.readUInt8("FNum")).map(Int.init)
        self.declaredFanCount = declared

        // `FNum` is the fast path. When it is missing or zero, count the fans
        // that actually answer instead of concluding there are none — a Mac
        // whose fans are readable should never be reported as fanless.
        let count: Int
        if let declared, declared > 0 {
            count = declared
        } else {
            count = (0..<Self.maxProbedFans).prefix { smc.keyExists("F\($0)Ac") }.count
        }

        self.fanCount = count
        self.fanKeys = (0..<count).map { index in
            func find(_ role: FanKeys.Role) -> String? {
                FanKeys.candidates(role, fan: index).first { smc.keyExists($0) }
            }
            return FanKeys(index: index,
                           actual: find(.actual), target: find(.target),
                           minimum: find(.minimum), maximum: find(.maximum),
                           mode: find(.mode))
        }
    }

    private func keys(_ index: Int) throws -> FanKeys {
        guard index >= 0 && index < fanKeys.count else {
            throw SMC.SMCError.keyNotFound("F\(index)Ac")
        }
        return fanKeys[index]
    }

    /// Whether this fan can be driven at all. False means the machine reports
    /// the fan but not the keys needed to command it.
    public func isControllable(_ index: Int) -> Bool {
        guard let k = try? keys(index) else { return false }
        return k.target != nil && k.mode != nil
    }

    public var controllableFanCount: Int {
        (0..<fanCount).filter(isControllable).count
    }

    // MARK: - Reading

    /// Reads one fan.
    ///
    /// Only `F<n>Ac` is required. A Mac that names or types the other four
    /// keys differently still gets its RPM shown, which is the entire point:
    /// the previous all-or-nothing read deleted the fan from the UI.
    public func read(_ index: Int) throws -> FanInfo {
        let k = try keys(index)
        guard let actualKey = k.actual else {
            throw SMC.SMCError.keyNotFound(FanKeys.candidates(.actual, fan: index).joined())
        }

        let actual = try smc.readNumber(actualKey)
        let target = k.target.flatMap { try? smc.readNumber($0) } ?? actual
        let lo = k.minimum.flatMap { try? smc.readNumber($0) } ?? 0
        let hi = k.maximum.flatMap { try? smc.readNumber($0) } ?? 0
        let mode = k.mode
            .flatMap { try? smc.readUInt8($0) }
            .flatMap(FanMode.init(rawValue:)) ?? .auto

        return FanInfo(index: index, actualRPM: actual, targetRPM: target,
                       minRPM: lo, maxRPM: hi, mode: mode)
    }

    public func readAll() -> [FanInfo] {
        (0..<fanCount).compactMap { try? read($0) }
    }

    /// The fan's advertised range, or nil when the hardware does not report
    /// one. Nil rather than a fabricated `0...0`, which would clamp every
    /// command to a standstill.
    public func range(_ index: Int) -> ClosedRange<Double>? {
        guard let k = try? keys(index),
              let lo = k.minimum.flatMap({ try? smc.readNumber($0) }),
              let hi = k.maximum.flatMap({ try? smc.readNumber($0) }),
              hi > lo else { return nil }
        return lo...hi
    }

    // MARK: - Writing (root only)

    public func setMode(_ index: Int, _ mode: FanMode) throws {
        guard let key = try keys(index).mode else {
            throw SMC.SMCError.keyNotFound(
                FanKeys.candidates(.mode, fan: index).joined(separator: " or "))
        }
        try smc.writeUInt8(key, mode.rawValue)
    }

    /// Sets the target RPM, clamped to the fan's own advertised range.
    /// Returns the value actually commanded.
    @discardableResult
    public func setTarget(_ index: Int, rpm: Double) throws -> Double {
        guard let key = try keys(index).target else {
            throw SMC.SMCError.keyNotFound(
                FanKeys.candidates(.target, fan: index).joined())
        }
        // Clamp only against a range the hardware actually reported.
        let value = range(index).map { rpm.clamped(to: $0) } ?? max(0, rpm)
        try smc.writeNumber(key, value)
        return value
    }

    /// Hand every fan back to Apple's controller. Best-effort and never throws —
    /// this runs on exit paths where throwing would strand the fans in manual.
    public func restoreAllToAuto() {
        for i in 0..<fanCount {
            try? setMode(i, .auto)
        }
    }

    /// Take manual control of every fan.
    ///
    /// Every fan is attempted before anything is reported. Stopping at the
    /// first failure would leave a working second fan untouched because the
    /// first one's key was missing.
    public func engageManualControl() throws {
        var failure: Error?
        for i in 0..<fanCount {
            do { try setMode(i, .manual) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    /// Whether every fan currently reports manual mode.
    public func isUnderManualControl() -> Bool {
        guard fanCount > 0 else { return false }
        return (0..<fanCount).allSatisfy { (try? read($0))?.mode == .manual }
    }

    // MARK: - Diagnostics

    /// What one of a fan's keys looks like on this machine.
    ///
    /// This is what turns "no fan speed and the buttons do nothing" into a
    /// name and a type someone can act on.
    public struct KeyProbe: Sendable {
        public let role: String
        /// The key that was found, or the names tried when none was.
        public let key: String
        public let type: String?
        public let size: Int?
        public let value: Double?
        public let error: String?

        public var exists: Bool { type != nil }
    }

    public func probe(_ index: Int) -> [KeyProbe] {
        FanKeys.Role.allCases.map { role in
            let tried = FanKeys.candidates(role, fan: index)
            guard let key = (try? keys(index))?.resolved(role) else {
                return KeyProbe(role: role.rawValue,
                                key: tried.joined(separator: " or "),
                                type: nil, size: nil, value: nil,
                                error: "no such key")
            }
            let info = try? smc.keyInfo(key)
            do {
                return KeyProbe(role: role.rawValue, key: key,
                                type: info?.type, size: info?.size,
                                value: try smc.readNumber(key), error: nil)
            } catch {
                return KeyProbe(role: role.rawValue, key: key,
                                type: info?.type, size: info?.size,
                                value: nil, error: "\(error)")
            }
        }
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
