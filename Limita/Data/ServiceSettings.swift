import Foundation

/// Which services Limita tracks, persisted in `UserDefaults`.
///
/// On first launch the set is auto-detected from what is installed; after that the
/// user's connect/disconnect choices are kept as they are.
struct ServiceSettings: @unchecked Sendable {
    static let enabledKey = "enabledServices"

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
