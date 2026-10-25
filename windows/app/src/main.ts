// Renders what Rust sends and reports the size it needs; Rust sizes and places the
// window (see `panel.rs`).

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { icons } from "./icons";
import type { ActivityDay, ActivityGrid, ActivityPanel, Meter, Mode, PanelView, Period, PrimeTimeNotice, ServiceView } from "./view";

let mode: Mode = "hidden";
let view: PanelView | null = null;
let hoverPill = true;
/** A newer Limita, when GitHub has one (see `updater.rs`). */
let update: { version: string | null; installing: boolean; error: string | null } = { version: null, installing: false, error: null };
let version = "";
/** The update button is spelled out for `ANNOUNCE_MS` the first time the dashboard shows
 *  a version after launch. */
const ANNOUNCE_MS = 8000;
let announced: { version: string; at: number } | null = null;
let reported = "";
let activity: ActivityPanel = { expanded: false, period: "all", grids: [] };
/** The day under the cursor, kept across re-renders. */
let hovered: { service: ServiceView["id"]; day: ActivityDay } | null = null;

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

  // Only while a newer version is out: an arrow down to a line, in the healthy green.
  let install: HTMLElement | null = null;
  let announcing = false;
  if (update.version) {
    const glyph = () => (update.installing ? el("span", "spinner") : icon("update"));
    const button = el("button", "round update", glyph());
    button.title = update.installing
      ? `Installing Limita ${update.version}…`
      : update.error
        ? `Update failed: ${update.error}. Click to try again.`
        : `Install Limita ${update.version}`;
    (button as HTMLButtonElement).disabled = update.installing;
    button.addEventListener("click", () => invoke("install_update"));

    // The first time the dashboard shows this version: a capsule growing to the left
    // over the empty header, the round button at its right end. Either installs.
    const now = Date.now();
    if (!update.installing && announced?.version !== update.version) {
      announced = { version: update.version, at: now };
      setTimeout(() => render(), ANNOUNCE_MS + 50);
    }
    announcing = !update.installing && announced !== null && now - announced.at < ANNOUNCE_MS;
    install = el("span", "update-slot", button);
    if (announcing && announced) {
      const capsule = el(
        "button",
        `update-announce${now - announced.at < 300 ? " enter" : ""}`,
        el("span", "announce-lines", el("span", "", `LIMITA ${update.version} IS OUT`), el("span", "muted", "CLICK TO UPDATE")),
        el("span", "announce-glyph", glyph()),
      );
      capsule.addEventListener("click", () => invoke("install_update"));
      install.append(capsule);
    }
  }

  const glyph = el("span", "app-glyph");
  // Titles left, buttons right; the prime-time badge, when shown, right after the titles
  // over side-by-side columns, and between titles and buttons with equal gaps over one.
  const badge = current.primeTime ? primeTimeBadge(current.primeTime) : el("div");
  if (current.services.length > 1) badge.classList.add("beside-titles");
  // Over one column the spelled-out update button would cover it.
  else if (announcing) badge.classList.add("covered");
  const header = el(
    "header",
    "",
    el("div", "header-side", glyph, el("div", "titles", el("div", "name-row", el("span", "app-name", "LIMITA"), version && el("span", "version", `v${version}`)), el("div", "caption", "AI USAGE MONITOR"))),
    badge,
    el("div", "header-side end", install, hover, current.services.length > 0 && refresh),
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
        el("div", "activity-header", el("div", "caption", "ACTIVITY"), periodSwitch()),
        el("div", "columns", ...activity.grids.flatMap((grid, index) => [
          index > 0 ? el("div", "divider vertical") : null,
          activityColumn(grid),
        ])),
      );
    }
    dashboard.append(activityToggle());
  }
  return dashboard;
}

// MARK: - Activity

const PERIODS: { id: Period; title: string }[] = [
  { id: "week", title: "WEEK" },
  { id: "month", title: "MONTH" },
  { id: "all", title: "ALL" },
];

async function loadActivity() {
  activity = await invoke<ActivityPanel>("activity");
  render();
}

/** WEEK · MONTH · ALL, shared by every service's graph. */
function periodSwitch(): HTMLElement {
  return el("div", "period-switch", ...PERIODS.map(({ id, title }) => {
    const button = el("button", id === activity.period ? "selected" : "", title);
    button.addEventListener("click", async () => {
      if (id === activity.period) return;
      hovered = null;
      activity = await invoke<ActivityPanel>("set_activity_period", { period: id });
      render();
    });
    return button;
  }));
}

/** A small capsule at the bottom right, in line with the columns' right edge, that opens
 * and closes the panel. */
function activityToggle(): HTMLElement {
  const button = el("button", `activity-toggle${activity.expanded ? " open" : ""}`, el("span", "", "ACTIVITY"), icon("chevron"));
  button.setAttribute("aria-label", activity.expanded ? "Hide activity" : "Show activity");
  button.addEventListener("click", async () => {
    const expanded = !activity.expanded;
    if (!expanded) {
      activity = { ...activity, expanded, grids: [] };
      render();
    }
    activity = await invoke<ActivityPanel>("set_activity_expanded", { expanded });
    render();
  });
  return el("div", "activity-toggle-row", button);
}

/** One service: the summary tiles, the graph, and under it the hovered day and the
 * legend. Cells fill the column; nothing scrolls or is cut off. Hovering a day shows its
 * tokens in a chip over it. */
