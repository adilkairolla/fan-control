import Foundation
import Carbon.HIToolbox

/// Global hotkeys via Carbon's `RegisterEventHotKey`.
///
/// Deliberately not `NSEvent.addGlobalMonitorForEvents` — that route requires
/// Accessibility permission and prompts the user. Carbon hotkeys need no
/// permission at all, which is why this old API is still the right one.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var registered: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private init() {}

    struct Combo {
        var keyCode: UInt32
        var carbonModifiers: UInt32

        /// ⌥⌘F — the default for summoning the dashboard.
        static let optionCommandF = Combo(keyCode: UInt32(kVK_ANSI_F),
                                          carbonModifiers: UInt32(optionKey | cmdKey))
    }

    @discardableResult
    func register(_ combo: Combo, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x464E4354), id: id)  // 'FNCT'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers,
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }

        actions[id] = action
        registered[id] = ref
        return true
    }

    func unregisterAll() {
        for (_, ref) in registered { UnregisterEventHotKey(ref) }
        registered.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
    }
}

private let hotKeyHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr else { return OSStatus(eventNotHandledErr) }

    DispatchQueue.main.async {
        HotKeyCenter.shared.fire(hotKeyID.id)
    }
    return noErr
}
