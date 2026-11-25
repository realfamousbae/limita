// Renders what Rust sends and reports the size it needs; Rust sizes and places the
// window (see `panel.rs`).

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { icons } from "./icons";
import { providerUsesSettings, reportsSpending } from "./view";
import type { SpendingGrid, ActivityDay, ActivityGrid, ActivityPanel, Meter, Mode, PanelView, Period, PrimeTimeNotice, ServiceView } from "./view";

let mode: Mode = "hidden";
let view: PanelView | null = null;
let hoverPill = true;
/** The dashboard floats where the user drags it (see `Panel::set_floating`). */
let floating = false;
/** A newer Limita, when GitHub has one (see `updater.rs`). */
let update: { version: string | null; installing: boolean; error: string | null } = { version: null, installing: false, error: null };
let version = "";
/** The update button is spelled out for `ANNOUNCE_MS` the first time the dashboard shows
 *  a version after launch. */
const ANNOUNCE_MS = 8000;
let announced: { version: string; at: number } | null = null;
let reported = "";
let activity: ActivityPanel = { expanded: false, period: "all", grids: [], spending: [] };
type ChartMode = "activity" | "models" | "money";
let chartMode: ChartMode = "activity";
let scrollLeft = 0;
let shownWeeks = 0;
let requestedWeeks = 0;
let resizeTimer: ReturnType<typeof setTimeout> | undefined;
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
  if (providerUsesSettings(service)) return el("span", "provider-glyph", reportsSpending(service) ? "$" : "◷");
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
  current.pill.slice(0, 5).forEach((item, index) => {
    if (index > 0) node.append(el("span", "pill-divider"));
    node.append(
      el("span", "pill-item", el("span", "pill-icon", logo(item.id)), dot(item.level, item.stale), el("span", "digits", item.label)),
    );
  });
  if (current.pill.length > 5) node.append(el("span", "", `+${current.pill.length - 5}`));
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

  // No shortcut in the tooltips: shortcuts can be changed or turned off in Settings.
  const hover = el("button", `round${hoverPill ? "" : " crossed"}`, icon("cursor"));
  hover.title = hoverPill ? "Turn off the hover pill" : "Turn on the hover pill";
  hover.addEventListener("click", () => invoke("toggle_hover_pill"));

  const pin = el("button", `round${floating ? "" : " crossed"}`, icon("pin"));
  pin.title = floating ? "Unpin the floating window" : "Pin as a floating window";
  pin.addEventListener("click", () => invoke("toggle_floating"));

  const settings = el("button", "round", icon("gear"));
  settings.title = "Settings";
  settings.setAttribute("aria-label", "Settings");
  settings.addEventListener("click", () => invoke("open_settings"));

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
  // Titles left, buttons right; the prime-time badge, when shown, in the middle of the panel.
  // Where the spelled-out update button would reach it, it steps aside (see `hideCoveredBadge`).
  const badge = current.primeTime ? primeTimeBadge(current.primeTime) : el("div");
  const header = el(
    "header",
    "",
    el("div", "header-side", glyph, el("div", "titles", el("div", "name-row", el("span", "app-name", "LIMITA"), version && el("span", "version", `v${version}`)), el("div", "caption", "AI USAGE MONITOR"))),
    badge,
    el("div", "header-side end", install, hover, pin, settings, current.services.length > 0 && refresh),
  );

  const body =
    current.services.length === 0
      ? connectPrompt(current)
      : el("div", "columns", ...current.services.flatMap((service, index) => [
          index > 0 ? el("div", "divider vertical") : null,
          column(service),
        ]));

  const wide = current.services.length > 3 || (current.services.length > 1 && screen.availWidth < 850);
  const dashboard = el("div", wide ? "dashboard wide" : "dashboard", header, el("div", "divider horizontal"));
  const cards = el("div", wide ? "provider-scroll" : "", body);
  dashboard.append(cards);
  if (current.services.length > 0) {
    const supportsSpending = current.services.some(({ id }) => reportsSpending(id));
    if (!supportsSpending) chartMode = "activity";
    if (activity.expanded && activity.grids.length > 0) {
      const charts = chartMode === "activity"
        ? activity.grids.map(activityColumn)
        : activity.spending.map((entry) => spendingColumn(entry, chartMode));
      const graphRow = el("div", "columns", ...charts.flatMap((chart, index) =>
        [index > 0 ? el("div", "divider vertical") : null, chart]));
      dashboard.append(el("div", "divider horizontal"),
        el("div", "activity-header", periodSwitch(), supportsSpending && chartModeSwitch()),
        el("div", wide ? "provider-scroll" : "", graphRow));
    }
    dashboard.append(activityToggle());
  }
  if (wide) {
    dashboard.style.maxWidth = `min(${Math.max(310, screen.availWidth - 24)}px, calc(3 * (2 * var(--meter) + 46px) + 4px))`;
    const scrolls = Array.from(dashboard.querySelectorAll<HTMLElement>(".provider-scroll"));
    for (const scroll of scrolls) {
      scroll.addEventListener("scroll", () => {
        if (scroll.scrollLeft === scrollLeft) return;
        scrollLeft = scroll.scrollLeft;
        for (const other of scrolls) if (other !== scroll) other.scrollLeft = scrollLeft;
      });
    }
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
  shownWeeks = 0;
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
      shownWeeks = 0;
      requestedWeeks = 0;
      activity = await invoke<ActivityPanel>("set_activity_period", { period: id });
      render();
    });
    return button;
  }));
}

