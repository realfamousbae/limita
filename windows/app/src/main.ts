// Renders what Rust sends and reports the size it needs; Rust sizes and places the
// window (see `panel.rs`).

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { icons } from "./icons";
import type { Meter, Mode, PanelView, ServiceView } from "./view";

let mode: Mode = "hidden";
let view: PanelView | null = null;
let reported = "";

const app = document.getElementById("app")!;

/** Builds an element; strings become text, so nothing from Rust is parsed as HTML. */
function el(tag: string, className = "", ...children: (Node | string | null | false)[]): HTMLElement {
  const node = document.createElement(tag);
  if (className) node.className = className;
  for (const child of children) {
    if (child === null || child === false) continue;
    node.append(child);
  }
  return node;
}

function icon(name: keyof typeof icons, className = ""): HTMLElement {
  const node = el("span", `icon ${className}`);
  node.innerHTML = icons[name];
  return node;
}

function dot(level: string | null, stale: boolean): HTMLElement {
  return el("span", `dot ${level ?? "none"}${stale ? " stale" : ""}`);
}

/** The service's logo; sources in macos/design/. */
function logo(service: ServiceView["id"]): HTMLElement {
  const img = document.createElement("img");
  img.className = "logo";
  img.src = `/logos/${service}.png`;
  img.alt = "";
  return img;
}

function badge(service: ServiceView["id"], size: "large" | "small" = "large"): HTMLElement {
  return el("span", `badge ${service} ${size}`, logo(service));
}

// MARK: - Pill

function pill(current: PanelView): HTMLElement {
  const node = el("button", "pill");
  node.addEventListener("click", () => invoke("expand"));
  if (current.pill.length === 0) {
    node.append(icon("plus", "muted"), el("span", "", "Connect a service"));
    return node;
  }
  current.pill.forEach((item, index) => {
    if (index > 0) node.append(el("span", "pill-divider"));
    node.append(
      el("span", "pill-item", el("span", "pill-icon", logo(item.id)), dot(item.level, item.stale), el("span", "digits", item.label)),
    );
  });
  return node;
}

// MARK: - Dashboard

function dashboard(current: PanelView): HTMLElement {
  const refresh = el("button", "round", current.isRefreshing ? el("span", "spinner") : icon("refresh"));
  refresh.title = "Refresh";
  (refresh as HTMLButtonElement).disabled = current.isRefreshing;
  refresh.addEventListener("click", () => invoke("refresh"));

  const glyph = el("span", "app-glyph");
  // Titles left, buttons right; prime-time badges, when any, between them with equal gaps.
  const header = el(
    "header",
    "",
    el("div", "header-side", glyph, el("div", "titles", el("div", "app-name", "LIMITA"), el("div", "caption", "AI USAGE MONITOR"))),
    el("div", "prime-badges", ...current.primeTime.map(primeTimeBadge)),
    el("div", "header-side end", current.services.length > 0 && refresh),
  );

  const body =
    current.services.length === 0
      ? connectPrompt(current)
      : el("div", "columns", ...current.services.flatMap((service, index) => [
          index > 0 ? el("div", "divider vertical") : null,
          column(service),
        ]));

  return el("div", "dashboard", header, el("div", "divider horizontal"), body);
}

/** One pass through the sprite sheet: 196 frames at 24 fps, as in `.burning-gauge`. */
const GAUGE_LOOP_MS = (196 / 24) * 1000;

/** Says that a service is in its peak hours, when work burns through its limits faster. */
function primeTimeBadge(badge: PanelView["primeTime"][number]): HTMLElement {
  const gauge = el("span", "burning-gauge");
  // Every view update rebuilds the header; resuming mid-loop keeps the animation smooth.
  gauge.style.animationDelay = `-${Math.round(performance.now() % GAUGE_LOOP_MS)}ms`;
  const node = el(
    "div",
    "prime-time",
    gauge,
    el("div", "prime-lines", el("div", "", badge.lines[0]), el("div", "", badge.lines[1])),
  );
  node.setAttribute("aria-label", badge.lines.join(" "));
  return node;
}

