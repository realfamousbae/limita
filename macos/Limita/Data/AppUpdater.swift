import AppKit
import CryptoKit
import Foundation
import Observation
import os

/// Finds a newer Limita on GitHub Releases and installs it in place.
///
/// A release is offered only when it carries both `Limita-<version>.dmg` and its
/// `.sig`, an Ed25519 signature made by `scripts/sign-update.sh` with the private key
/// that only the maintainer holds. Installing downloads both, checks the signature
/// against `publicKey`, takes `Limita.app` out of the DMG, and hands over to a small
/// script that swaps it in once Limita has quit and opens the new copy.
///
/// Set `LIMITA_UPDATE_FEED` to a URL with the same JSON as GitHub's latest-release
/// endpoint to test against a local release, and `LIMITA_UPDATE_INSTALL=1` to install
/// what it offers without a click.
@Observable
@MainActor
final class AppUpdater {
    struct Release: Equatable, Sendable {
        let version: String
        let dmg: URL
        let signature: URL
        let page: URL
    }

    enum Phase: Equatable {
        case idle
        case installing
        case failed(String)
    }

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated static let feed = URL(string: "https://api.github.com/repos/realfamousbae/limita/releases/latest")!
    /// The half of the signing key the app checks updates with. The private half is
    /// never in the repository.
    nonisolated static let publicKey = "lH3iQ4KUqcNSzc79iUXNf4fMvdzdordW6zjgHhf2Wq8="
    static let checkInterval: TimeInterval = 6 * 60 * 60

    /// A newer release than the running one, `nil` while there is none.
    private(set) var available: Release?
    private(set) var phase: Phase = .idle

    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let feedURL: URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let log = Logger(subsystem: "com.limita.app", category: "update")

    init(
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        feedURL: URL = ProcessInfo.processInfo.environment["LIMITA_UPDATE_FEED"].flatMap(URL.init(string:)) ?? AppUpdater.feed
    ) {
        self.currentVersion = currentVersion
        self.feedURL = feedURL
    }

    /// Checks now and then every `checkInterval`.
    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 10 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    func check() {
        // `swift test` and other bundles without a version have nothing to compare.
        guard !currentVersion.isEmpty, phase != .installing else { return }
        let feedURL = feedURL
        Task {
            do {
                let release = try await Self.latestRelease(from: feedURL)
                let newer = release.flatMap { Self.isVersion($0.version, newerThan: currentVersion) ? $0 : nil }
                if newer != available {
                    available = newer
                    phase = .idle
                }
                if newer != nil, ProcessInfo.processInfo.environment["LIMITA_UPDATE_INSTALL"] == "1" { install() }
            } catch {
                // Offline or rate-limited: try again at the next check, quietly.
                log.info("Update check failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func install() {
        guard let release = available, phase != .installing else { return }
        // A copy macOS runs from a randomised read-only path, or one in a folder the
        // user cannot write to, cannot be replaced; let them download it instead.
        let app = Bundle.main.bundleURL
        guard Self.canReplace(app) else {
            NSWorkspace.shared.open(release.page)
            return
        }
        phase = .installing
        Task {
            do {
                let staged = try await Self.stage(release, bundleID: Bundle.main.bundleIdentifier ?? "")
                try Self.handOver(newApp: staged, replacing: app)
                NSApp.terminate(nil)
            } catch {
                log.error("Update failed: \(error.localizedDescription, privacy: .public)")
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Feed

    private struct FeedRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    nonisolated static func latestRelease(from feed: URL) async throws -> Release? {
        var request = URLRequest(url: feed, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        // No release yet is not an error.
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw UpdateError(message: "GitHub answered \(status)") }
        return try release(fromFeed: data)
    }

    nonisolated static func release(fromFeed data: Data) throws -> Release? {
        let feed = try JSONDecoder().decode(FeedRelease.self, from: data)
        guard feed.draft != true, feed.prerelease != true else { return nil }
        let version = feed.tag_name.hasPrefix("v") ? String(feed.tag_name.dropFirst()) : feed.tag_name
        let dmgName = "Limita-\(version).dmg"
        // Releases from before auto-update have no signature; they are not offered.
        guard let dmg = feed.assets.first(where: { $0.name == dmgName }),
              let signature = feed.assets.first(where: { $0.name == dmgName + ".sig" })
        else { return nil }
        return Release(version: version, dmg: dmg.browser_download_url, signature: signature.browser_download_url, page: feed.html_url)
    }

    /// Compares dotted versions number by number, so 0.10.0 is newer than 0.9.3.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let parts = { (version: String) in version.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Install

    nonisolated static func canReplace(_ app: URL) -> Bool {
        let path = app.path
        guard !path.contains("/AppTranslocation/"), !path.hasPrefix("/Volumes/") else { return false }
        return FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    nonisolated static func verify(_ data: Data, signature: Data, publicKey: String = AppUpdater.publicKey) -> Bool {
        guard let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { return false }
        return key.isValidSignature(signature, for: data)
    }

    /// Downloads and checks the release, and copies its app out of the DMG into a
    /// fresh temporary folder.
    private nonisolated static func stage(_ release: Release, bundleID: String) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("limita-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            return try await stage(release, bundleID: bundleID, in: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private nonisolated static func stage(_ release: Release, bundleID: String, in folder: URL) async throws -> URL {
        let dmgData = try await download(release.dmg)
        let signatureText = try await download(release.signature)
        guard let signature = Data(base64Encoded: String(decoding: signatureText, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)),
              verify(dmgData, signature: signature)
        else { throw UpdateError(message: "The update's signature does not match") }
        let dmg = folder.appendingPathComponent("Limita.dmg")
        try dmgData.write(to: dmg)

        let mount = folder.appendingPathComponent("mount", isDirectory: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let mounted = mount.appendingPathComponent("Limita.app")
        let info = Bundle(url: mounted)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == bundleID,
              info?["CFBundleShortVersionString"] as? String == release.version
        else { throw UpdateError(message: "The update holds a different app") }

        let staged = folder.appendingPathComponent("Limita.app")
        try run("/usr/bin/ditto", [mounted.path, staged.path])
        try? FileManager.default.removeItem(at: dmg)
        return staged
    }

    private nonisolated static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 120))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { throw UpdateError(message: "Download failed (\(status))") }
        return data
    }

    /// Starts the script that waits for Limita to quit, swaps the app and opens it.
    /// The old copy is kept until the new one is in place, and put back if copying fails.
    private nonisolated static func handOver(newApp: URL, replacing app: URL) throws {
        let script = """
        pid="$1"; new="$2"; app="$3"; folder="$4"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        backup="$app.previous"
        rm -rf "$backup"
        if mv "$app" "$backup"; then
            if ditto "$new" "$app"; then
                xattr -dr com.apple.quarantine "$app" 2>/dev/null
                rm -rf "$backup"
            else
                rm -rf "$app"
                mv "$backup" "$app"
            fi
        fi
        open "$app"
        rm -rf "$folder"
        """
        let arguments = [
            "/bin/sh", "-c", script, "limita-update",
            String(ProcessInfo.processInfo.processIdentifier), newApp.path, app.path,
            newApp.deletingLastPathComponent().path,
        ]
        // A session of its own, so the script outlives Limita when it quits.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", nil, &attributes, &argv, environ)
        guard status == 0 else { throw UpdateError(message: "Could not start the installer (\(status))") }
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UpdateError(message: "\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }
}
