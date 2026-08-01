import AppKit

// Menu bar agent. The .app bundle sets LSUIElement, but set the activation
// policy at runtime too so running the bare binary during development behaves
// the same way.

// NSApplication.delegate is a weak reference — without this the delegate would
// be deallocated the moment the closure returns.
var retainedDelegate: AppDelegate?

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    retainedDelegate = delegate
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
