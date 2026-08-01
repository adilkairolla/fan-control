import SwiftUI
import FanKit

/// The popover. Width is fixed at 360 (a golden rectangle against its ~222pt
/// visual mass) so `NSHostingController` can report a stable size *before* the
/// popover positions itself — a popover that resizes after being shown drifts
/// away from its own arrow.
struct MenuBarView: View {
    @ObservedObject var model: StatusModel
    var onOpenDashboard: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.md) {
            header

            if let status = model.status {
                fans(status)

                VStack(alignment: .leading, spacing: Metric.sm) {
                    SectionLabel(text: "Temperatures", symbol: "thermometer.medium")
                    temperatures(status)
                }

                VStack(alignment: .leading, spacing: Metric.sm) {
                    SectionLabel(text: "System", symbol: "waveform.path.ecg")
                    load(status)
                }
                Divider().opacity(0.5)
                controls(status)
            } else {
                placeholder
            }

            Divider().opacity(0.5)
            footer
        }
        .padding(Metric.lg)
        .frame(width: Metric.popoverWidth)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Metric.sm) {
            Image(systemName: "fanblades.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .rotationEffect(.degrees(spinAngle))
                .animation(.linear(duration: 2.4).repeatForever(autoreverses: false),
                           value: spinAngle)

            Text("Fan Control")
                .font(.system(size: 15, weight: .semibold))

            Spacer(minLength: Metric.sm)

            if let status = model.status {
                Chip(text: status.thermalPressure.rawValue.capitalized,
                     symbol: status.thermalPressure.symbol,
                     color: Palette.thermal(status.thermalPressure),
                     emphasised: true)
            }
            sourceChip
        }
    }

    /// Spins only while the fans are actually moving, so the animation carries
    /// information instead of just being decoration.
    private var spinAngle: Double {
        (model.status?.averageFanRPM ?? 0) > 100 ? 360 : 0
    }

    @ViewBuilder
    private var sourceChip: some View {
        switch model.source {
        case .local:
            Chip(text: "Monitor", symbol: "eye", color: .secondary)
        case .unavailable:
            Chip(text: "No SMC", symbol: "exclamationmark.triangle.fill", color: .orange)
        case .daemon, .connecting:
            EmptyView()
        }
    }

    // MARK: - Fans

    private func fans(_ status: SystemStatus) -> some View {
        HStack(spacing: Metric.sm) {
            ForEach(status.fans) { fan in
                fanCard(fan)
            }
        }
    }

    private func fanCard(_ fan: FanState) -> some View {
        let info = fan.info
        let color = fan.safetyEngaged ? Color.orange : Palette.fan(info.loadFraction)

        return Card(padding: Metric.md, radius: Metric.radiusMd,
                    tint: fan.safetyEngaged ? .orange : nil) {
            VStack(alignment: .leading, spacing: Metric.sm) {
                HStack(spacing: Metric.xs) {
                    Image(systemName: "fanblades")
                        .font(.system(size: 9, weight: .semibold))
                    Text("FAN \(info.index)")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                    Spacer(minLength: 0)
                    if fan.safetyEngaged {
                        Image(systemName: "shield.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("Safety floor is holding this fan up")
                    }
                }
                .foregroundStyle(.tertiary)

                HStack(alignment: .firstTextBaseline, spacing: Metric.xxs) {
                    Text("\(Int(info.actualRPM))")
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("rpm")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }

                Meter(fraction: info.loadFraction, color: color)

                HStack {
                    Text(info.mode.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Text("\(Int(info.loadFraction * 100))%")
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Temperatures

    private func temperatures(_ status: SystemStatus) -> some View {
        let groups: [SensorGroup] = [.cpu, .gpu, .hotspot, .memory]
        return LazyVGrid(
            columns: [GridItem(.flexible(), spacing: Metric.sm),
                      GridItem(.flexible(), spacing: Metric.sm)],
            spacing: Metric.sm
        ) {
            ForEach(groups, id: \.self) { group in
                if let summary = status.group(group) {
                    Card(padding: Metric.sm + 2, radius: Metric.radiusSm + 1) {
                        StatReadout(symbol: group.symbol,
                                    label: group.displayName,
                                    value: String(format: "%.0f°", summary.max),
                                    color: Palette.temperature(summary.max),
                                    compact: true)
                    }
                }
            }
        }
    }

    // MARK: - Load

    private func load(_ status: SystemStatus) -> some View {
        VStack(spacing: Metric.sm) {
            meterRow(symbol: "speedometer",
                     label: "CPU",
                     value: String(format: "%.0f%%", status.cpu.busy * 100),
                     fraction: status.cpu.busy,
                     color: Color.accentColor)

            meterRow(symbol: "memorychip",
                     label: "RAM",
                     value: String(format: "%.1f / %.0f GB",
                                   Double(status.memory.usedBytes) / 1_073_741_824,
                                   Double(status.memory.totalBytes) / 1_073_741_824),
                     fraction: status.memory.usedFraction,
                     color: .purple)

            if let battery = status.battery {
                meterRow(symbol: battery.isPluggedIn ? "bolt.fill" : "battery.100",
                         label: battery.isCharging ? "Charging"
                              : (battery.isPluggedIn ? "AC Power" : "Battery"),
                         value: String(format: "%.0f%%", battery.percentage),
                         fraction: battery.percentage / 100,
                         color: battery.isPluggedIn ? .green : .secondary)
            }
        }
    }

    private func meterRow(symbol: String, label: String, value: String,
                          fraction: Double, color: Color) -> some View {
        HStack(spacing: Metric.sm) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 14)

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            Meter(fraction: fraction, color: color, height: 4)

            Text(value)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private func controls(_ status: SystemStatus) -> some View {
        if model.canControl {
            VStack(alignment: .leading, spacing: Metric.sm) {
                HStack {
                    SectionLabel(text: "Mode", symbol: "slider.horizontal.3")
                    Spacer()
                    Text(status.activeProfileName ?? status.controlMode.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: Metric.xs) {
                    modeButton(title: "Auto",
                               symbol: "gearshape.fill",
                               active: status.controlMode == .appleAuto) {
                        model.setControlMode(.appleAuto)
                    }
                    ForEach(model.profiles.filter(\.isBuiltin)) { profile in
                        modeButton(title: profile.name,
                                   symbol: ProfileIcon.symbol(for: profile.name),
                                   active: status.controlMode == .curve
                                        && status.activeProfileName == profile.name) {
                            model.applyProfile(profile.name)
                        }
                    }
                }
            }
        } else {
            helperPrompt
        }
    }

    private func modeButton(title: String, symbol: String,
                            active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Metric.xxs + 1) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metric.sm)
            .foregroundStyle(active ? Color.white : Color.secondary)
            .background {
                RoundedRectangle(cornerRadius: Metric.radiusSm, style: .continuous)
                    .fill(active ? Color.accentColor : Palette.cardFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusSm, style: .continuous)
                    .strokeBorder(active ? .clear : Palette.cardStroke, lineWidth: Metric.hairline)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: active)
    }

    /// Monitoring works with no setup; control cannot, because the kernel
    /// refuses SMC writes from unprivileged processes.
    private var helperPrompt: some View {
        Card(padding: Metric.md, radius: Metric.radiusMd) {
            VStack(alignment: .leading, spacing: Metric.xs) {
                HStack(spacing: Metric.xs) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11, weight: .medium))
                    Text("Monitoring only")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)

                Text("Changing fan speed needs the privileged helper.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("make up")
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, Metric.xs)
                    .padding(.vertical, Metric.xxs)
                    .background {
                        RoundedRectangle(cornerRadius: Metric.radiusXs, style: .continuous)
                            .fill(Palette.trackFill)
                    }
            }
        }
    }

    // MARK: - Placeholder / footer

    private var placeholder: some View {
        HStack(spacing: Metric.sm) {
            ProgressView().controlSize(.small)
            Text("Reading sensors…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Metric.lg)
    }

    private var footer: some View {
        HStack(spacing: Metric.sm) {
            Button(action: onOpenDashboard) {
                HStack(spacing: Metric.xs) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 11, weight: .medium))
                    Text("Dashboard")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Chip(text: "⌥⌘F")

            Spacer()

            Button(action: onQuit) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Fan Control")
        }
    }
}
