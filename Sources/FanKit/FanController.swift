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

    /// Position within the hardware range, 0...1.
    public var loadFraction: Double {
        guard maxRPM > minRPM else { return 0 }
        return ((actualRPM - minRPM) / (maxRPM - minRPM)).clamped(to: 0...1)
    }
}

/// Reads and drives the system fans.
///
/// Two things learned the hard way on M5 Max, both encoded here:
///  - The mode key is `F0md` (lowercase `d`), *not* the `F0Md` that every
///    Intel-era SMC snippet uses. The uppercase variant does not exist.
///  - Writing `F<n>Tg` and immediately reading it back returns the **old**
///    value — the register is eventually consistent. Confirm that control took
///    effect by watching `F<n>Ac` converge instead.
public final class FanController {

    private let smc: SMC
    public let fanCount: Int

    public init(smc: SMC) throws {
        self.smc = smc
        self.fanCount = Int((try? smc.readUInt8("FNum")) ?? 0)
    }

    // MARK: - Key names

    private func actualKey(_ i: Int) -> String { "F\(i)Ac" }
    private func targetKey(_ i: Int) -> String { "F\(i)Tg" }
    private func minKey(_ i: Int)    -> String { "F\(i)Mn" }
    private func maxKey(_ i: Int)    -> String { "F\(i)Mx" }
    private func modeKey(_ i: Int)   -> String { "F\(i)md" }

    // MARK: - Reading

    public func read(_ index: Int) throws -> FanInfo {
        FanInfo(index: index,
                actualRPM: Double(try smc.readFloat(actualKey(index))),
                targetRPM: Double(try smc.readFloat(targetKey(index))),
                minRPM: Double(try smc.readFloat(minKey(index))),
                maxRPM: Double(try smc.readFloat(maxKey(index))),
                mode: FanMode(rawValue: try smc.readUInt8(modeKey(index))) ?? .auto)
    }

    public func readAll() -> [FanInfo] {
        (0..<fanCount).compactMap { try? read($0) }
    }

    public func range(_ index: Int) throws -> ClosedRange<Double> {
        let lo = Double(try smc.readFloat(minKey(index)))
        let hi = Double(try smc.readFloat(maxKey(index)))
        guard hi > lo else { return lo...lo }
        return lo...hi
    }

    // MARK: - Writing (root only)

    public func setMode(_ index: Int, _ mode: FanMode) throws {
        try smc.writeUInt8(modeKey(index), mode.rawValue)
    }

    /// Sets the target RPM, clamped to the fan's own advertised range.
    /// Returns the value actually commanded.
    @discardableResult
    public func setTarget(_ index: Int, rpm: Double) throws -> Double {
        let bounds = try range(index)
        let clamped = rpm.clamped(to: bounds)
        try smc.writeFloat(targetKey(index), Float(clamped))
        return clamped
    }

    /// Hand every fan back to Apple's controller. Best-effort and never throws —
    /// this runs on exit paths where throwing would strand the fans in manual.
    public func restoreAllToAuto() {
        for i in 0..<fanCount {
            try? setMode(i, .auto)
        }
    }

    /// Take manual control of every fan.
    public func engageManualControl() throws {
        for i in 0..<fanCount {
            try setMode(i, .manual)
        }
    }

    /// Whether every fan currently reports manual mode.
    public func isUnderManualControl() -> Bool {
        guard fanCount > 0 else { return false }
        return (0..<fanCount).allSatisfy { (try? read($0))?.mode == .manual }
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
