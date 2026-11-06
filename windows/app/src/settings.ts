// The Settings window: General, Providers, Shortcuts and Updates, as on macOS
// (`SettingsView.swift`). Changes apply at once; Rust owns every value and sends the
// whole state back after each change (`settings_window.rs`).

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { icons } from "./icons";
import type { Service } from "./view";

type Tab = "general" | "providers" | "shortcuts" | "updates";

const TABS: { id: Tab; title: string }[] = [
  { id: "general", title: "General" },
  { id: "providers", title: "Providers" },
  { id: "shortcuts", title: "Shortcuts" },
  { id: "updates", title: "Updates" },
];

interface IntervalPicker {
  label: string;
  hint: string;
  selected: number;
  choices: { seconds: number; label: string }[];
}

interface Provider {
  id: Service;
  name: string;
  enabled: boolean;
  status: string;
  failed: boolean;
  setupMessage: string | null;
  interval: IntervalPicker | null;
}

interface Shortcut {
  id: string;
  title: string;
  text: string;
  off: boolean;
  isDefault: boolean;
  defaultText: string;
  failed: boolean;
}

interface SettingsState {
  general: { hoverPill: boolean; floating: boolean; launchAtLogin: boolean; resetNotifications: boolean; balanceAlerts: boolean };
  providers: Provider[];
  deepseek: { keyHint: string | null; fake: boolean; lowBalance: string | null; currency: string };
  shortcuts: Shortcut[];
  updates: {
    version: string;
    autoCheck: boolean;
    checking: boolean;
    status: string;
    available: string | null;
    installing: boolean;
    error: string | null;
  };
}

const root = document.getElementById("settings")!;
let state: SettingsState | null = null;
/** Rust names the tab to open on (`settings_window.rs`, `open`). */
let tab: Tab = tabFrom((window as { __LIMITA_SETTINGS_TAB__?: string }).__LIMITA_SETTINGS_TAB__ ?? location.hash) ?? "general";

// What the user is in the middle of, kept across re-renders.
let keyDraft = "";
let replacingKey = false;
let checkingKey = false;
let keyError: string | null = null;
/** The low-balance field as typed, until it is applied; `null` shows the stored value. */
let thresholdDraft: string | null = null;
/** The shortcut being recorded, and why the last key press was not taken. */
let recording: string | null = null;
let recordError: string | null = null;

