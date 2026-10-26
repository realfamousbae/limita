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

    /// ⌃⌥H: turns the hover pill on or off.
    static let hoverToggle = (keyCode: UInt32(kVK_ANSI_H), carbonModifiers: UInt32(controlKey | optionKey))
    static let hoverToggleKeyEquivalent = "h"

    /// ⌃⌥P: pins the dashboard as a floating window, or unpins it.
    static let floatingToggle = (keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(controlKey | optionKey))
    static let floatingToggleKeyEquivalent = "p"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private let id: UInt32

    /// Registers the shortcut; `nil` when the system refuses it (another app holds it).
    init?(id: UInt32 = 1, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.id = id
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                // Every hot key reaches every handler; take only this one's.
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed
                )
                guard status == noErr, pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            },
            1,
            &type,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard installed == noErr else { return nil }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C4D_5441), id: id) // "LMTA"
        let registered = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }
}
