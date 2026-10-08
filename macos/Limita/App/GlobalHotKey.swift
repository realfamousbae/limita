import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Carbon's hot keys need no Accessibility
/// permission, unlike a global key-event monitor. Kept for the life of the app, so it is
/// never unregistered.
@MainActor
final class GlobalHotKey {
    /// ⌃⌥L: shows or hides the dashboard from any app, a terminal included.
    static let dashboard = (keyCode: UInt32(kVK_ANSI_L), carbonModifiers: UInt32(controlKey | optionKey))
    static let dashboardKeyEquivalent = "l"
    static let dashboardModifiers: NSEvent.ModifierFlags = [.control, .option]

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Registers the shortcut; `nil` when the system refuses it (another app holds it).
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            },
            1,
            &type,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4C4D_5441), id: 1) // "LMTA"
        let registered = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }
}
