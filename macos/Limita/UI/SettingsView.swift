import AppKit
import SwiftUI

/// Every setting of the app, in four tabs. Changes apply at once; there is no Save.
struct SettingsView: View {
    let store: LimitsStore
    let hotKeys: HotKeyCenter
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettings(store: store)
                .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbol) }
                .tag(SettingsTab.general)
            ProviderSettings(store: store)
                .tabItem { Label(SettingsTab.providers.title, systemImage: SettingsTab.providers.symbol) }
                .tag(SettingsTab.providers)
            ShortcutSettings(hotKeys: hotKeys)
                .tabItem { Label(SettingsTab.shortcuts.title, systemImage: SettingsTab.shortcuts.symbol) }
                .tag(SettingsTab.shortcuts)
            UpdateSettings(updater: store.updater)
                .tabItem { Label(SettingsTab.updates.title, systemImage: SettingsTab.updates.symbol) }
                .tag(SettingsTab.updates)
        }
        .frame(width: 560, height: 540)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let store: LimitsStore

    var body: some View {
        @Bindable var store = store
        @Bindable var resets = store.resets
        Form {
            Section {
                Toggle(isOn: $store.hoverEnabled) {
                    Text("Hover pill")
                    Text("Resting the cursor at the top edge of a screen shows a pill with the limits.")
                }
                Toggle(isOn: $store.floatingEnabled) {
                    Text("Floating window")
                    Text("The dashboard stays open where you drag it, on every Space.")
                }
                Toggle(isOn: $store.showsMenuBarIcon) {
                    Text("Menu bar icon")
                    Text("Shown again at every launch, so Settings and Quit stay reachable.")
                }
            } header: {
                Text("Dashboard")
            }
            Section {
                Toggle(isOn: $resets.notificationsEnabled) {
                    Text("Limit resets")
                    Text("A notification when Claude or Codex limits reset early.")
                }
                Toggle(isOn: $store.balanceAlertsEnabled) {
                    Text("Low DeepSeek balance")
                    Text("A notification when the balance drops below your alert, or runs out.")
                }
            } header: {
                Text("Notifications")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Providers

private struct ProviderSettings: View {
    let store: LimitsStore

    var body: some View {
        Form {
            ForEach(Service.allCases) { service in
                Section {
                    ProviderHeader(store: store, service: service)
                    if service == .deepseek {
                        DeepSeekSettings(store: store)
                    } else if let message = store.setupMessage, message.service == service {
                        HStack(alignment: .top) {
                            Text(message.text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("OK") { store.setupMessage = nil }
                        }
                    }
                    if store.isEnabled(service) {
                        IntervalPicker(store: store, service: service)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Logo, name, how the service is doing, and Connect or Disconnect.
private struct ProviderHeader: View {
    let store: LimitsStore
    let service: Service

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 12) {
                ServiceBadge(service: service, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.productName)
                        .font(.headline)
                    Text(Self.status(store: store, service: service, now: context.date))
                        .font(.callout)
                        .foregroundStyle(store.isEnabled(service) && store.liveErrors[service] != nil ? .red : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if store.isEnabled(service) {
                    Button("Disconnect") { store.disconnect(service) }
                } else if service != .deepseek {
                    Button("Connect") { store.connect(service) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    static func status(store: LimitsStore, service: Service, now: Date) -> String {
        guard store.isEnabled(service) else {
            return switch service {
            case .claude: "Not connected. Connecting adds Limita to Claude Code's status line."
            case .codex: "Not connected. Limits come from Codex's session logs and its app server."
            case .deepseek: "Not connected. Needs an API key from platform.deepseek.com."
            }
        }
        if let error = store.liveErrors[service] { return error }
        let state = store.state(for: service)
        if let snapshot = state.snapshot {
            return "Connected · updated \(ExpandedView.updatedText(snapshot.capturedAt, now: now))"
        }
        return state.unavailableReason ?? "Connected"
    }
}

private struct IntervalPicker: View {
    let store: LimitsStore
    let service: Service

    var body: some View {
        Picker(selection: Binding(
            get: { store.liveInterval(for: service) },
            set: { store.setLiveInterval($0, for: service) }
        )) {
            ForEach(LimitsStore.liveIntervalChoices, id: \.self) { interval in
                let minutes = Int(interval / 60)
                let label = minutes == 1 ? "Every minute" : "Every \(minutes) minutes"
                Text(interval == LimitsStore.defaultLiveInterval(for: service) ? "\(label) (default)" : label)
                    .tag(interval)
            }
        } label: {
            Text("Ask the \(service.displayName) API")
            Text(service.kind == .balance
                 ? "The balance and its history come from these requests."
                 : "Local data is read every minute either way; a busier poll risks rate limits.")
        }
    }
}

/// The API key and the low-balance alert.
private struct DeepSeekSettings: View {
    let store: LimitsStore

    @State private var key = ""
    @State private var replacing = false
    @State private var checking = false
    @State private var error: String?
    @State private var hint: String?
    @State private var thresholdText = ""

    private var currency: String {
        store.state(for: .deepseek).snapshot?.balance?.currency ?? "CNY"
    }

    var body: some View {
        Group {
            if store.isEnabled(.deepseek) && !replacing {
                LabeledContent("API key") {
                    HStack {
                        if let hint {
                            Text(hint)
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            Text(DeepSeekClient.apiOverride == nil ? "Stored in the Keychain" : "Not needed for the fake server")
                                .foregroundStyle(.secondary)
                        }
                        Button("Replace…") { replacing = true }
                    }
                }
            } else {
                keyEntry
            }
            if let message = store.setupMessage, message.service == .deepseek {
                Text(message.text).font(.callout).foregroundStyle(.red)
            }
            if store.isEnabled(.deepseek) {
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("Low balance alert", text: $thresholdText, prompt: Text("Off"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .onSubmit(applyThreshold)
                        Text(currency).foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Low balance alert")
                    Text("At or below this the dot turns red and, if notifications are on, you are told once. Empty turns it off.")
                }
            }
        }
        .onAppear {
            hint = store.deepseekKeyHint()
            thresholdText = store.lowBalanceThreshold.map { String(format: "%.2f", $0) } ?? ""
        }
        .onDisappear(perform: applyThreshold)
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SecureField("API key", text: $key, prompt: Text("sk-…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(connect)
                    .disabled(checking)
                if checking {
                    ProgressView().controlSize(.small)
                }
                Button(store.isEnabled(.deepseek) ? "Save Key" : "Connect", action: connect)
                    .buttonStyle(.borderedProminent)
                    .disabled(checking || key.trimmingCharacters(in: .whitespaces).isEmpty)
                if replacing {
                    Button("Cancel") {
                        replacing = false
                        key = ""
                        error = nil
                    }
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack(spacing: 4) {
                Text("The key is checked with DeepSeek, then kept in your Keychain.")
                Link("Create a key", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func connect() {
        guard !checking else { return }
        checking = true
        error = nil
        Task {
            let failure = await store.connectDeepSeek(apiKey: key)
            checking = false
            error = failure
            if failure == nil {
                key = ""
                replacing = false
                hint = store.deepseekKeyHint()
            }
        }
    }

    private func applyThreshold() {
        let text = thresholdText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let value = Double(text).flatMap { $0 > 0 ? $0 : nil }
        store.lowBalanceThreshold = value
        thresholdText = value.map { String(format: "%.2f", $0) } ?? ""
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    let hotKeys: HotKeyCenter

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent {
                        HStack(spacing: 6) {
                            ShortcutRecorder(hotKeys: hotKeys, action: action)
                            Button {
                                hotKeys.set(nil, for: action)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Turn this shortcut off")
                            .disabled(hotKeys.binding(for: action) == nil)
                            Button {
                                hotKeys.reset(action)
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Back to \(action.defaultBinding.displayText)")
                            .disabled(hotKeys.binding(for: action) == action.defaultBinding)
                        }
                    } label: {
                        Text(action.title)
                        if hotKeys.failed.contains(action) {
                            Text("Another app uses this shortcut; pick another one.")
                                .foregroundStyle(.red)
                        }
                    }
                }
            } footer: {
                Text("Shortcuts work from any app. Click one and press the new keys with ⌃, ⌥ or ⌘; Esc cancels.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// A button showing a shortcut; clicked, it takes the next key press as the new one.
private struct ShortcutRecorder: View {
    let hotKeys: HotKeyCenter
    let action: HotKeyAction

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press keys…" : hotKeys.binding(for: action)?.displayText ?? "Off")
                .font(.body.monospaced())
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        // The current shortcuts must not fire while new keys are pressed.
        hotKeys.suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
                return nil
            }
            let binding = HotKeyBinding(
                keyCode: UInt32(event.keyCode),
                modifiers: event.modifierFlags,
                character: event.charactersIgnoringModifiers ?? ""
            )
            guard binding.isValid else {
                NSSound.beep()
                return nil
            }
            stop()
            hotKeys.set(binding, for: action)
            return nil
        }
    }

    private func stop() {
        guard recording || monitor != nil else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hotKeys.suspend(false)
    }
}

// MARK: - Updates

private struct UpdateSettings: View {
    let updater: AppUpdater

    var body: some View {
        @Bindable var updater = updater
        Form {
            Section {
                LabeledContent("Version", value: updater.version.isEmpty ? "Development build" : updater.version)
                Toggle(isOn: $updater.autoCheck) {
                    Text("Check for updates automatically")
                    Text("Asks GitHub every \(Int(AppUpdater.checkInterval / 3600)) hours. Updates are signed and installed only when you click Install.")
                }
                LabeledContent {
                    HStack {
                        if updater.isChecking { ProgressView().controlSize(.small) }
                        Button("Check Now") { updater.check() }
                            .disabled(updater.isChecking || updater.version.isEmpty)
                    }
                } label: {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(status(now: context.date))
                    }
                }
                if let release = updater.available {
                    LabeledContent {
                        Button(updater.phase == .installing ? "Installing…" : "Install and Relaunch") { updater.install() }
                            .buttonStyle(.borderedProminent)
                            .disabled(updater.phase == .installing)
                    } label: {
                        Text("Limita \(release.version) is out")
                        Link("Release notes", destination: release.page)
                    }
                }
                if case .failed(let message) = updater.phase {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func status(now: Date) -> String {
        if updater.isChecking { return "Checking…" }
        if let error = updater.lastError { return "Last check failed: \(error)" }
        if updater.available != nil { return "An update is available" }
        if let checked = updater.lastChecked {
            return "Up to date · checked \(ExpandedView.updatedText(checked, now: now))"
        }
        return "Not checked yet"
    }
}
