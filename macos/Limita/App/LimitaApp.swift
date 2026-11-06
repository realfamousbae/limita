import SwiftUI

@main
struct LimitaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Claude Code runs this binary as its status-line command; handle that and exit
        // before any UI is created.
        let arguments = CommandLine.arguments
        guard arguments.contains(ClaudeStatusLineCommand.flag) else { return }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        exit(ClaudeStatusLineCommand.run(arguments: arguments, input: input))
    }

    var body: some Scene {
        // The real Settings window is AppKit's (`SettingsWindowController`); this scene only
        // exists because an App needs one. Its menu item, and ⌘, while Limita is active,
        // open that window instead of a blank one.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.openSettings(tab: nil) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
