import SwiftUI
import Charts
import FanKit

struct CurveEditorView: View {
    @ObservedObject var model: StatusModel

    @State private var selectedID: UUID?
    @State private var draft: Profile?
    @State private var dirty = false
    @State private var draggingIndex: Int?
    @State private var saveError: String?
    @State private var pendingDeletion: Profile?

    private var fanRange: ClosedRange<Double> {
        guard let info = model.status?.fans.first?.info, info.maxRPM > info.minRPM else {
            return 2000...7000
        }
        return info.minRPM...info.maxRPM
    }

    private var temperatureRange: ClosedRange<Double> { 30...105 }

    var body: some View {
        Group {
            if model.canControl {
                HSplitView {
                    profileList
                        .frame(minWidth: 158, idealWidth: 172, maxWidth: 210)
                    editor
                        .frame(minWidth: 520)
                }
            } else {
                helperRequired
            }
        }
        .onAppear(perform: selectActiveProfile)
        .onChange(of: model.profiles.map(\.id)) { _, ids in
            reconcileSelection(with: ids)
        }
        .confirmationDialog(
            pendingDeletion.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { profile in
            Button("Delete", role: .destructive) { delete(profile) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { profile in
            Text(isDriving(profile)
                 ? "This curve is driving the fans right now. Deleting it hands them back to macOS."
                 : "A curve cannot be recovered once deleted.")
        }
    }

    /// Curves are meaningless without the ability to write to the SMC, and that
    /// is gated by the kernel rather than by anything this app can ask for.
    private var helperRequired: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("Fan control needs the helper")
                .font(.title3).bold()
            Text("""
                Sensor monitoring works with no setup — every SMC read is \
                permitted. Writing fan speed is not: macOS returns \
                kIOReturnNotPrivileged to unprivileged processes, so a small \
                root daemon has to do it.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 4) {
                Text("Install it once:").font(.caption).foregroundStyle(.secondary)
                Text("sudo ./scripts/install.sh")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Profile list

    /// Hand-rolled rather than an `NSTableView`-backed `List`: the stock list
    /// brings its own row metrics, inset grouping and selection chrome, none of
    /// which match the rest of the window. These rows use the same scale,
    /// icons and selection treatment as the toolbar tabs.
    private var profileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metric.md) {
                    profileSection("Built-in", model.profiles.filter(\.isBuiltin))

                    let custom = model.profiles.filter { !$0.isBuiltin }
                    if !custom.isEmpty {
                        profileSection("Custom", custom)
                    }
                }
                .padding(Metric.sm)
            }

            Divider().opacity(0.5)

            Button {
                model.setControlMode(.appleAuto)
            } label: {
                HStack(spacing: Metric.xs) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .medium))
                    Text("Hand back to system")
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metric.sm)
                .padding(.vertical, Metric.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Return the fans to Apple's controller")
        }
        .background(Palette.cardFill.opacity(0.6))
    }

    private func profileSection(_ title: String, _ profiles: [Profile]) -> some View {
        VStack(alignment: .leading, spacing: Metric.xxs) {
            SectionLabel(text: title)
                .padding(.horizontal, Metric.sm)
                .padding(.bottom, Metric.xxs)
            ForEach(profiles) { profileRow($0) }
        }
    }

    private func profileRow(_ profile: Profile) -> some View {
        let selected = selectedID == profile.id
        let active = isDriving(profile)

        return Button {
            selectedID = profile.id
            draft = profile
            dirty = false
        } label: {
            HStack(spacing: Metric.sm) {
                Image(systemName: ProfileIcon.symbol(for: profile.name))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 15)

                Text(profile.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)

                Spacer(minLength: 0)

                // A dot, not a checkmark: "active" and "selected for editing"
                // are different states and shouldn't compete visually.
                if active {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .help("Currently driving the fans")
                }
            }
            .padding(.horizontal, Metric.sm)
            .padding(.vertical, Metric.xs + 1)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: Metric.radiusSm, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.10) : .clear)
            }
        }
        .buttonStyle(.plain)
        // Deleting from the row is what people reach for first; the trash in
        // the editor header requires opening the thing you want gone.
        .contextMenu {
            Button("Apply") { model.applyProfile(profile.name) }
            if !profile.isBuiltin {
                Divider()
                Button("Delete…", role: .destructive) { pendingDeletion = profile }
            }
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        if let draft {
            VStack(alignment: .leading, spacing: Metric.sm) {
                header(draft)
                Card(padding: Metric.sm + 2, radius: Metric.radiusMd + 2) { curveChart(draft) }
                Card(padding: Metric.sm + 2, radius: Metric.radiusMd + 2) { pointsTable(draft) }
                Spacer(minLength: 0)
                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(Metric.md)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.largeTitle).foregroundStyle(.tertiary)
                Text("Select a profile").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ profile: Profile) -> some View {
        HStack(spacing: Metric.md) {
            Image(systemName: ProfileIcon.symbol(for: profile.name))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: Metric.xl, height: Metric.xl)
                .background {
                    RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).font(.system(size: 15, weight: .semibold))
                Text(profile.isBuiltin
                     ? "Built-in — edits fork into a custom copy"
                     : "Custom profile")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: Metric.sm)

            Picker("", selection: inputBinding) {
                ForEach(SensorGroup.curveInputs, id: \.self) { group in
                    Label(group.displayName, systemImage: group.symbol).tag(group)
                }
            }
            .labelsHidden()
            .frame(width: 168)
            .help("Which sensor group drives this curve")

            Button("Apply") { model.applyProfile(profile.name) }
                .disabled(dirty)
                .help(dirty ? "Save your edits first" : "Activate this profile")

            Button(dirty ? "Save" : "Saved") { save(profile) }
                .buttonStyle(.borderedProminent)
                .disabled(!dirty)

            if !profile.isBuiltin {
                Button(role: .destructive) {
                    pendingDeletion = profile
                } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .help("Delete this profile")
            }
        }
    }

    private var inputBinding: Binding<SensorGroup> {
        Binding(
            get: { draft?.curves.first?.input ?? .cpu },
            set: { group in
                guard var profile = draft else { return }
                for index in profile.curves.indices {
                    profile.curves[index] = FanCurve(input: group, points: profile.curves[index].points)
                }
                draft = profile
                dirty = true
            }
        )
    }

    // MARK: - Chart

    private func curveChart(_ profile: Profile) -> some View {
        let curve = profile.curves.first ?? FanCurve(input: .cpu, points: [])
        let currentTemp = model.status?.group(curve.input)?.max

        return VStack(alignment: .leading, spacing: Metric.sm) {
            HStack {
                SectionLabel(text: "Curve", symbol: "point.topleft.down.curvedto.point.bottomright.up")
                Spacer()
                Text("drag a point to reshape")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }

            Chart {
                // The safety floor the daemon enforces underneath any curve.
                ForEach(safetyFloorSamples(), id: \.celsius) { sample in
                    LineMark(x: .value("°C", sample.celsius),
                             y: .value("RPM", sample.rpm),
                             series: .value("Series", "Safety floor"))
                        .foregroundStyle(.red.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }

                ForEach(curveSamples(curve), id: \.celsius) { sample in
                    LineMark(x: .value("°C", sample.celsius),
                             y: .value("RPM", sample.rpm),
                             series: .value("Series", "Curve"))
                        .foregroundStyle(Color.accentColor)
                        .interpolationMethod(.linear)
                }

                ForEach(Array(curve.points.enumerated()), id: \.offset) { index, point in
                    PointMark(x: .value("°C", point.celsius),
                              y: .value("RPM", point.rpm))
                        .foregroundStyle(draggingIndex == index ? Color.orange : Color.accentColor)
                        .symbolSize(draggingIndex == index ? 160 : 90)
                }

                if let currentTemp {
                    RuleMark(x: .value("°C", currentTemp))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("now \(currentTemp, specifier: "%.0f")°C")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartXScale(domain: temperatureRange)
            .chartYScale(domain: fanRange)
            .chartXAxisLabel("Temperature (°C)")
            .chartYAxisLabel("Fan speed (RPM)")
            .frame(height: 260)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(dragGesture(proxy: proxy, geometry: geometry, curve: curve))
                }
            }
        }
    }

    private func dragGesture(proxy: ChartProxy,
                             geometry: GeometryProxy,
                             curve: FanCurve) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let plotFrame = proxy.plotFrame else { return }
                let origin = geometry[plotFrame].origin
                let location = CGPoint(x: value.location.x - origin.x,
                                       y: value.location.y - origin.y)
                guard let celsius: Double = proxy.value(atX: location.x),
                      let rpm: Double = proxy.value(atY: location.y) else { return }

                // Latch onto the nearest point on first contact, then keep it.
                if draggingIndex == nil {
                    draggingIndex = nearestPointIndex(to: (celsius, rpm), in: curve, proxy: proxy)
                }
                guard let index = draggingIndex, var profile = draft,
                      let first = profile.curves.first,
                      index < first.points.count else { return }

                var points = first.points
                points[index] = CurvePoint(
                    celsius: celsius.clamped(to: temperatureRange),
                    rpm: rpm.clamped(to: fanRange)
                )
                // Re-sorting here would make the dragged point jump under the
                // cursor mid-gesture; FanCurve's init sorts on commit instead.
                for curveIndex in profile.curves.indices {
                    profile.curves[curveIndex] = FanCurve(input: first.input, points: points)
                }
                draft = profile
                dirty = true
            }
            .onEnded { _ in draggingIndex = nil }
    }

    private func nearestPointIndex(to target: (celsius: Double, rpm: Double),
                                   in curve: FanCurve,
                                   proxy: ChartProxy) -> Int? {
        // Compare in normalised axis space so the two very different units
        // (°C vs RPM) contribute comparably to "nearest".
        let tSpan = temperatureRange.upperBound - temperatureRange.lowerBound
        let rSpan = fanRange.upperBound - fanRange.lowerBound
        var best: (index: Int, distance: Double)?

        for (index, point) in curve.points.enumerated() {
            let dt = (point.celsius - target.celsius) / tSpan
            let dr = (point.rpm - target.rpm) / rSpan
            let distance = (dt * dt + dr * dr).squareRoot()
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        // Ignore taps far from any handle.
        guard let best, best.distance < 0.12 else { return nil }
        return best.index
    }

    private func curveSamples(_ curve: FanCurve) -> [CurvePoint] {
        stride(from: temperatureRange.lowerBound, through: temperatureRange.upperBound, by: 1.0)
            .map { CurvePoint(celsius: $0, rpm: curve.rpm(at: $0).clamped(to: fanRange)) }
    }

    private func safetyFloorSamples() -> [CurvePoint] {
        let policy = SafetyPolicy.standard
        return stride(from: temperatureRange.lowerBound, through: temperatureRange.upperBound, by: 1.0)
            .map { CurvePoint(celsius: $0, rpm: policy.floorRPM(dieCelsius: $0, range: fanRange)) }
    }

    // MARK: - Points table

    private func pointsTable(_ profile: Profile) -> some View {
        let points = profile.curves.first?.points ?? []
        return VStack(alignment: .leading, spacing: Metric.sm) {
            HStack {
                SectionLabel(text: "Points", symbol: "list.bullet")
                Spacer()
                Button {
                    addPoint()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                        VStack(spacing: 3) {
                            Text("\(point.celsius, specifier: "%.0f")°C")
                                .font(.system(.caption, design: .monospaced))
                            Text("\(Int(point.rpm))")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Button {
                                removePoint(index)
                            } label: {
                                Image(systemName: "minus.circle.fill").font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .disabled(points.count <= 2)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    // MARK: - Mutations

    private func addPoint() {
        guard var profile = draft, let curve = profile.curves.first else { return }
        let hottest = curve.points.max { $0.celsius < $1.celsius }
        let newPoint = CurvePoint(celsius: min((hottest?.celsius ?? 70) + 5, 104),
                                  rpm: hottest?.rpm ?? fanRange.lowerBound)
        let points = curve.points + [newPoint]
        for index in profile.curves.indices {
            profile.curves[index] = FanCurve(input: curve.input, points: points)
        }
        draft = profile
        dirty = true
    }

    private func removePoint(_ index: Int) {
        guard var profile = draft, let curve = profile.curves.first,
              curve.points.count > 2, index < curve.points.count else { return }
        var points = curve.points
        points.remove(at: index)
        for curveIndex in profile.curves.indices {
            profile.curves[curveIndex] = FanCurve(input: curve.input, points: points)
        }
        draft = profile
        dirty = true
    }

    private func save(_ profile: Profile) {
        saveError = nil
        var toSave = profile
        if profile.isBuiltin {
            // Built-ins are regenerated per-machine, so edits fork into a copy.
            toSave = Profile(id: UUID(),
                             name: uniqueName(basedOn: profile.name),
                             curves: profile.curves,
                             isBuiltin: false)
        }
        model.saveProfile(toSave)
        draft = toSave
        selectedID = toSave.id
        dirty = false
    }

    private func uniqueName(basedOn base: String) -> String {
        let existing = Set(model.profiles.map(\.name))
        var candidate = "\(base) copy"
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(base) copy \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func isDriving(_ profile: Profile) -> Bool {
        model.status?.controlMode == .curve
            && model.status?.activeProfileName == profile.name
    }

    /// Deletion moves the selection the way a list should: onto whatever now
    /// occupies the deleted row, or the last one if you deleted the bottom.
    ///
    /// The old flow blanked the editor and left the row in place until the next
    /// slow poll, so nothing on screen said the profile was gone — you had to
    /// click away and back for the list to catch up. Now the row goes at once
    /// (`StatusModel.deleteProfile` drops it optimistically) and the editor
    /// lands on a neighbour instead of an empty state.
    private func delete(_ profile: Profile) {
        pendingDeletion = nil
        saveError = nil

        // Computed before the delete, so the index still means something.
        let custom = model.profiles.filter { !$0.isBuiltin }
        let position = custom.firstIndex { $0.id == profile.id }
        let remaining = custom.filter { $0.id != profile.id }
        let replacement = position.flatMap { index in
            remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
        } ?? model.profiles.first { $0.id != profile.id }

        model.deleteProfile(profile.id)

        selectedID = replacement?.id
        draft = replacement
        dirty = false
    }

    /// Keeps the editor honest when the list changes underneath it — a delete
    /// confirmed here, or one done from `fanctl` while the window is open.
    /// Without this the pane keeps rendering a profile that no longer exists.
    private func reconcileSelection(with ids: [UUID]) {
        guard let current = selectedID else {
            selectActiveProfile()
            return
        }
        // Unsaved edits outrank tidiness: leave the draft be and let Save
        // re-create it under a fresh id.
        guard !ids.contains(current), !dirty else { return }
        draft = nil
        selectedID = nil
        selectActiveProfile()
    }

    private func selectActiveProfile() {
        guard draft == nil else { return }
        let active = model.profiles.first { $0.name == model.status?.activeProfileName }
            ?? model.profiles.first
        guard let active else { return }
        selectedID = active.id
        draft = active
        dirty = false
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