function chartModeSwitch(): HTMLElement {
  const modes: ChartMode[] = ["activity", "models", "money"];
  const controls = el("div", "period-switch");
  controls.setAttribute("aria-label", "Graph");
  for (const id of modes) {
    const button = el("button", id === chartMode ? "selected" : "", id.toUpperCase());
    button.setAttribute("aria-pressed", String(id === chartMode));
    button.addEventListener("click", () => {
      if (chartMode === id) return;
      chartMode = id;
      shownWeeks = 0;
      render();
      app.querySelector<HTMLElement>('.period-switch[aria-label="Graph"] .selected')?.focus();
    });
    controls.append(button);
  }
  return controls;
}

function spendingColumn(entry: SpendingGrid, mode: ChartMode): HTMLElement {
  const { grid, history } = entry;
  const node = el("section", `column activity spending ${grid.id}`);
  if (!history || (mode === "models" && !Object.values(history.days).some((models) => Object.keys(models).some(Boolean)))) {
    node.append(el("p", "activity-message", reportsSpending(grid.id)
      ? mode === "models" ? "Model spending unavailable" : "No spending history yet"
      : "Spending is available on API connections"));
    return node;
  }
  const { days } = history;
  const money = new Intl.NumberFormat(undefined, { style: "currency", currency: history.currency, maximumFractionDigits: 6 });
  const total = (day: Record<string, number> = {}) => Object.values(day).reduce((sum, amount) => sum + amount, 0);
  const positive = (day: Record<string, number> = {}) => Math.max(0, total(day));
  const peak = Math.max(0.000001, ...grid.cells.flatMap((row) => row.map((day) => {
    const amounts = day ? days[day.key] : undefined;
    return mode === "models" && grid.layout === "row"
      ? Object.values(amounts ?? {}).reduce((sum, amount) => sum + Math.max(0, amount), 0)
      : positive(amounts);
  })));
  const details = el("div", "caption spend-detail");
  const palette = ["#64adf5", "#f69b5a", "#72d4b4", "#ac8cea", "#e787ae", "#efcf67", "#68cadc"];
  const models = [...new Set(Object.keys(days).sort().flatMap((day) => Object.keys(days[day]).filter(Boolean).sort()))];
  const modelColors = new Map(models.map((model, index) => [model, palette[index % palette.length]]));
  const dayButton = (day: ActivityDay, className: string) => {
    const amounts = days[day.key];
    const values = amounts === undefined ? ["No data"] : [money.format(total(amounts))];
    if (mode === "models" && amounts) {
      for (const [name, cost] of Object.entries(amounts).sort((a, b) => b[1] - a[1])) {
        if (name) values.push(`${name} ${money.format(cost)}`);
      }
    }
    const caption = [day.label, ...values].join(" · ");
    const button = el("button", className);
    button.setAttribute("aria-label", caption);
    const show = () => { details.textContent = caption; };
    const hide = () => { if (document.activeElement !== button) details.textContent = ""; };
    button.addEventListener("pointerenter", show);
    button.addEventListener("pointerleave", hide);
    button.addEventListener("focus", show);
    button.addEventListener("blur", hide);
    return button;
  };
  if (history.estimated) node.append(el("div", "caption", "Estimated from balance changes"));
  if (grid.layout === "row") {
    const graph = el("div", "spend-bars");
    for (const [index, day] of (grid.cells[0] ?? []).entries()) {
      if (!day) continue;
      const amounts = days[day.key];
      const button = dayButton(day, "spend-bar");
      const track = el("span", "spend-stack");
      if (amounts) {
        const groups = mode === "models" ? Object.entries(amounts).filter(([name]) => name).sort(([a], [b]) => a.localeCompare(b)) : [];
        const parts: [string, number][] = groups.length ? groups : [["", positive(amounts)]];
        for (const [name, cost] of parts) {
          if (cost <= 0 && parts.length > 1) continue;
          const segment = el("span", "spend-segment");
          segment.style.height = `${Math.max(1, 96 * Math.max(0, cost) / peak)}px`;
          segment.style.background = modelColors.get(name) ?? palette[0];
          track.append(segment);
        }
      }
      button.append(track);
      const label = index % 3 === 0
        ? new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", timeZone: "UTC" }).format(new Date(day.key))
        : " ";
      graph.append(el("div", "spend-day", button, el("span", "caption", label)));
    }
    node.append(graph);
  } else {
    const labelled = grid.layout === "weeks";
    const graph = el("div", `activity-graph spend-grid ${grid.layout}`);
    graph.style.gridTemplateColumns = `${labelled ? "26px " : ""}repeat(${grid.columnLabels.length}, 19px)`;
    if (labelled) graph.append(el("span"));
    for (const label of grid.columnLabels) graph.append(el("span", "column-label", label ?? ""));
    for (const [row, cells] of grid.cells.entries()) {
      if (labelled) graph.append(el("span", "row-label", grid.rowLabels[row] ?? ""));
      for (const day of cells) {
        if (!day) { graph.append(el("span", "spend-square future")); continue; }
        const cell = dayButton(day, "spend-square");
        const amounts = days[day.key];
        if (amounts) cell.style.background = `rgb(100 173 245 / ${0.18 + 0.82 * Math.sqrt(positive(amounts) / peak)})`;
        graph.append(cell);
      }
    }
    node.append(graph);
  }
  node.append(details);
  return node;
}

