import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Carbon's hot keys need no Accessibility
/// permission, unlike a global key-event monitor. Released when the object goes away,
/// so a changed shortcut frees the old keys.
@MainActor
final class GlobalHotKey {
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
            handler = nil
            return nil
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// A shortcut as the user set it: a key and at least one of ⌃⌥⇧⌘.
struct HotKeyBinding: Codable, Equatable, Sendable {
    let keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw value, only ⌃⌥⇧⌘.
    let modifiers: UInt
    /// The key's character as typed, "l"; empty for keys named by `keyCode`.
    let character: String

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, character: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.allowed).rawValue
        self.character = character.lowercased()
    }

    static let allowed: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// A shortcut needs ⌃, ⌥ or ⌘: ⇧ alone would take a letter from every text field.
    var isValid: Bool { !modifierFlags.intersection([.control, .option, .command]).isEmpty }

    var carbonModifiers: UInt32 {
        var result = 0
        if modifierFlags.contains(.control) { result |= controlKey }
        if modifierFlags.contains(.option) { result |= optionKey }
        if modifierFlags.contains(.shift) { result |= shiftKey }
        if modifierFlags.contains(.command) { result |= cmdKey }
        return UInt32(result)
    }

    /// For a menu item's hint; `nil` for a key a menu cannot show as a character.
    var keyEquivalent: String? {
        Self.keyNames[keyCode] == nil && !character.isEmpty ? character : nil
    }

    /// "⌃⌥L", "⌘F5".
    var displayText: String {
        var text = ""
        if modifierFlags.contains(.control) { text += "⌃" }
        if modifierFlags.contains(.option) { text += "⌥" }
        if modifierFlags.contains(.shift) { text += "⇧" }
        if modifierFlags.contains(.command) { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? character.uppercased())
    }

    private static let keyNames: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Escape): "⎋", UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘", UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]
}

/// What a global shortcut does.
enum HotKeyAction: String, CaseIterable, Identifiable, Sendable {
    case dashboard
    case hoverPill
    case floatingWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Show or hide the dashboard"
        case .hoverPill: "Turn the hover pill on or off"
        case .floatingWindow: "Pin or unpin the floating window"
        }
    }

    /// ⌃⌥L, ⌃⌥H and ⌃⌥P, as before shortcuts could be changed.
    var defaultBinding: HotKeyBinding {
        let (code, character): (Int, String) = switch self {
        case .dashboard: (kVK_ANSI_L, "l")
        case .hoverPill: (kVK_ANSI_H, "h")
        case .floatingWindow: (kVK_ANSI_P, "p")
        }
        return HotKeyBinding(keyCode: UInt32(code), modifiers: [.control, .option], character: character)
    }

    /// Carbon tells hot keys apart by this id.
    var carbonID: UInt32 {
        switch self {
        case .dashboard: 1
        case .hoverPill: 2
        case .floatingWindow: 3
        }
    }
}

/// The app's global shortcuts: what each is set to, registering them, and saving
/// changes. A shortcut can be turned off; one another app holds is reported, not lost.
@Observable
@MainActor
final class HotKeyCenter {
    static let storageKey = "hotKeys"

    private(set) var bindings: [HotKeyAction: HotKeyBinding] = [:]
    /// Actions whose shortcut macOS refused, usually because another app holds it.
    private(set) var failed: Set<HotKeyAction> = []
    /// Called after any change, e.g. to update the menu's hint.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var registered: [HotKeyAction: GlobalHotKey] = [:]
    @ObservationIgnored private var actions: [HotKeyAction: () -> Void] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var suspended = false

    /// The fake-server suite under `LIMITA_*`, so a test copy never changes the real shortcuts.
    init(defaults: UserDefaults = ServiceSettings.standardDefaults) {
        self.defaults = defaults
        bindings = Self.load(from: defaults)
    }

    /// Registers every shortcut with what it does.
    func start(_ actions: [HotKeyAction: () -> Void]) {
        self.actions = actions
        registerAll()
    }

    func binding(for action: HotKeyAction) -> HotKeyBinding? {
        bindings[action]
    }

    /// Sets a shortcut, `nil` to turn it off. One already used by another action moves here.
    func set(_ binding: HotKeyBinding?, for action: HotKeyAction) {
        if let binding {
            for (other, existing) in bindings where other != action && existing.keyCode == binding.keyCode
                && existing.modifiers == binding.modifiers {
                bindings[other] = nil
            }
        }
        bindings[action] = binding
        save()
        registerAll()
    }

    func reset(_ action: HotKeyAction) {
        set(action.defaultBinding, for: action)
    }

    /// While a shortcut is being recorded, the current ones must not fire.
    func suspend(_ isSuspended: Bool) {
        guard isSuspended != suspended else { return }
        suspended = isSuspended
        registerAll()
    }

    private func registerAll() {
        registered = [:]
        var failed: Set<HotKeyAction> = []
        if !suspended {
            for action in HotKeyAction.allCases {
                guard let binding = bindings[action], let perform = actions[action] else { continue }
                if let hotKey = GlobalHotKey(
                    id: action.carbonID, keyCode: binding.keyCode, modifiers: binding.carbonModifiers, action: perform
                ) {
                    registered[action] = hotKey
                } else {
                    failed.insert(action)
                }
            }
        }
        if !suspended { self.failed = failed }
        onChange?()
    }

    /// Whether `action`'s shortcut is registered and works.
    func isActive(_ action: HotKeyAction) -> Bool {
        registered[action] != nil
    }

    // MARK: - Saving

    /// One entry per changed action: a binding, or `null` for a shortcut turned off.
    /// An action without an entry has its default.
    private struct Stored: Codable {
        var binding: HotKeyBinding?
    }

    static func load(from defaults: UserDefaults) -> [HotKeyAction: HotKeyBinding] {
        let stored = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) } ?? [:]
        var result: [HotKeyAction: HotKeyBinding] = [:]
        for action in HotKeyAction.allCases {
            if let entry = stored[action.rawValue] {
                if let binding = entry.binding, binding.isValid { result[action] = binding }
            } else {
                result[action] = action.defaultBinding
            }
        }
        return result
    }

    private func save() {
        var stored: [String: Stored] = [:]
        for action in HotKeyAction.allCases where bindings[action] != action.defaultBinding {
            stored[action.rawValue] = Stored(binding: bindings[action])
        }
        if stored.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
