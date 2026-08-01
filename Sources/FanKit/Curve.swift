import Foundation

// MARK: - Curve

public struct CurvePoint: Codable, Sendable, Equatable {
    public var celsius: Double
    public var rpm: Double

    public init(celsius: Double, rpm: Double) {
        self.celsius = celsius
        self.rpm = rpm
    }
}

/// A piecewise-linear temperature → RPM mapping for one fan.
public struct FanCurve: Codable, Sendable, Equatable {
    /// Which sensor aggregate drives this curve.
    public var input: SensorGroup
    /// Sorted ascending by temperature. Flat extrapolation outside the ends.
    public var points: [CurvePoint]

    public init(input: SensorGroup, points: [CurvePoint]) {
        self.input = input
        self.points = points.sorted { $0.celsius < $1.celsius }
    }

    public func rpm(at celsius: Double) -> Double {
        guard let first = points.first else { return 0 }
        guard points.count > 1 else { return first.rpm }
        if celsius <= first.celsius { return first.rpm }
        guard let last = points.last else { return first.rpm }
        if celsius >= last.celsius { return last.rpm }

        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            if celsius >= a.celsius && celsius <= b.celsius {
                let span = b.celsius - a.celsius
                guard span > 0 else { return b.rpm }
                let t = (celsius - a.celsius) / span
                return a.rpm + t * (b.rpm - a.rpm)
            }
        }
        return last.rpm
    }
}

// MARK: - Safety

/// A hard floor the daemon enforces underneath every user curve.
///
/// The UI can *raise* this but never remove it, which is what makes "full
/// override" (letting curves run quieter and hotter than Apple's auto) safe to
/// offer at all.
///
/// Driven by max(CPU, GPU) die temperature rather than the `Tf*` hotspot group:
/// on this hardware `Tf*` reads 93–95 °C during ordinary heavy load, so keying
/// safety off it would peg the fans permanently.
public struct SafetyPolicy: Codable, Sendable, Equatable {
    /// Fractions of the fan's usable range, not absolute RPM, so the policy
    /// travels across machines with different fan hardware.
    public var floorPoints: [CurvePoint]
    /// Above this, fans go to maximum regardless of any curve.
    public var criticalCelsius: Double

    public init(floorPoints: [CurvePoint], criticalCelsius: Double) {
        self.floorPoints = floorPoints.sorted { $0.celsius < $1.celsius }
        self.criticalCelsius = criticalCelsius
    }

    /// `rpm` values here are fractions in 0...1.
    public static let standard = SafetyPolicy(
        floorPoints: [
            CurvePoint(celsius: 85, rpm: 0.00),
            CurvePoint(celsius: 90, rpm: 0.40),
            CurvePoint(celsius: 95, rpm: 0.70),
            CurvePoint(celsius: 100, rpm: 1.00),
        ],
        criticalCelsius: 103
    )

    /// Minimum RPM permitted at this temperature, in absolute terms.
    public func floorRPM(dieCelsius: Double, range: ClosedRange<Double>) -> Double {
        if dieCelsius >= criticalCelsius { return range.upperBound }
        let fraction = FanCurve(input: .cpu, points: floorPoints).rpm(at: dieCelsius)
        guard fraction > 0 else { return range.lowerBound }
        return range.lowerBound + fraction.clamped(to: 0...1) * (range.upperBound - range.lowerBound)
    }
}

// MARK: - Evaluation

public struct EvaluatorTuning: Codable, Sendable, Equatable {
    /// Temperature must fall this far below the ratchet before output drops.
    public var hysteresisCelsius: Double
    /// Slew limit so the fan ramps instead of stepping. Emergency floor bypasses this.
    public var maxRPMPerSecond: Double

    public init(hysteresisCelsius: Double = 3.0, maxRPMPerSecond: Double = 500) {
        self.hysteresisCelsius = hysteresisCelsius
        self.maxRPMPerSecond = maxRPMPerSecond
    }

    public static let standard = EvaluatorTuning()
}

public struct EvaluationResult: Sendable {
    public let commandedRPM: Double
    public let curveRPM: Double
    public let floorRPM: Double
    /// True when the safety floor, not the user curve, is deciding the outcome.
    public let safetyEngaged: Bool
}

/// Stateful per-fan evaluator: ratcheting hysteresis plus slew limiting.
public final class CurveEvaluator {
    private let tuning: EvaluatorTuning
    private var ratchetCelsius: Double?
    private var lastRPM: Double?

    public init(tuning: EvaluatorTuning = .standard) {
        self.tuning = tuning
    }