/** A small capsule at the bottom right, in line with the columns' right edge, that opens
 * and closes the panel. */
function activityToggle(): HTMLElement {
  const button = el("button", `activity-toggle${activity.expanded ? " open" : ""}`, el("span", "", "ACTIVITY"), icon("chevron"));
  button.setAttribute("aria-label", activity.expanded ? "Hide activity" : "Show activity");
  button.addEventListener("click", async () => {
    const expanded = !activity.expanded;
    if (!expanded) {
      activity = { ...activity, expanded, grids: [], spending: [] };
      render();
    }
    shownWeeks = 0;
    requestedWeeks = 0;
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
  if (grid.message) {
    node.append(el("p", "activity-message", grid.message));
    return node;
  }
  const chip = el("span", "activity-chip");
  const date = el("div", "caption nowrap activity-date");
  const columns = grid.cells[0]?.length ?? 0;
  const labelled = grid.rowLabels.some((label) => label !== null);

  const graph = el("div", `activity-graph ${grid.layout}`);
  graph.style.gridTemplateColumns = `${labelled ? "26px " : ""}repeat(${columns}, ${grid.layout === "weeks" ? "19px" : "minmax(0, 1fr)"})`;

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

/** The spelled-out update button grows left over the header from the ⤓ button; the badge
 *  in the middle hides while the two would touch, whatever the number of columns. Measured
 *  without transforms, so the capsule's grow-in animation does not hide an overlap. */
function hideCoveredBadge() {
  const capsule = app.querySelector<HTMLElement>(".update-announce");
  const slot = app.querySelector<HTMLElement>(".update-slot");
  const badge = app.querySelector<HTMLElement>(".prime-time");
  if (!capsule || !slot || !badge) return;
  // `right: -4px` in styles.css: the capsule's round end sits 4 px right of the button.
  const capsuleLeft = slot.getBoundingClientRect().right + 4 - capsule.offsetWidth;
  if (capsuleLeft < badge.getBoundingClientRect().right + 9) badge.classList.add("covered");
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
  const more = el("button", "caption", "More providers");
  more.addEventListener("click", () => invoke("open_settings", { tab: "providers" }));
  return el(
    "div",
    "connect",
    el("p", "value muted", "Connect a service to see its limits."),
    ...current.connect.slice(0, 3).map((option) => {
      const button = el("button", "connect-button", badge(option.id, "small"), el("span", "", option.label), el("span", "spacer"), icon("plus", "muted"));
      // A key is needed first, and it is entered in Settings.
      button.addEventListener("click", () =>
        option.inSettings ? invoke("open_settings", { tab: "providers" }) : invoke("connect", { service: option.id }),
      );
      return button;
    }),
    more,
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
  if (!service.updated && service.meters.length === 0) {
    node.append(el("p", "value muted", service.message ?? "No data"));
    return node;
  }
  // One row per meter: the limits, then the credits.
  const meters = [...service.meters, ...service.credits];
  if (meters.length) node.append(el("div", "meters", ...meters.map((m) => meter(m, service.stale))));
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
    `meter${stale ? " stale" : ""}${m.tone === "unlimited" ? " unlimited" : ""}`,
    el("div", "caption meter-caption nowrap", m.title),
    el(
      "div",
      "meter-body",
      m.tone === "unlimited" ? icon("infinity", "big") : el("span", "big digits", m.value),
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
  if (mode === "dashboard") {
    hideCoveredBadge();
    restoreActivity();
    for (const row of app.querySelectorAll<HTMLElement>(".provider-scroll")) row.scrollLeft = scrollLeft;
    scheduleActivityWidth();
  }
  // Measured right away: a hidden window gets no animation frames, and it stays hidden
  // until Rust knows the size.
  const box = app.firstElementChild?.getBoundingClientRect();
  if (!box) return;
  const size = `${mode}:${Math.ceil(box.width)}x${Math.ceil(box.height)}`;
  if (!modeChanged && size === reported) return;
  reported = size;
  invoke("panel_resized", { width: box.width, height: box.height });
}

function scheduleActivityWidth() {
  clearTimeout(resizeTimer);
  if (!activity.expanded || activity.period !== "all") {
    shownWeeks = 0;
    requestedWeeks = 0;
    return;
  }
  resizeTimer = setTimeout(async () => {
    const graph = app.querySelector<HTMLElement>(".activity-graph.weeks");
    if (!graph) return;
    const weeks = Math.max(1, Math.min(520, Math.floor((graph.clientWidth - 26) / 22)));
    if (weeks === shownWeeks || weeks === requestedWeeks) return;
    requestedWeeks = weeks;
    try {
      const result = await invoke<ActivityPanel>("activity_for_weeks", { weeks });
      if (requestedWeeks !== weeks || !activity.expanded || activity.period !== "all") return;
      activity = result;
      shownWeeks = weeks;
      requestedWeeks = 0;
      render();
    } catch (error) {
      requestedWeeks = 0;
      console.error("Could not resize activity graph", error);
    }
  }, 100);
}
window.addEventListener("resize", scheduleActivityWidth);

/** Both meters share the width of the longest countdown, so it always fits on one line. */
function sizeMeters(longest: string) {
  const probe = el("span", "caption meter-caption probe", longest);
  document.body.append(probe);
  document.documentElement.style.setProperty("--meter", `${Math.ceil(probe.getBoundingClientRect().width) + 4}px`);
  probe.remove();
}

async function start() {
  await document.fonts.load('10px "JetBrains Mono"');
  const current = await invoke<{ mode: Mode; hoverPill: boolean; floating: boolean; version: string; view: PanelView; update: typeof update }>(
    "current",
  );
  version = current.version;
  update = current.update;
  view = current.view;
  mode = current.mode;
  hoverPill = current.hoverPill;
  floating = current.floating;
  sizeMeters(view.longestResetText);
  render(true);
  loadActivity();

  await listen<PanelView>("view", async (event) => {
    view = event.payload;
    render();
    if (mode === "dashboard" && activity.expanded && chartMode !== "activity") {
      const period = activity.period;
      const weeks = shownWeeks;
      const recent = weeks > 0
        ? await invoke<ActivityPanel>("activity_for_weeks", { weeks })
        : await invoke<ActivityPanel>("activity");
      if (mode === "dashboard" && activity.expanded && activity.period === period) {
        activity = recent;
        render();
      }
    }
  });
  await listen<{ enabled: boolean }>("hover-pill", (event) => {
    hoverPill = event.payload.enabled;
    render();
  });
  await listen<{ enabled: boolean }>("floating", (event) => {
    floating = event.payload.enabled;
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
  // The floating dashboard moves when dragged by anything but a button, as on macOS.
  app.addEventListener("mousedown", (event) => {
    if (!floating || mode !== "dashboard" || event.button !== 0) return;
    if ((event.target as Element).closest("button, a, input")) return;
    invoke("start_drag");
  });
  window.addEventListener("keydown", (event) => {
    if (event.key === "Escape") invoke("hide_panel");
  });
}

start();
