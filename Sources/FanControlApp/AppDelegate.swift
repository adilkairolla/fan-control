import AppKit
import SwiftUI
import Combine
import FanKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let model = StatusModel()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var dashboardWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon, no main menu window.
        NSApp.setActivationPolicy(.accessory)

        setUpStatusItem()
        setUpPopover()
        registerHotKey()

        model.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.updateStatusItem(status) }
            .store(in: &cancellables)

        model.$source
            .receive(on: RunLoop.main)
            .sink { [weak self] source in
                if case .unavailable = source { self?.updateStatusItem(nil) }
            }
            .store(in: &cancellables)

        model.start()

        // `open -a FanControl --args --dashboard` goes straight to the window.
        if CommandLine.arguments.contains("--dashboard") {
            openDashboard()
        }
        if CommandLine.arguments.contains("--popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.togglePopover()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self?.logPopoverAlignment()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        HotKeyCenter.shared.unregisterAll()
    }

    // MARK: - Status item

    /// Fixed, not `variableLength`. The title reflows once a second, and a
    /// variable-width item would resize with it — which both jitters every
    /// neighbouring menu bar icon and moves the anchor out from under an
    /// already-positioned popover. Monospaced digits keep the text stable
    /// inside this width.
    private static let statusItemWidth: CGFloat = 88

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: Self.statusItemWidth)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.imagePosition = .imageLeading

        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        item.button?.image = NSImage(systemSymbolName: "fanblades",
                                     accessibilityDescription: "Fan Control")?
            .withSymbolConfiguration(configuration)

        statusItem = item
        updateStatusItem(nil)
    }

    private func updateStatusItem(_ status: SystemStatus?) {
        guard let button = statusItem?.button else { return }

        guard let status else {
            button.attributedTitle = NSAttributedString(
                string: " —",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]
            )
            button.toolTip = "Fan Control — daemon not reachable"
            return
        }

        let temperature = status.cpuTemperature

        // A machine with no fans shows the temperature alone. Printing "0.0k"
        // would be a reading, and there is no reading to give.
        let title = status.fans.isEmpty
            ? String(format: " %.0f°", temperature)
            : String(format: " %.0f°  %.1fk", temperature, status.averageFanRPM / 1000)

        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        ]
        if status.safetyEngaged {
            attributes[.foregroundColor] = NSColor.systemOrange
        } else if status.thermalPressure == .serious || status.thermalPressure == .critical {
            attributes[.foregroundColor] = NSColor.systemRed
        }

        button.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        button.toolTip = """
            CPU \(String(format: "%.1f", temperature))°C · GPU \(String(format: "%.1f", status.gpuTemperature))°C
            Fans \(status.fans.isEmpty ? "none detected — run fanctl doctor"
                   : status.fans.map { "\(Int($0.info.actualRPM))" }.joined(separator: " / ") + " RPM")
            Mode: \(status.controlMode.displayName)\(status.activeProfileName.map { " · \($0)" } ?? "")
            """
    }

    // MARK: - Popover

    private func setUpPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let hosting = NSHostingController(
            rootView: MenuBarView(
                model: model,
                onOpenDashboard: { [weak self] in
                    self?.closePopover()
                    self?.openDashboard()
                },
                onQuit: { NSApp.terminate(nil) }
            )
        )

        // The positioning fix. An NSPopover anchors itself using the content
        // size reported at the moment it is shown. A plain NSHostingController
        // reports an intrinsic size that SwiftUI then revises once it lays out
        // for real, so the popover is placed for one size and drawn at
        // another — it visibly slides off its own arrow.
        //
        // `.preferredContentSize` makes the hosting controller publish
        // SwiftUI's measured size up front and keep it in sync afterwards, and
        // the fixed width in MenuBarView means that measurement is stable.
        hosting.sizingOptions = [.preferredContentSize]

        popover.contentViewController = hosting
        self.popover = popover
    }

    @objc private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        // An .accessory app has no active window, so bring it forward before
        // showing — otherwise the popover can appear behind the frontmost app
        // and lose first-click.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func closePopover() {
        popover?.performClose(nil)
    }

    // MARK: - Dashboard

    private func registerHotKey() {
        let registered = HotKeyCenter.shared.register(.optionCommandF) { [weak self] in
            self?.openDashboard()
        }
        if !registered {
            NSLog("FanControl: could not register ⌥⌘F — another app likely owns it")
        }
    }

    private func openDashboard() {
        if let window = dashboardWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metric.windowWidth, height: Metric.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Fan Control"
        window.titlebarAppearsTransparent = false
        window.contentView = NSHostingView(rootView: DashboardView(model: model))
        window.isReleasedWhenClosed = false
        window.center()

        dashboardWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension AppDelegate {
    /// Numeric check that the popover actually lands under the status item.
    /// Eyeballing a popover is how the misalignment survived in the first place.
    private func diag(_ line: String) {
        // NSLog output is unreliable to retrieve from a GUI-launched app, so
        // write somewhere we can always read.
        let path = "/tmp/fanalign.log"
        let text = line + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(text.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func logPopoverAlignment() {
        guard let button = statusItem?.button,
              let buttonWindow = button.window else { return }
        let buttonScreen = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil))
        diag(String(format: "button   x=%.1f..%.1f  centre=%.1f  shown=%@",
                    buttonScreen.minX, buttonScreen.maxX, buttonScreen.midX,
                    (popover?.isShown ?? false) ? "yes" : "NO"))
        for screen in NSScreen.screens {
            diag(String(format: "screen   %.0fx%.0f at (%.0f, %.0f)",
                        screen.frame.width, screen.frame.height,
                        screen.frame.minX, screen.frame.minY))
        }

        guard let popoverFrame = popover?.contentViewController?.view.window?.frame else {
            diag("popover  <no window>")
            return
        }
        diag(String(format: "popover  x=%.1f..%.1f  centre=%.1f  size=%.0fx%.0f",
                    popoverFrame.minX, popoverFrame.maxX, popoverFrame.midX,
                    popoverFrame.width, popoverFrame.height))
        diag(String(format: "delta    %.1f pt", popoverFrame.midX - buttonScreen.midX))
    }
}
