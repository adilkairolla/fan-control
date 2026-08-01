import AppKit
import FanKit

// Menu bar agent. The .app bundle sets LSUIElement, but set the activation
// policy at runtime too so running the bare binary during development behaves
// the same way.

// NSApplication.delegate is a weak reference — without this the delegate would
// be deallocated the moment the closure returns.
var retainedDelegate: AppDelegate?

// Likewise: releasing the token releases the lock. See SingleInstance.
var instanceLock: SingleInstance.Token?

MainActor.assumeIsolated {
    guard let lock = SingleInstance.claim(at: SingleInstance.appLockPath) else {
        // Silently. This is a menu bar agent with no window to raise, and the
        // copy already running is the one the user can see.
        exit(0)
    }
    instanceLock = lock

    let application = NSApplication.shared
    let delegate = AppDelegate()
    retainedDelegate = delegate
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
