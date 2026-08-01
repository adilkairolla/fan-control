import Foundation
import FanKit

// fand — privileged fan control daemon.
//
// Runs as root because SMC writes require it. Everything else in this project
// runs unprivileged and talks to this over a Unix socket.

var gServer: SocketServer?

/// Restores fans to Apple's controller. Must be safe to call from a signal
/// handler and safe to call more than once.
func emergencyRestore() {
    gDaemon?.shutdown()
    gServer?.stop()
}

func installSignalHandlers() {
    atexit { emergencyRestore() }
    for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
        signal(sig, { received in
            log("signal \(received) — restoring fans and exiting")
            emergencyRestore()
            exit(128 + received)
        })
    }
}

// A broken client socket must not take down the daemon.
signal(SIGPIPE, SIG_IGN)

guard getuid() == 0 else {
    FileHandle.standardError.write("""
        fand must run as root — SMC writes require privileges.
        Install it as a LaunchDaemon with scripts/install.sh, or run:
            sudo fand

        """.data(using: .utf8)!)
    exit(1)
}

do {
    let daemon = try Daemon()
    gDaemon = daemon
    installSignalHandlers()

    let server = SocketServer(path: IPC.socketPath) { request in
        daemon.handle(request)
    }
    try server.start()
    gServer = server
    log("listening on \(IPC.socketPath)")

    try daemon.start()

    // The power-management notifier needs a live run loop on the main thread.
    CFRunLoopRun()

} catch let error as SMC.SMCError {
    log("fatal: \(error.description)")
    exit(1)
} catch {
    log("fatal: \(error.localizedDescription)")
    exit(1)
}