function connectPrompt(current: PanelView): HTMLElement {
  return el(
    "div",
    "connect",
    el("p", "value muted", "Connect a service to see its limits."),
    ...current.connect.map((option) => {
      const button = el("button", "connect-button", badge(option.id, "small"), el("span", "", option.label), el("span", "spacer"), icon("plus", "muted"));
      button.addEventListener("click", () => invoke("connect", { service: option.id }));
      return button;
    }),
  );
}

function column(service: ServiceView): HTMLElement {
  // Name on the left, how fresh the data is on the right. The meter titles already
  // say "used" or "left".
  const head = el(
    "div",
    "column-head",
    badge(service.id),
    el("div", "service-name", service.name, dot(service.level, service.stale)),
    el("span", "spacer"),
    el("div", "head-status", el("div", "caption", service.status), service.updated ? el("div", "caption faint", service.updated) : null),
  );

  const node = el("section", `column ${service.id}`, head);
  if (service.setupMessage) {
    const ok = el("button", "ok", "OK");
    ok.addEventListener("click", () => invoke("dismiss_setup"));
    node.append(el("div", "setup", el("p", "value", service.setupMessage), ok));
    return node;
  }
  if (service.meters.length === 0) {
    node.append(el("p", "value muted", service.message ?? "No data"));
    return node;
  }
  node.append(el("div", "meters", ...service.meters.map((m) => meter(m, service.stale))));
  // Tiles two to a row, on the meters' grid.
  if (service.details.length > 0) {
    node.append(
      el("div", "details", ...service.details.map((row) => el("div", "tile", el("div", "caption", row.label), el("div", "tile-value digits", row.value)))),
    );
  }
  if (service.error) node.append(el("div", "error", icon("warning"), el("span", "", service.error)));
  return node;
}

function meter(m: Meter, stale: boolean): HTMLElement {
  const fill = el("span", `fill ${m.tone}`);
  fill.style.width = `${Math.round(m.fill * 1000) / 10}%`;
  return el(
    "div",
    `meter${stale ? " stale" : ""}`,
    el("div", "caption meter-caption", m.title),
    el("div", "big digits", m.value),
    el("div", "bar", fill),
    el("div", "caption meter-caption nowrap", m.caption),
  );
}

// MARK: - Rendering and sizing

function render(modeChanged = false) {
  if (!view || mode === "hidden") {
    app.replaceChildren();
    reported = "";
    return;
  }
  app.replaceChildren(mode === "pill" ? pill(view) : dashboard(view));
  // Measured right away: a hidden window gets no animation frames, and it stays hidden
  // until Rust knows the size.
  const box = app.firstElementChild?.getBoundingClientRect();
  if (!box) return;
  const size = `${mode}:${Math.ceil(box.width)}x${Math.ceil(box.height)}`;
  if (!modeChanged && size === reported) return;
  reported = size;
  invoke("panel_resized", { width: box.width, height: box.height });
}

/** Both meters share the width of the longest countdown, so it always fits on one line. */
function sizeMeters(longest: string) {
  const probe = el("span", "caption meter-caption probe", longest);
  document.body.append(probe);
  document.documentElement.style.setProperty("--meter", `${Math.ceil(probe.getBoundingClientRect().width) + 4}px`);
  probe.remove();
}

async function start() {
  await document.fonts.load('10px "JetBrains Mono"');
  const current = await invoke<{ mode: Mode; view: PanelView }>("current");
  view = current.view;
  mode = current.mode;
  sizeMeters(view.longestResetText);
  render(true);

  await listen<PanelView>("view", (event) => {
    view = event.payload;
    render();
  });
  await listen<{ mode: Mode }>("panel-mode", (event) => {
    mode = event.payload.mode;
    render(true);
  });
  window.addEventListener("keydown", (event) => {
    if (event.key === "Escape") invoke("hide_panel");
  });
}

start();