function tabFrom(text: string): Tab | null {
  const id = text.replace(/^#/, "");
  return TABS.some((t) => t.id === id) ? (id as Tab) : null;
}

/** Builds an element; strings become text, so nothing from Rust is parsed as HTML. */
function el(tag: string, className = "", ...children: (Node | string | null | false | undefined)[]): HTMLElement {
  const node = document.createElement(tag);
  if (className) node.className = className;
  for (const child of children) {
    if (child === null || child === false || child === undefined) continue;
    node.append(child);
  }
  return node;
}

function icon(name: keyof typeof icons): HTMLElement {
  const node = el("span", "icon");
  node.innerHTML = icons[name];
  return node;
}

function button(text: string | Node, className: string, onClick: () => void, disabled = false): HTMLButtonElement {
  const node = el("button", className, text) as HTMLButtonElement;
  node.disabled = disabled;
  node.addEventListener("click", onClick);
  return node;
}

/** A switch with its title and what it does. */
function toggle(title: string, detail: string, checked: boolean, change: (on: boolean) => void): HTMLElement {
  const input = document.createElement("input");
  input.type = "checkbox";
  input.className = "switch";
  input.checked = checked;
  input.addEventListener("change", () => change(input.checked));
  return el("label", "row", el("div", "row-text", el("div", "row-title", title), el("div", "row-detail", detail)), input);
}

function row(title: string, detail: string | null, ...controls: (Node | null | false)[]): HTMLElement {
  return el("div", "row", el("div", "row-text", el("div", "row-title", title), detail && el("div", "row-detail", detail)), el("div", "row-controls", ...controls));
}

function section(title: string | null, ...rows: (Node | null | false)[]): HTMLElement {
  return el("section", "group", title && el("h2", "group-title", title), el("div", "group-body", ...rows));
}

function badge(service: Service): HTMLElement {
  const img = document.createElement("img");
  img.className = "logo";
  img.src = `/logos/${service}.png`;
  img.alt = "";
  return el("span", `badge ${service}`, img);
}

// MARK: - General

function general(s: SettingsState): HTMLElement[] {
  const g = s.general;
  return [
    section(
      "Dashboard",
      toggle("Hover pill", "Resting the cursor at the top edge of a screen shows a pill with the limits.", g.hoverPill, (on) =>
        invoke("set_hover_pill", { enabled: on }),
      ),
      toggle("Floating window", "The dashboard stays open where you drag it, above other windows.", g.floating, (on) =>
        invoke("set_floating", { enabled: on }),
      ),
      toggle("Launch at login", "Limita starts with Windows and waits in the tray.", g.launchAtLogin, (on) =>
        invoke("set_launch_at_login", { enabled: on }),
      ),
    ),
    section(
      "Notifications",
      toggle("Limit resets", "A notification when Claude or Codex limits reset early.", g.resetNotifications, (on) =>
        invoke("set_reset_notifications", { enabled: on }),
      ),
      toggle("Low DeepSeek balance", "A notification when the balance drops below your alert, or runs out.", g.balanceAlerts, (on) =>
        invoke("set_balance_alerts", { enabled: on }),
      ),
    ),
  ];
}

// MARK: - Providers

function providers(s: SettingsState): HTMLElement[] {
  return s.providers.map((provider) => {
    const action = provider.enabled
      ? button("Disconnect", "button", () => invoke("disconnect", { service: provider.id }))
      : provider.id === "deepseek"
        ? null
        : button("Connect", "button primary", () => invoke("connect", { service: provider.id }));
    const head = el(
      "div",
      "provider-head",
      badge(provider.id),
      el("div", "row-text", el("div", "provider-name", provider.name), el("div", `row-detail${provider.failed ? " failed" : ""}`, provider.status)),
      action,
    );
    const rows: (HTMLElement | null)[] = [head];
    if (provider.id === "deepseek") {
      rows.push(...deepseekRows(s, provider));
    } else if (provider.setupMessage) {
      rows.push(el("div", "row", el("p", "message", provider.setupMessage), button("OK", "button", () => invoke("dismiss_setup"))));
    }
    if (provider.interval) rows.push(intervalRow(provider.id, provider.interval));
    return section(null, ...rows);
  });
}

function intervalRow(service: Service, picker: IntervalPicker): HTMLElement {
  const select = document.createElement("select");
  select.id = `interval-${service}`;
  for (const choice of picker.choices) {
    const option = document.createElement("option");
    option.value = String(choice.seconds);
    option.textContent = choice.label;
    option.selected = Math.abs(choice.seconds - picker.selected) < 0.5;
    select.append(option);
  }
  select.addEventListener("change", () => invoke("set_live_interval", { service, seconds: Number(select.value) }));
  return row(picker.label, picker.hint, select);
}

/** The API key and the low-balance alert. */
function deepseekRows(s: SettingsState, provider: Provider): HTMLElement[] {
  const rows: HTMLElement[] = [];
  if (provider.enabled && !replacingKey) {
    const stored = s.deepseek.keyHint
      ? el("span", "key-hint", s.deepseek.keyHint)
      : el("span", "row-detail", s.deepseek.fake ? "Not needed for the fake server" : "Stored in the Credential Manager");
    rows.push(row("API key", null, stored, button("Replace…", "button", () => ((replacingKey = true), render()))));
  } else {
    rows.push(keyEntry(provider.enabled));
  }
  if (provider.setupMessage) rows.push(el("p", "message failed", provider.setupMessage));
  if (provider.enabled) {
    const input = document.createElement("input");
    input.id = "low-balance";
    input.className = "amount";
    input.inputMode = "decimal";
    input.placeholder = "Off";
    input.value = thresholdDraft ?? s.deepseek.lowBalance ?? "";
    input.addEventListener("input", () => (thresholdDraft = input.value));
    input.addEventListener("change", () => {
      const amount = input.value;
      thresholdDraft = null;
      invoke("set_low_balance", { amount });
    });
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") input.blur();
    });
    rows.push(
      row(
        "Low balance alert",
        "At or below this the dot turns red and, if notifications are on, you are told once. Empty turns it off.",
        input,
        el("span", "row-detail", s.deepseek.currency),
      ),
    );
  }
  return rows;
}

