import SwiftUI
import FanKit

// MARK: - Metrics
//
// Everything derives from φ ≈ 1.618. Rather than multiplying by 1.618 and
// landing on fractional pixels, the scale is Fibonacci: consecutive terms
// approach the golden ratio, so any two adjacent steps are already in golden
// proportion and every value lands on a whole pixel.
//
//   3 · 5 · 8 · 13 · 21 · 34 · 55
//
// Two rules follow from that and are applied consistently:
//
//   radius = padding / φ   →  the next step *down* the scale
//   gap    = padding / φ   →  children breathe less than the container's edge
//
// So a card padded 13 gets an 8pt radius and 8pt internal gaps. Nested
// containers use concentric radii (inner = outer − padding) so curves stay
// parallel instead of drifting.

enum Metric {
    static let phi: CGFloat = 1.618

    static let xxs: CGFloat = 3
    static let xs: CGFloat = 5
    static let sm: CGFloat = 8
    static let md: CGFloat = 13
    static let lg: CGFloat = 21
    static let xl: CGFloat = 34
    static let xxl: CGFloat = 55

    /// radius = padding / φ
    static let radiusXs: CGFloat = 3
    static let radiusSm: CGFloat = 5
    static let radiusMd: CGFloat = 8
    static let radiusLg: CGFloat = 13
    static let radiusXl: CGFloat = 21

    /// Keeps a nested corner parallel to its parent's.
    static func concentric(outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(2, outer - inset)
    }

    /// 360 / φ ≈ 222 — a golden rectangle for the popover's visual mass.
    static let popoverWidth: CGFloat = 360
    static let windowWidth: CGFloat = 1160
    static let windowHeight: CGFloat = 717     // 1160 / φ
    static let meterHeight: CGFloat = 5
    static let hairline: CGFloat = 1

    /// Plot heights. 233 and 144 are consecutive Fibonacci terms, so the
    /// primary chart stands in exact golden proportion to the pair beneath it.
    /// They are the reference values; the real heights are the same ratio
    /// applied to whatever the window actually gives us.
    static let plotTall: CGFloat = 233
    static let plotShort: CGFloat = 144
    static let plotFloor: CGFloat = 89

    /// A sparkline takes the far side of a hero card. Bounded 55–89 so the
    /// numerals keep roughly φ of the card's inner width at any window size.
    static let sparkMinWidth: CGFloat = 55
    static let sparkMaxWidth: CGFloat = 89
    static let sparkHeight: CGFloat = 21
}

// MARK: - Palette

enum Palette {
    /// Temperature ramp. Thresholds are tuned to this hardware rather than
    /// generic: the CPU sits in the 70s under normal load, so 70 must not
    /// read as alarming.
    static func temperature(_ celsius: Double) -> Color {
        switch celsius {
        case ..<55:  return Color(red: 0.30, green: 0.78, blue: 0.55)   // calm green
        case ..<70:  return Color(red: 0.55, green: 0.78, blue: 0.42)   // green-yellow
        case ..<82:  return Color(red: 0.94, green: 0.76, blue: 0.30)   // amber
        case ..<92:  return Color(red: 0.96, green: 0.55, blue: 0.26)   // orange
        default:     return Color(red: 0.94, green: 0.36, blue: 0.36)   // red
        }
    }

    /// Fan load ramp — cool blue through to hot cyan-white as it spins up.
    static func fan(_ fraction: Double) -> Color {
        let clamped = min(max(fraction, 0), 1)
        return Color(hue: 0.58 - clamped * 0.06,
                     saturation: 0.62 + clamped * 0.24,
                     brightness: 0.78 + clamped * 0.16)
    }

    static func thermal(_ pressure: ThermalPressure) -> Color {
        switch pressure {
        case .nominal:  return Color(red: 0.30, green: 0.78, blue: 0.55)
        case .fair:     return Color(red: 0.94, green: 0.76, blue: 0.30)
        case .serious:  return Color(red: 0.96, green: 0.55, blue: 0.26)
        case .critical: return Color(red: 0.94, green: 0.36, blue: 0.36)
        case .unknown:  return .secondary
        }
    }

    static let cardFill = Color.primary.opacity(0.045)
    static let cardStroke = Color.primary.opacity(0.07)
    static let trackFill = Color.primary.opacity(0.09)
}

// MARK: - Iconography
//
// Every symbol below was verified to resolve on this macOS build. `gpu` does
// not exist as an SF Symbol, hence `display` for the GPU group.

extension SensorGroup {
    var symbol: String {
        switch self {
        case .cpu:           return "cpu"
        case .gpu:           return "display"
        case .memory:        return "memorychip"
        case .hotspot:       return "flame.fill"
        case .powerDelivery: return "bolt.fill"
        case .storage:       return "internaldrive"
        case .battery:       return "battery.100"
        case .ambient:       return "wind"
        case .wireless:      return "wifi"
        case .other:         return "circle.hexagongrid.fill"
        }
    }
}

extension ThermalPressure {
    var symbol: String {
        switch self {
        case .nominal:  return "checkmark.circle.fill"
        case .fair:     return "thermometer.medium"
        case .serious:  return "thermometer.high"
        case .critical: return "exclamationmark.triangle.fill"
        case .unknown:  return "thermometer"
        }
    }
}

