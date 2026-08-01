import Foundation
import Combine
import FanKit

/// Publishes what the UI renders, from whichever source is available.
///
/// Two modes, and the distinction matters:
///
///  - **daemon** — `fand` is installed. Full monitoring *and* fan control.
///  - **local** — no daemon. The app opens its own SMC handle and reads
///    everything directly. All monitoring works; control is unavailable,
///    because SMC writes return `kIOReturnNotPrivileged` to a normal user.
///
/// The local path is why the app is useful with zero installation.
@MainActor
final class StatusModel: ObservableObject {

    enum Source: Equatable {
        case connecting
        case daemon
        case local
        case unavailable(String)
    }

    @Published private(set) var status: SystemStatus?
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var history: [HistorySample] = []
    @Published private(set) var source: Source = .connecting
    @Published var historyWindow: HistoryWindow = .lastHour

    /// Fan control needs the privileged daemon. Monitoring does not.
    var canControl: Bool { source == .daemon }

    enum HistoryWindow: String, CaseIterable, Identifiable {
        case lastHour = "1h"
        case sixHours = "6h"
        case day = "24h"
        case week = "7d"

        var id: String { rawValue }
        var seconds: Int {
            switch self {
            case .lastHour: return 3600
            case .sixHours: return 6 * 3600
            case .day:      return 24 * 3600
            case .week:     return 7 * 24 * 3600
            }
        }
    }

    private let queue = DispatchQueue(label: "app.poll", qos: .utility)
    private var timer: Timer?
    private var tick = 0

    /// Immutable reference, so the polling closure can reach it without
    /// crossing the main actor. The holder does its own locking.
    private let localMonitor = LocalMonitorHolder()

    // MARK: - Lifecycle

    func start(interval: TimeInterval = 1.0) {
        stop()
        poll()

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Polling

    private func poll() {
        tick += 1
        let wantHistory = (tick % 15 == 1)
        let seconds = historyWindow.seconds

        queue.async { [weak self] in
            guard let self else { return }
            let client = FanControlClient()

            // Prefer the daemon: it is authoritative and has real history.
            if let response = try? client.send(Request(cmd: .status)),
               let status = response.status {
                let profiles = wantHistory
                    ? (try? client.send(Request(cmd: .listProfiles)))?.profiles
                    : nil
                let history = wantHistory
                    ? (try? client.send(Request(cmd: .history, seconds: seconds)))?.history
                    : nil

                Task { @MainActor in
                    self.source = .daemon
                    self.status = status
                    if let profiles { self.profiles = profiles }
                    if let history { self.history = history }
                }
                return
            }

            // No daemon — read the hardware ourselves.
            let monitor: LocalMonitor
            do {
                guard let resolved = try self.localMonitor.get() else { return }
                monitor = resolved
            } catch {
                let message = "\(error)"
                Task { @MainActor in self.source = .unavailable(message) }
                return
            }

            let status = monitor.readStatus()
            let history = monitor.history()
            Task { @MainActor in
                self.source = .local
                self.status = status
                self.history = history
                self.profiles = []
            }
        }
    }

    func loadHistory() {
        tick = 0   // force a history fetch on the next poll
        poll()
    }

    // MARK: - Control (daemon only)

    func setControlMode(_ mode: ControlMode) {
        sendControl(Request(cmd: .setControlMode, controlMode: mode))
    }

    func setFixedRPM(_ rpm: Double, fan: Int? = nil) {
        sendControl(Request(cmd: .setTarget, fan: fan, rpm: rpm))
    }

    func applyProfile(_ name: String) {
        sendControl(Request(cmd: .applyProfile, profileName: name))
    }

    func saveProfile(_ profile: Profile) {
        sendControl(Request(cmd: .saveProfile, profile: profile))
    }

    func deleteProfile(_ id: UUID) {
        sendControl(Request(cmd: .deleteProfile, profileID: id))
    }

    func maxFans() {
        applyProfile("Max")
    }

    private func sendControl(_ request: Request) {
        queue.async { [weak self] in
            _ = try? FanControlClient().send(request)
            Task { @MainActor in self?.poll() }
        }
    }
}

/// Lazily creates the unprivileged monitor and hands it out under a lock.
///
/// `StatusModel` is `@MainActor` but polls on a background queue, so the
/// monitor cannot live as main-actor state — that would be a data race the
/// moment the queue touched it. Keeping it behind an immutable, self-locking
/// reference lets the polling closure use it safely.
private final class LocalMonitorHolder: @unchecked Sendable {
    private var monitor: LocalMonitor?
    private var failed = false
    private let lock = NSLock()

    /// Nil once creation has already failed — we don't retry every second.
    func get() throws -> LocalMonitor? {
        lock.lock()
        defer { lock.unlock() }

        if let monitor { return monitor }
        if failed { return nil }

        do {
            let created = try LocalMonitor()
            monitor = created
            return created
        } catch {
            failed = true
            throw error
        }
    }
}