function keyEntry(connected: boolean): HTMLElement {
  const input = document.createElement("input");
  input.id = "deepseek-key";
  input.type = "password";
  input.className = "key";
  input.placeholder = "sk-…";
  input.autocomplete = "off";
  input.spellcheck = false;
  input.value = keyDraft;
  input.disabled = checkingKey;
  const submit = button(connected ? "Save Key" : "Connect", "button primary", connectKey, checkingKey || keyDraft.trim() === "");
  input.addEventListener("input", () => {
    keyDraft = input.value;
    submit.disabled = checkingKey || keyDraft.trim() === "";
  });
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") connectKey();
  });
  const cancel =
    replacingKey &&
    button("Cancel", "button", () => {
      replacingKey = false;
      keyDraft = "";
      keyError = null;
      render();
    });
  const link = button("Create a key", "link", () => invoke("open_link", { link: "deepseek-keys" }));
  return el(
    "div",
    "key-entry",
    el("div", "key-line", input, checkingKey && el("span", "spinner"), submit, cancel),
    keyError && el("p", "message failed", keyError),
    el("p", "row-detail", "The key is checked with DeepSeek, then kept in the Windows Credential Manager. ", link),
  );
}

async function connectKey() {
  if (checkingKey || keyDraft.trim() === "") return;
  checkingKey = true;
  keyError = null;
  render();
  try {
    await invoke("connect_deepseek", { key: keyDraft });
    keyDraft = "";
    replacingKey = false;
  } catch (error) {
    keyError = String(error);
  }
  checkingKey = false;
  await load();
}

// MARK: - Shortcuts

function shortcuts(s: SettingsState): HTMLElement[] {
  return [
    section(
      null,
      ...s.shortcuts.map((shortcut) => {
        const isRecording = recording === shortcut.id;
        const recorder = button(isRecording ? "Press keys…" : shortcut.text, `button recorder${isRecording ? " recording" : ""}`, () =>
          isRecording ? stopRecording() : startRecording(shortcut.id),
        );
        const off = button(icon("close"), "button icon-button", () => invoke("clear_hotkey", { action: shortcut.id }), shortcut.off);
        off.title = "Turn this shortcut off";
        const reset = button(icon("reset"), "button icon-button", () => invoke("reset_hotkey", { action: shortcut.id }), shortcut.isDefault);
        reset.title = `Back to ${shortcut.defaultText}`;
        const problem = isRecording && recordError ? recordError : shortcut.failed ? "Another app uses this shortcut; pick another one." : null;
        return el(
          "div",
          "row",
          el("div", "row-text", el("div", "row-title", shortcut.title), problem && el("div", "row-detail failed", problem)),
          el("div", "row-controls", recorder, off, reset),
        );
      }),
    ),
    el("p", "footnote", "Shortcuts work from any app. Click one and press the new keys with Ctrl, Alt or Win; Esc cancels."),
  ];
}

const MODIFIER_KEYS = ["Control", "Alt", "AltGraph", "Shift", "Meta", "OS"];

function onRecordKey(event: KeyboardEvent) {
  if (!recording) return;
  event.preventDefault();
  event.stopPropagation();
  if (event.key === "Escape") {
    stopRecording();
    return;
  }
  if (MODIFIER_KEYS.includes(event.key)) return;
  const action = recording;
  invoke("set_hotkey", {
    action,
    keyCode: event.keyCode,
    ctrl: event.ctrlKey,
    alt: event.altKey,
    shift: event.shiftKey,
    win: event.metaKey,
  })
    .then(() => stopRecording())
    .catch((error) => {
      recordError = String(error);
      render();
    });
}