    public func reset() {
        ratchetCelsius = nil
        lastRPM = nil
    }

    /// - Parameters:
    ///   - inputCelsius: temperature of the group the curve is bound to
    ///   - dieCelsius: max(CPU, GPU) — drives the safety floor
    ///   - dt: seconds since the previous evaluation
    public func evaluate(curve: FanCurve,
                         inputCelsius: Double,
                         dieCelsius: Double,
                         safety: SafetyPolicy,
                         range: ClosedRange<Double>,
                         dt: Double) -> EvaluationResult {

        // Ratchet: rise immediately, fall only after clearing the hysteresis band.
        let ratchet: Double
        if let current = ratchetCelsius {
            if inputCelsius >= current {
                ratchet = inputCelsius
            } else if inputCelsius < current - tuning.hysteresisCelsius {
                ratchet = inputCelsius + tuning.hysteresisCelsius
            } else {
                ratchet = current
            }
        } else {
            ratchet = inputCelsius
        }
        ratchetCelsius = ratchet

        let curveRPM = curve.rpm(at: ratchet).clamped(to: range)

        // Slew-limit the user curve only.
        var slewed = curveRPM
        if let previous = lastRPM, dt > 0 {
            let maxDelta = tuning.maxRPMPerSecond * dt
            slewed = previous + (curveRPM - previous).clamped(to: -maxDelta...maxDelta)
        }

        // Safety floor applies instantly, never slew-limited.
        let floor = safety.floorRPM(dieCelsius: dieCelsius, range: range)
        let commanded = max(slewed, floor).clamped(to: range)

        lastRPM = commanded
        return EvaluationResult(commandedRPM: commanded,
                                curveRPM: curveRPM,
                                floorRPM: floor,
                                safetyEngaged: floor > slewed + 1)
    }
}

// MARK: - Profiles

public struct Profile: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// One curve per fan. If shorter than the fan count, the last entry repeats.
    public var curves: [FanCurve]
    public var isBuiltin: Bool

    public init(id: UUID = UUID(), name: String, curves: [FanCurve], isBuiltin: Bool = false) {
        self.id = id
        self.name = name
        self.curves = curves
        self.isBuiltin = isBuiltin
    }

    public func curve(forFan index: Int) -> FanCurve? {
        guard !curves.isEmpty else { return nil }
        return index < curves.count ? curves[index] : curves[curves.count - 1]
    }
}

extension Profile {
    /// Stable identities for the built-ins. These must not change: a saved
    /// `activeProfileID` has to still resolve after a daemon restart, and the
    /// curves themselves are regenerated per-machine from the fan range.
    private enum BuiltinID {
        static let silent   = UUID(uuidString: "00000000-0000-0000-0000-00000000FA01")!
        static let balanced = UUID(uuidString: "00000000-0000-0000-0000-00000000FA02")!
        static let cool     = UUID(uuidString: "00000000-0000-0000-0000-00000000FA03")!
        static let max      = UUID(uuidString: "00000000-0000-0000-0000-00000000FA04")!
    }

    /// Built-ins generated against the machine's real fan range, so they adapt
    /// to hardware instead of hardcoding this Mac's 2317–7826 RPM.
    public static func builtins(range: ClosedRange<Double>) -> [Profile] {
        func rpm(_ fraction: Double) -> Double {
            range.lowerBound + fraction.clamped(to: 0...1) * (range.upperBound - range.lowerBound)
        }
        func curve(_ pairs: [(Double, Double)]) -> FanCurve {
            FanCurve(input: .cpu, points: pairs.map { CurvePoint(celsius: $0.0, rpm: rpm($0.1)) })
        }

        return [
            Profile(id: BuiltinID.silent, name: "Silent", curves: [curve([
                (45, 0.00), (60, 0.00), (72, 0.15), (80, 0.40), (88, 0.70), (95, 1.00),
            ])], isBuiltin: true),

            Profile(id: BuiltinID.balanced, name: "Balanced", curves: [curve([
                (45, 0.00), (58, 0.15), (68, 0.35), (78, 0.60), (86, 0.85), (93, 1.00),
            ])], isBuiltin: true),

            Profile(id: BuiltinID.cool, name: "Cool", curves: [curve([
                (40, 0.20), (55, 0.40), (65, 0.60), (75, 0.85), (85, 1.00),
            ])], isBuiltin: true),

            Profile(id: BuiltinID.max, name: "Max", curves: [curve([
                (0, 1.00), (100, 1.00),
            ])], isBuiltin: true),
        ]
    }
}
