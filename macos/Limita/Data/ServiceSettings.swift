import Foundation

/// Which services Limita tracks, persisted in `UserDefaults`.
///
/// On first launch the set is auto-detected from what is installed; after that the
/// user's connect/disconnect choices are kept as they are.
struct ServiceSettings: @unchecked Sendable {
    static let enabledKey = "enabledServices"
    static let hoverKey = "hoverPillEnabled"
    static let collapsedKey = "collapsedMeters"
    static let floatingKey = "floatingWindowEnabled"
    static let floatingOriginKey = "floatingWindowOrigin"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored set, or the result of `detect` on first launch (which is then stored).
    func load(detect: () -> Set<Service>) -> Set<Service> {
        if let raw = defaults.stringArray(forKey: Self.enabledKey) {
            return Set(raw.compactMap(Service.init(rawValue:)))
        }
        let detected = detect()
        save(detected)
        return detected
    }

    /// Whether the cursor at the screen edge shows the pill. On unless the user turned it off.
    var hoverEnabled: Bool {
        get { defaults.object(forKey: Self.hoverKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.hoverKey) }
    }

    /// Whether the dashboard floats where the user left it instead of hanging from the
    /// menu bar. Off unless the user turned it on.
    var floatingEnabled: Bool {
        get { defaults.bool(forKey: Self.floatingKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.floatingKey) }
    }

    /// Top-left corner of the floating dashboard in global screen coordinates, once moved.
    var floatingOrigin: CGPoint? {
        get {
            guard let pair = defaults.array(forKey: Self.floatingOriginKey) as? [Double], pair.count == 2 else { return nil }
            return CGPoint(x: pair[0], y: pair[1])
        }
        nonmutating set {
            if let point = newValue {
                defaults.set([Double(point.x), Double(point.y)], forKey: Self.floatingOriginKey)
            } else {
                defaults.removeObject(forKey: Self.floatingOriginKey)
            }
        }
    }

    /// Meters folded into a capsule under the others, as `"claude.FABLE"`.
    var collapsedMeters: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.collapsedKey) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: Self.collapsedKey) }
    }

    func save(_ services: Set<Service>) {
        defaults.set(Service.allCases.filter(services.contains).map(\.rawValue), forKey: Self.enabledKey)
    }

    /// A service counts as installed when its CLI or its config folder exists. Nothing
    /// here touches the Keychain, so first launch never shows a permission prompt.
    static func detectInstalled(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        findCLI: (String) -> URL? = CLILocator.find
    ) -> Set<Service> {
        let fileManager = FileManager.default
        var services: Set<Service> = []
        if findCLI("claude") != nil || fileManager.fileExists(atPath: home.appendingPathComponent(".claude").path) {
            services.insert(.claude)
        }
        if findCLI("codex") != nil || fileManager.fileExists(atPath: home.appendingPathComponent(".codex").path) {
            services.insert(.codex)
        }
        return services
    }
}