enum ProfileIcon {
    static func symbol(for name: String) -> String {
        switch name.lowercased() {
        case "silent":   return "leaf.fill"
        case "balanced": return "gauge.with.dots.needle.50percent"
        case "cool":     return "snowflake"
        case "max":      return "hare.fill"
        default:         return "slider.horizontal.3"
        }
    }
}

// MARK: - Components

/// A rounded surface with the padding/radius pair the scale prescribes.
struct Card<Content: View>: View {
    var padding: CGFloat = Metric.md
    var radius: CGFloat = Metric.radiusMd
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A card contains its contents, full stop. Swift Charts in
            // particular will happily draw a mark outside the plotting area,
            // and one panel bleeding over another is never the intent.
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tint?.opacity(0.10) ?? Palette.cardFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(tint?.opacity(0.22) ?? Palette.cardStroke,
                                  lineWidth: Metric.hairline)
            }
    }
}

/// Horizontal progress meter. Capsule so the radius is always exactly half the
/// height — the one case where "radius = height / 2" beats the scale.
struct Meter: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = Metric.meterHeight

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Palette.trackFill)
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(colors: [color.opacity(0.75), color],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: max(height, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.45), value: fraction)
    }
}

/// Small pill used for status and shortcut hints.
struct Chip: View {
    var text: String
    var symbol: String?
    var color: Color = .secondary
    var emphasised = false

    var body: some View {
        HStack(spacing: Metric.xxs + 1) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, Metric.sm)
        .padding(.vertical, Metric.xxs)
        .background {
            Capsule(style: .continuous)
                .fill(color.opacity(emphasised ? 0.16 : 0.10))
        }
    }
}

/// Numeric readout with a leading glyph. Used across popover and dashboard so
/// the two never drift apart visually.
struct StatReadout: View {
    var symbol: String
    var label: String
    var value: String
    var color: Color
    var compact = false

    var body: some View {
        HStack(spacing: Metric.sm) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 11 : 13, weight: .medium))
                .foregroundStyle(color)
                .frame(width: compact ? 14 : 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                // The number carries the colour, not just the glyph — heat
                // should be readable without parsing the digits.
                Text(value)
                    .font(.system(size: compact ? 15 : 17, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A micro chart for the far side of a hero card: trend only, no axes, no
/// labels, no ticks.
///
/// It exists because a 220pt-wide card holding one number is mostly empty, and
/// the honest fix for empty space is information rather than a smaller box.
/// The numeral beside it already says *what* — this only has to answer *which
/// way is it going*.
struct Sparkline: View {
    var values: [Double]
    var color: Color

    /// Smallest range, in the series' own units, that is allowed to fill the
    /// full height. Without it a sensor that only wobbles 2 °C gets its noise
    /// amplified into a mountain range, which is a lie — the hotspot group on
    /// this machine sits at 93–95 all day and has to *look* flat.
    var minimumSpan: Double = 1

    /// More than this is wasted on a strip 55–89pt wide.
    private static let maxPoints = 64

    var body: some View {
        GeometryReader { geometry in
            let points = trace(in: geometry.size)
            if points.count > 1 {
                ZStack {
                    area(points, height: geometry.size.height)
                        .fill(LinearGradient(colors: [color.opacity(0.26),
                                                      color.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
                    line(points)
                        .stroke(color.opacity(0.85),
                                style: StrokeStyle(lineWidth: 1.5,
                                                   lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        return path
    }

    private func area(_ points: [CGPoint], height: CGFloat) -> Path {
        var path = line(points)
        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: height))
        path.addLine(to: CGPoint(x: points[0].x, y: height))
        path.closeSubpath()
        return path
    }

    private func trace(in size: CGSize) -> [CGPoint] {
        let series = downsampled
        guard series.count > 1,
              let low = series.min(), let high = series.max() else { return [] }

        // Anything quieter than `minimumSpan` is drawn against that span and
        // centred, so a flat series renders flat through the middle instead of
        // collapsing onto an edge or being magnified into false drama.
        let observed = high - low
        let span = max(observed, minimumSpan)
        let base = low - (span - observed) / 2

        let inset: CGFloat = 2      // room for the stroke at the extremes
        let usable = max(size.height - inset * 2, 1)
        return series.enumerated().map { index, value in
            CGPoint(x: size.width * CGFloat(index) / CGFloat(series.count - 1),
                    y: inset + usable * (1 - CGFloat((value - base) / span)))
        }
    }

    private var downsampled: [Double] {
        guard values.count > Self.maxPoints else { return values }
        let step = Double(values.count - 1) / Double(Self.maxPoints - 1)
        return (0..<Self.maxPoints).map { values[Int((Double($0) * step).rounded())] }
    }
}

struct LegendEntry: Identifiable {
    var name: String
    var color: Color
    var id: String { name }
}

/// Legend key, drawn in a card header rather than inside the plot. Swift
/// Charts' own legend claims a full row of the plotting area and renders in
/// system styling that matches nothing else in the window.
struct LegendDot: View {
    var entry: LegendEntry

    var body: some View {
        HStack(spacing: Metric.xxs + 1) {
            Circle()
                .fill(entry.color)
                .frame(width: 6, height: 6)
            Text(entry.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// Section label — small, tracked-out, quiet.
struct SectionLabel: View {
    var text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: Metric.xs) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            Text(text.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
        }
        .foregroundStyle(.tertiary)
    }
}