function startRecording(action: string) {
  stopRecording();
  recording = action;
  recordError = null;
  // The current shortcuts must not fire while new keys are pressed.
  invoke("suspend_hotkeys", { suspended: true });
  window.addEventListener("keydown", onRecordKey, true);
  render();
}

function stopRecording() {
  if (!recording) return;
  recording = null;
  recordError = null;
  window.removeEventListener("keydown", onRecordKey, true);
  invoke("suspend_hotkeys", { suspended: false });
  render();
}

// MARK: - Updates

function updates(s: SettingsState): HTMLElement[] {
  const u = s.updates;
  const rows: (HTMLElement | null)[] = [
    row("Version", null, el("span", "row-detail", u.version)),
    toggle(
      "Check for updates automatically",
      "Asks GitHub every 3 hours. Updates are signed and installed only when you click Install.",
      u.autoCheck,
      (on) => invoke("set_auto_update", { enabled: on }),
    ),
    row(
      u.status,
      null,
      u.checking && el("span", "spinner"),
      button("Check Now", "button", () => invoke("check_updates"), u.checking || u.installing),
    ),
  ];
  if (u.available) {
    const notes = button("Release notes", "link", () => invoke("open_link", { link: "release-notes" }));
    rows.push(
      el(
        "div",
        "row",
        el("div", "row-text", el("div", "row-title", `Limita ${u.available} is out`), notes),
        el("div", "row-controls", button(u.installing ? "Installing…" : "Install and Relaunch", "button primary", () => invoke("install_update"), u.installing)),
      ),
    );
  }
  if (u.error) rows.push(el("p", "message failed", `Update failed: ${u.error}`));
  return [section(null, ...rows)];
}

// MARK: - Rendering

function tabBar(): HTMLElement {
  return el(
    "nav",
    "tabs",
    ...TABS.map(({ id, title }) =>
      button(title, id === tab ? "tab selected" : "tab", () => {
        if (id === tab) return;
        stopRecording();
        tab = id;
        history.replaceState(null, "", `#${id}`);
        render();
      }),
    ),
  );
}

function render() {
  if (!state) return;
  // Re-rendering replaces the fields; the one being typed in keeps its focus and caret.
  const focused = document.activeElement as HTMLInputElement | null;
  const focusId = focused?.id;
  const selection = focusId && "selectionStart" in focused! ? [focused!.selectionStart, focused!.selectionEnd] : null;
  const scroll = document.querySelector(".content")?.scrollTop ?? 0;

  const pages: Record<Tab, (s: SettingsState) => HTMLElement[]> = { general, providers, shortcuts, updates };
  const content = el("main", "content", ...pages[tab](state));
  root.replaceChildren(tabBar(), content);
  content.scrollTop = scroll;

  if (focusId) {
    const again = document.getElementById(focusId) as HTMLInputElement | null;
    if (again && !again.disabled) {
      again.focus();
      if (selection && typeof again.setSelectionRange === "function") {
        try {
          again.setSelectionRange(selection[0], selection[1]);
        } catch {
          // Not a text field.
        }
      }
    }
  }
}

let loading = false;
let reloadAfter = false;

/** Reads the whole state from Rust; changes that arrive meanwhile read it once more. */
async function load() {
  if (loading) {
    reloadAfter = true;
    return;
  }
  loading = true;
  try {
    state = await invoke<SettingsState>("settings_state");
  } finally {
    loading = false;
  }
  render();
  if (reloadAfter) {
    reloadAfter = false;
    load();
  }
}

async function start() {
  await document.fonts.load('10px "JetBrains Mono"');
  await load();
  for (const event of ["settings-changed", "view", "update", "hover-pill", "floating"]) {
    await listen(event, () => load());
  }
  await listen<string>("settings-tab", (event) => {
    const next = tabFrom(event.payload);
    if (next && next !== tab) {
      stopRecording();
      tab = next;
      render();
    }
  });
  // A shortcut is recorded only while the window has the keyboard.
  window.addEventListener("blur", () => stopRecording());
}

start();
