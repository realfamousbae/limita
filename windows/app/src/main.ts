// Renders what Rust sends and reports the size it needs; Rust sizes and places the
// window (see `panel.rs`).

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { icons } from "./icons";
import type { ActivityDay, ActivityGrid, ActivityPanel, Meter, Mode, PanelView, PrimeTimeNotice, ServiceView } from "./view";

let mode: Mode = "hidden";
let view: PanelView | null = null;
let hoverPill = true;
let version = "";
let reported = "";
let activity: ActivityPanel = { expanded: false, grids: [] };
/** The day under the cursor, kept across re-renders. */
let hovered: { service: ServiceView["id"]; day: ActivityDay } | null = null;
/** Where each graph is scrolled; a graph not in here opens on the newest weeks. */
const scrolled = new Map<ServiceView["id"], number>();

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

/** The service's logo; sources in assets/design/, copies via scripts/sync-assets.sh. */
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
  refresh.addEventListener("click", () => {
    invoke("refresh");
    loadActivity();
  });

  const hover = el("button", `round${hoverPill ? "" : " crossed"}`, icon("cursor"));
  hover.title = hoverPill ? "Turn off the hover pill (Ctrl+Alt+H)" : "Turn on the hover pill (Ctrl+Alt+H)";
  hover.addEventListener("click", () => invoke("toggle_hover_pill"));

  const glyph = el("span", "app-glyph");
  // Titles left, buttons right; the prime-time badge, when shown, between them with equal gaps.
  const header = el(
    "header",
    "",
    el("div", "header-side", glyph, el("div", "titles", el("div", "name-row", el("span", "app-name", "LIMITA"), version && el("span", "version", `v${version}`)), el("div", "caption", "AI USAGE MONITOR"))),
    current.primeTime ? primeTimeBadge(current.primeTime) : el("div"),
    el("div", "header-side end", hover, current.services.length > 0 && refresh),
  );

  const body =
    current.services.length === 0
      ? connectPrompt(current)
      : el("div", "columns", ...current.services.flatMap((service, index) => [
          index > 0 ? el("div", "divider vertical") : null,
          column(service),
        ]));

  const dashboard = el("div", "dashboard", header, el("div", "divider horizontal"), body);
  if (current.services.length > 0) {
    // The window grows to fit, so the panel drops down below the columns.
    if (activity.expanded && activity.grids.length > 0) {
      dashboard.append(
        el("div", "divider horizontal"),
        el("div", "columns", ...activity.grids.flatMap((grid, index) => [
          index > 0 ? el("div", "divider vertical") : null,
          activityGraph(grid),
        ])),
      );
    }
    dashboard.append(activityToggle());
  }
  return dashboard;
}

// MARK: - Activity

const CELL_STEP = 13;

async function loadActivity() {
  activity = await invoke<ActivityPanel>("activity");
  render();
}

/** The round button with a chevron under the dashboard that opens and closes the panel. */
function activityToggle(): HTMLElement {
  const button = el("button", `round activity-toggle${activity.expanded ? " open" : ""}`, icon("chevron"));
  button.setAttribute("aria-label", activity.expanded ? "Hide activity" : "Show activity");
  button.addEventListener("click", async () => {
    const expanded = !activity.expanded;
    if (!expanded) {
      activity = { expanded, grids: [] };
      render();
    }
    activity = await invoke<ActivityPanel>("set_activity_expanded", { expanded });
    render();
  });
  return el("div", "activity-toggle-row", button);
}

/** One service's year: weeks left to right, opened on the newest. Hovering a day shows
 * its tokens in a chip over it and its date in the caption. */