function activityColumn(grid: ActivityGrid): HTMLElement {
  const node = el("section", `column activity ${grid.id}`);
  const chip = el("span", "activity-chip");
  const date = el("div", "caption nowrap activity-date");
  const columns = grid.cells[0]?.length ?? 0;
  const labelled = grid.rowLabels.some((label) => label !== null);

  const graph = el("div", `activity-graph ${grid.layout}`);
  graph.style.gridTemplateColumns = `${labelled ? "26px " : ""}repeat(${columns}, ${grid.layout === "weeks" ? "minmax(0, 19px)" : "minmax(0, 1fr)"})`;

  const show = (day: ActivityDay | null, cell: HTMLElement | null) => {
    graph.querySelector(".cell.hovered")?.classList.remove("hovered");
    hovered = day && { service: grid.id, day };
    date.textContent = day ? day.label : "";
    if (!day || !cell) {
      chip.style.display = "none";
      return;
    }
    cell.classList.add("hovered");
    chip.textContent = day.chip;
    chip.style.display = "block";
    // Centred over the cell, kept inside the column.
    const box = node.getBoundingClientRect();
    const rect = cell.getBoundingClientRect();
    const width = chip.getBoundingClientRect().width;
    const left = Math.min(Math.max(rect.left + rect.width / 2 - box.left - width / 2, 0), box.width - width);
    chip.style.left = `${left}px`;
    chip.style.top = `${rect.top - box.top - 19}px`;
  };

  // Labels over the columns, then one grid row per row of days.
  if (labelled) graph.append(el("span"));
  for (const label of grid.columnLabels) graph.append(el("span", `column-label ${grid.layout}`, label ?? ""));
  grid.cells.forEach((row, index) => {
    if (labelled) graph.append(el("span", "row-label", grid.rowLabels[index] ?? ""));
    for (const day of row) {
      const cell = el("span", day ? `cell l${day.level}` : "cell empty");
      if (day) {
        cell.dataset.key = day.key;
        cell.addEventListener("mouseenter", () => show(day, cell));
        cell.addEventListener("click", () => show(day, cell));
      }
      graph.append(cell);
    }
  });
  graph.addEventListener("mouseleave", () => show(null, null));
  // Puts the chip back over the hovered day once the column is laid out (see `render`).
  node.addEventListener("restore", () => {
    if (hovered?.service !== grid.id) return;
    const cell = graph.querySelector<HTMLElement>(`[data-key="${hovered.day.key}"]`);
    show(cell ? hovered.day : null, cell);
  });

  const summary = el("div", "activity-summary", ...grid.summary.map((tile) =>
    el("div", "tile", el("div", "caption nowrap", tile.label), el("div", "tile-value digits", tile.value))));
  const legend = el("div", "activity-legend", el("span", "", "LESS"), ...[0, 1, 2, 3, 4].map((l) => el("span", `cell l${l}`)), el("span", "", "MORE"));
  node.append(summary, graph, el("div", "activity-footer", date, legend), chip);
  return node;
}

/** Puts each hover chip back over its day. Runs after the dashboard is in the document. */
function restoreActivity() {
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
  // One row per meter: the limits, then the credits.
  node.append(el("div", "meters", ...[...service.meters, ...service.credits].map((m) => meter(m, service.stale))));
  // Tiles two to a row, on the meters' grid.
  if (service.details.length > 0) {
    node.append(
      el("div", "details", ...service.details.map((row) => el("div", "tile", el("div", "caption", row.label), el("div", "tile-value digits", row.value)))),
    );
  }
  if (service.reset) node.append(resetLine(service.id, service.reset));
  if (service.error) node.append(el("div", "error", icon("warning"), el("span", "", service.error)));
  return node;
}

/** The newest limit reset, e.g. "RESET FOR EVERYONE · 5 HOURS AGO", with the tracker's
 *  credit under it. The title opens the announcement, the credit the tracker; Rust
 *  picks both links (`open_reset`). */
function resetLine(service: ServiceView["id"], line: NonNullable<ServiceView["reset"]>): HTMLElement {
  const title = el(line.hasLink ? "button" : "div", "reset-title", icon("reset"), el("span", "caption", line.title));
  if (line.hasLink) title.addEventListener("click", () => invoke("open_reset", { service, site: false }));
  const node = el("div", "reset-line", title);
  if (line.credit) {
    const credit = el("button", "caption faint reset-credit", line.credit);
    credit.addEventListener("click", () => invoke("open_reset", { service, site: true }));
    node.append(credit);
  }
  return node;
}

/** The title on top; under it the value, then the bar (with the dollars right of it, for
 *  credits) over the countdown. */
function meter(m: Meter, stale: boolean): HTMLElement {
  const fill = el("span", `fill ${m.tone}`);
  fill.style.width = `${Math.round(m.fill * 1000) / 10}%`;
  const highlight = m.highlight ? el("span", "fill share highlight") : null;
  if (highlight) highlight.style.width = `${Math.round((m.highlight ?? 0) * 1000) / 10}%`;
  const amount = m.amount ? el("span", "caption meter-caption digits nowrap amount", m.amount) : null;
  return el(
    "div",
    `meter${stale ? " stale" : ""}`,
    el("div", "caption meter-caption nowrap", m.title),
    el(
      "div",
      "meter-body",
      el("span", "big digits", m.value),
      el("div", "meter-track", el("div", "bar-line", el("div", "bar", fill, highlight), amount), el("div", "caption meter-caption nowrap", m.caption)),
    ),
  );
}

// MARK: - Rendering and sizing

function render(modeChanged = false) {
  if (!view || mode === "hidden") {
    app.replaceChildren();
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
  const current = await invoke<{ mode: Mode; hoverPill: boolean; version: string; view: PanelView; update: typeof update }>("current");
  version = current.version;
  update = current.update;
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
  await listen<typeof update>("update", (event) => {
    update = event.payload;
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
