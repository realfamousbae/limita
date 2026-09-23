import SwiftUI
#if canImport(Darwin)
import Darwin
#endif

@main
struct LimitaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        guard CommandLine.arguments.contains("--capture-claude-status") else { return }
        do {
            try ClaudeStatusCapture.capture()
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("Limita: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