function activityGraph(grid: ActivityGrid): HTMLElement {
  const info = el("div", "caption faint nowrap", grid.total);
  const chip = el("span", "activity-chip");
  const months = el("div", "activity-months", ...grid.months.map((month) => {
    const label = el("span", "", month.text);
    label.style.left = `${month.column * CELL_STEP}px`;
    return label;
  }));
  const cells = el("div", "activity-cells");
  const node = el("section", `column activity ${grid.id}`);

  const show = (day: ActivityDay | null, cell: HTMLElement | null) => {
    node.querySelector(".cell.hovered")?.classList.remove("hovered");
    hovered = day && { service: grid.id, day };
    info.textContent = day ? day.label : grid.total;
    info.classList.toggle("faint", !day);
    if (!day || !cell) {
      chip.style.display = "none";
      return;
    }
    cell.classList.add("hovered");
    chip.textContent = day.chip;
    chip.style.display = "block";
    // Centred over the cell, kept inside the graph.
    const box = node.getBoundingClientRect();
    const rect = cell.getBoundingClientRect();
    const width = chip.getBoundingClientRect().width;
    const left = Math.min(Math.max(rect.left + rect.width / 2 - box.left - width / 2, 0), box.width - width);
    chip.style.left = `${left}px`;
    chip.style.top = `${rect.top - box.top - 19}px`;
  };

  for (const week of grid.columns) {
    const column = el("div", "activity-week");
    for (const day of week) {
      const cell = el("span", day ? `cell l${day.level}` : "cell empty");
      if (day) {
        cell.dataset.key = day.key;
        cell.addEventListener("mouseenter", () => show(day, cell));
        cell.addEventListener("click", () => show(day, cell));
      }
      column.append(cell);
    }
    cells.append(column);
  }
  cells.addEventListener("mouseleave", () => show(null, null));

  const scroller = el("div", "activity-scroll", months, cells);
  scroller.dataset.service = grid.id;
  scroller.addEventListener("scroll", () => {
    // Restoring the position after a re-render fires this too; that is no real scroll.
    if (scroller.scrollLeft === scrolled.get(grid.id)) return;
    scrolled.set(grid.id, scroller.scrollLeft);
    if (hovered?.service === grid.id) show(null, null);
  });
  // Restores the hovered day once the graph is laid out (see `render`).
  node.addEventListener("restore", () => {
    if (hovered?.service !== grid.id) return;
    const cell = cells.querySelector<HTMLElement>(`[data-key="${hovered.day.key}"]`);
    show(cell ? hovered.day : null, cell);
  });

  const weekdays = el("div", "activity-weekdays", ...["", "Mon", "", "Wed", "", "Fri", ""].map((d) => el("span", "", d)));
  const legend = el("div", "activity-legend", el("span", "", "LESS"), ...[0, 1, 2, 3, 4].map((l) => el("span", `cell l${l}`)), el("span", "", "MORE"));
  node.append(
    el("div", "activity-head", el("div", "caption", "ACTIVITY"), info),
    el("div", "activity-body", weekdays, scroller),
    legend,
    chip,
  );
  return node;
}

/** Puts each graph back where it was scrolled, or on the newest weeks, and the hover chip
 * back over its day. Runs after the dashboard is in the document. */
function restoreActivity() {
  for (const scroller of Array.from(app.querySelectorAll<HTMLElement>(".activity-scroll"))) {
    const service = scroller.dataset.service as ServiceView["id"];
    scroller.scrollLeft = scrolled.get(service) ?? scroller.scrollWidth;
  }
  for (const node of Array.from(app.querySelectorAll(".column.activity"))) node.dispatchEvent(new Event("restore"));
}

/** One pass through the sprite sheet: 196 frames at 24 fps, as in `.burning-gauge`. */
const GAUGE_LOOP_MS = (196 / 24) * 1000;

/** Says that a service is in its peak hours, when work burns through its limits faster. */
function primeTimeBadge(notice: PrimeTimeNotice): HTMLElement {
  const gauge = el("span", "burning-gauge");
  // Every view update rebuilds the header; resuming mid-loop keeps the animation smooth.
  gauge.style.animationDelay = `-${Math.round(performance.now() % GAUGE_LOOP_MS)}ms`;
  const node = el(
    "div",
    "prime-time",
    gauge,
    el(
      "div",
      "prime-lines",
      el("div", "", notice.strong && el("strong", "", notice.strong), notice.title),
      el("div", "", notice.detail),
    ),
  );
  node.setAttribute("aria-label", `${notice.strong ?? ""}${notice.title} ${notice.detail}`);
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
    // The next opening starts on the newest weeks.
    scrolled.clear();
    hovered = null;
    reported = "";
    return;
  }
  app.replaceChildren(mode === "pill" ? pill(view) : dashboard(view));
  if (mode === "dashboard") restoreActivity();
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
  const current = await invoke<{ mode: Mode; hoverPill: boolean; version: string; view: PanelView }>("current");
  version = current.version;
  view = current.view;
  mode = current.mode;
  hoverPill = current.hoverPill;
  sizeMeters(view.longestResetText);
  render(true);
  loadActivity();

  await listen<PanelView>("view", (event) => {
    view = event.payload;
    render();
  });
  await listen<{ enabled: boolean }>("hover-pill", (event) => {
    hoverPill = event.payload.enabled;
    render();
  });
  await listen<{ mode: Mode }>("panel-mode", (event) => {
    mode = event.payload.mode;
    render(true);
    if (mode === "dashboard") loadActivity();
  });
  window.addEventListener("keydown", (event) => {
    if (event.key === "Escape") invoke("hide_panel");
  });
}

start();
