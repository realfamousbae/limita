// Limita landing page: the menu-bar clock, the live dashboard replica under the faux menu
// bar, download links from the latest GitHub release, and the language choice.
// The replica is always in English, like the app.

(() => {
  "use strict";

  const REPO = "realfamousbae/limita";
  const lang = document.documentElement.lang || "en";
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");
  const finePointer = matchMedia("(hover: hover) and (pointer: fine)");

  // MARK: - Language

  // A first visit from a Russian-language browser goes to /ru/ once; a choice made with
  // the switcher is remembered and wins from then on.
  const LANG_KEY = "limita-lang";
  const stored = (() => {
    try { return localStorage.getItem(LANG_KEY); } catch { return null; }
  })();
  if (!stored && lang === "en" && location.pathname === "/" && /^ru\b/i.test(navigator.language || "")) {
    location.replace("/ru/" + location.hash);
    return;
  }
  document.querySelectorAll(".mb-lang a").forEach((link) => {
    link.addEventListener("click", () => {
      try { localStorage.setItem(LANG_KEY, link.dataset.lang); } catch { /* private mode */ }
    });
  });

  // MARK: - Helpers

  const svg = (body) => `<svg viewBox="0 0 24 24" aria-hidden="true" fill="currentColor">${body}</svg>`;
  const icons = {
    refresh: svg('<path d="M12 4a8 8 0 1 0 7.75 10h-2.1A6 6 0 1 1 12 6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35A7.96 7.96 0 0 0 12 4z"/>'),
    cursor: svg('<path d="M5 3l14 8-6 1.8L9.8 19z"/>'),
    chevron: svg('<path d="M5.4 8.6L12 15.2l6.6-6.6 1.4 1.4-8 8-8-8z"/>'),
  };

  function el(tag, className = "", ...children) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    for (const child of children) {
      if (child === null || child === false || child === undefined) continue;
      node.append(child);
    }
    return node;
  }

  function icon(name) {
    const node = el("span", "icon");
    node.innerHTML = icons[name];
    return node;
  }

  function logo(service) {
    const img = el("img");
    img.src = `/assets/${service}.png`;
    img.alt = "";
    return img;
  }

  const MINUTE = 60_000;
  const HOUR = 60 * MINUTE;
  const DAY = 24 * HOUR;

  /** "RESETS IN 3 DAYS 18 HOURS 40 MIN", to the minute, as the app counts down. */
  function countdown(ms) {
    const total = Math.max(0, Math.round(ms / MINUTE));
    const days = Math.floor(total / 1440);
    const hours = Math.floor((total % 1440) / 60);
    const minutes = total % 60;
    const parts = [];
    if (days) parts.push(`${days} ${days === 1 ? "DAY" : "DAYS"}`);
    if (hours) parts.push(`${hours} ${hours === 1 ? "HOUR" : "HOURS"}`);
    if (minutes || parts.length === 0) parts.push(`${minutes} MIN`);
    return `RESETS IN ${parts.join(" ")}`;
  }

  // MARK: - Peak hours

  /** Weekday (0 = Sunday) and hour of `date` in a time zone. */
  function zoned(date, timeZone) {
    const parts = new Intl.DateTimeFormat("en-US", { timeZone, weekday: "short", hour: "numeric", hourCycle: "h23" }).formatToParts(date);
    const weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(parts.find((p) => p.type === "weekday").value);
    const hour = Number(parts.find((p) => p.type === "hour").value) % 24;
    return { weekday, hour };
  }

  // Claude: weekdays 5–11 AM Pacific. Codex: weekdays 12:00–18:00 UTC.
  const PEAKS = {
    claude: { timeZone: "America/Los_Angeles", from: 5, to: 11 },
    codex: { timeZone: "UTC", from: 12, to: 18 },
  };

  function inPeak(service, date = new Date()) {
    const peak = PEAKS[service];
    const { weekday, hour } = zoned(date, peak.timeZone);
    return weekday >= 1 && weekday <= 5 && hour >= peak.from && hour < peak.to;
  }

  /** Today's start of the zone's `hour`, as a local "HH:MM". */
  function localTime(timeZone, hour) {
    const now = new Date();
    const asZone = new Date(now.toLocaleString("en-US", { timeZone }));
    const offset = asZone.getTime() - new Date(now.toLocaleString("en-US")).getTime();
    const target = new Date(asZone);
    target.setHours(hour, 0, 0, 0);
    const local = new Date(target.getTime() - offset);
    return local.toLocaleTimeString(lang, { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
  }

  function renderSchedule() {
    const list = document.querySelector(".schedule");
    if (!list) return;
    for (const item of list.querySelectorAll("[data-peak]")) {
      const peak = PEAKS[item.dataset.peak];
      const local = item.querySelector(".local");
      let text = `(${list.dataset.local.replace("{from}", localTime(peak.timeZone, peak.from)).replace("{to}", localTime(peak.timeZone, peak.to))})`;
      if (inPeak(item.dataset.peak)) text += `, ${list.dataset.now}`;
      local.textContent = text;
      local.classList.toggle("now", inPeak(item.dataset.peak));
    }
  }

  // MARK: - The replica's data

  // Offsets from page load, so the countdowns tick from the visitor's own clock.
  const loadedAt = Date.now();
  const services = [
    {
      id: "claude",
      name: "Claude Max X5",
      meters: [
        { title: "5 HOURS USED", value: "15%", fill: 0.15, tone: "accent", resetIn: 3 * HOUR + 20 * MINUTE, period: 5 * HOUR },
        { title: "7 DAYS USED", value: "25%", fill: 0.25, tone: "accentSoft", highlight: 0.12, resetIn: 3 * DAY + 18 * HOUR + 40 * MINUTE, period: 7 * DAY },
        { title: "FABLE 7 DAYS USED", value: "24%", fill: 0.24, tone: "share", amount: "12% OF WEEKLY · MAX 50%", folds: true, resetIn: 3 * DAY + 18 * HOUR + 40 * MINUTE, period: 7 * DAY },
      ],
      details: [],
      pill: "5h 15% used",
      week: [2, 3, 1, 4, 3, 0, 2],
      summary: [["TOTAL TOKENS", "41.6M"], ["FAVORITE MODEL", "Opus 5.5"], ["MESSAGES", "1,284"], ["PEAK HOUR", "15:00"]],
    },
    {
      id: "codex",
      name: "Codex",
      meters: [
        { title: "5 HOURS LEFT", value: "94%", fill: 0.94, tone: "accent", resetIn: 45 * MINUTE, period: 5 * HOUR },
        { title: "7 DAYS LEFT", value: "99%", fill: 0.99, tone: "accentSoft", resetIn: 5 * DAY + 5 * HOUR + 46 * MINUTE, period: 7 * DAY },
      ],
      details: [["LIMIT RESETS", "2"], ["CREDITS", "0 credits · $0.00"]],
      pill: "5h 94% left",
      week: [1, 0, 2, 1, 3, 1, 0],
      summary: [["TOTAL TOKENS", "12.7M"], ["FAVORITE MODEL", "Sol 6"], ["MESSAGES", "312"], ["PEAK HOUR", "11:00"]],
    },
  ];

  let version = document.querySelector("[data-version]")?.textContent.trim() || "";
  let hoverPill = true;
  let activityOpen = false;
  let refreshedAt = loadedAt;
  let refreshing = false;

  function updatedText() {
    const minutes = Math.floor((Date.now() - refreshedAt) / MINUTE);
    return minutes < 1 ? "UPDATED JUST NOW" : `UPDATED ${minutes} MIN AGO`;
  }

  /** Time left in a window; once it passes, the next window starts, as the real one does. */
  function remaining(meter) {
    const elapsed = Date.now() - loadedAt;
    const left = meter.resetIn - elapsed;
    return left > 0 ? left : meter.period - (-left % meter.period);
  }

  // MARK: - Pill

  function pill() {
    const node = el("button", "pill");
    node.type = "button";
    node.setAttribute("aria-label", "Open the dashboard");
    services.forEach((service, index) => {
      if (index > 0) node.append(el("span", "pill-divider"));
      node.append(el("span", "pill-item", logo(service.id), el("span", "dot"), el("span", "digits", service.pill)));
    });
    node.addEventListener("click", () => setState("dashboard"));
    return node;
  }

  // MARK: - Dashboard

  function primeTimeBadge() {
    const peaking = services.filter((s) => inPeak(s.id));
    if (peaking.length === 0) return null;
    const lines = el("div", "prime-lines");
    if (peaking.length === services.length) {
      lines.append(el("div", "", "PEAK HOURS FOR ALL PROVIDERS"));
    } else {
      lines.append(el("div", "", el("strong", "", peaking[0].id.toUpperCase()), " PEAK HOURS"));
    }
    lines.append(el("div", "", "USAGE LIMITS RUN OUT FASTER"));
    return el("div", "prime-time", el("span", "burning-gauge"), lines);
  }

  function meter(m) {
    const fill = el("span", `fill ${m.tone}`);
    fill.style.width = `${m.fill * 100}%`;
    const highlight = m.highlight ? el("span", "fill share highlight") : null;
    if (highlight) highlight.style.width = `${m.highlight * 100}%`;
    // Fable's bar is drawn against its own 50% cap.
    if (m.amount) fill.style.width = `${(m.fill / 0.5) * 100}%`;
    const title = el("div", "caption meter-caption nowrap meter-title", m.title, m.folds ? icon("chevron") : null);
    const reset = el("div", "caption meter-caption nowrap", countdown(remaining(m)));
    reset.dataset.countdown = "";
    reset._meter = m;
    return el(
      "div",
      "meter",
      title,
      el(
        "div",
        "meter-body",
        el("span", "big digits", m.value),
        el(
          "div",
          "meter-track",
          el("div", "bar-line", el("div", "bar", fill, highlight), m.amount ? el("span", "caption meter-caption nowrap", m.amount) : null),
          reset,
        ),
      ),
    );
  }

  function column(service) {
    const status = el("div", "caption faint", updatedText());
    status.dataset.updated = "";
    const node = el(
      "section",
      `column ${service.id}`,
      el(
        "div",
        "column-head",
        el("span", `badge ${service.id}`, logo(service.id)),
        el("div", "service-name", service.name, el("span", "dot")),
        el("span", "spacer"),
        el("div", "head-status", el("div", "caption", "LIVE DATA"), status),
      ),
      el("div", "meters", ...service.meters.map(meter)),
    );
    if (service.details.length) {
      node.append(el("div", "details", ...service.details.map(([label, value]) => el("div", "tile", el("div", "caption", label), el("div", "tile-value digits", value)))));
    }
    return node;
  }

  function activityColumn(service) {
    const days = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"];
    // The last seven days end today, so the labels start the day after today a week ago.
    const today = (new Date().getDay() + 6) % 7;
    const order = Array.from({ length: 7 }, (_, i) => (today + 1 + i) % 7);
    return el(
      "section",
      `column activity ${service.id}`,
      el("div", "activity-summary", ...service.summary.map(([label, value]) => el("div", "tile", el("div", "caption", label), el("div", "tile-value digits", value)))),
      el(
        "div",
        "week",
        ...order.map((d) => el("span", "label", days[d])),
        ...order.map((_, i) => el("span", `cell l${service.week[i]}`)),
      ),
    );
  }

  function button(className, content, label, onClick) {
    const node = el("button", `round ${className}`.trim(), content);
    node.type = "button";
    node.title = label;
    node.setAttribute("aria-label", label);
    node.addEventListener("click", onClick);
    return node;
  }

  function dashboard() {
    const hover = button(hoverPill ? "" : "crossed", icon("cursor"), hoverPill ? "Turn off the hover pill" : "Turn on the hover pill", () => {
      hoverPill = !hoverPill;
      render();
      dashSlot.querySelector(".round")?.focus();
    });
    const refresh = button("", refreshing ? el("span", "spinner") : icon("refresh"), "Refresh", () => {
      if (refreshing) return;
      refreshing = true;
      render();
      setTimeout(() => {
        refreshing = false;
        refreshedAt = Date.now();
        render();
      }, 900);
    });

    const header = el(
      "div",
      "dash-header",
      el(
        "div",
        "header-side",
        el("span", "app-glyph"),
        el("div", "titles", el("div", "name-row", el("span", "app-name", "LIMITA"), version ? el("span", "version", `v${version}`) : null), el("div", "caption", "AI USAGE MONITOR")),
      ),
      primeTimeBadge() || el("div"),
      el("div", "header-side end", hover, refresh),
    );

    const toggle = el("button", "activity-toggle", "ACTIVITY", icon("chevron"));
    toggle.type = "button";
    toggle.setAttribute("aria-expanded", String(activityOpen));
    toggle.addEventListener("click", () => {
      activityOpen = !activityOpen;
      render();
      dashSlot.querySelector(".activity-toggle")?.focus();
    });

    const node = el(
      "div",
      "dashboard",
      header,
      el("div", "divider horizontal"),
      el("div", "columns", ...services.flatMap((s, i) => [i > 0 ? el("div", "divider vertical") : null, column(s)])),
    );
    if (activityOpen) {
      node.append(
        el("div", "divider horizontal"),
        el("div", "activity-header", el("div", "caption", "ACTIVITY"), el("div", "caption faint", "LAST 7 DAYS")),
        el("div", "columns", ...services.flatMap((s, i) => [i > 0 ? el("div", "divider vertical") : null, activityColumn(s)])),
      );
    }
    node.append(el("div", "activity-toggle-row", toggle));
    return node;
  }

  // MARK: - Stage

  const stage = document.getElementById("stage");
  const pillSlot = stage.querySelector(".pill-slot");
  const dashSlot = stage.querySelector(".dash-slot");
  const glyph = document.querySelector(".mb-glyph");
  const hint = stage.querySelector(".stage-hint");
  let dashRoot;

  function render() {
    dashRoot.replaceChildren(dashboard());
  }

  /** "hidden", "pill" or "dashboard", as in the app. */
  function setState(state) {
    stage.dataset.state = state;
    glyph.setAttribute("aria-expanded", String(state === "dashboard"));
    glyph.setAttribute("aria-label", state === "dashboard" ? glyph.dataset.hide : glyph.dataset.show);
    dashRoot.inert = state !== "dashboard";
    pillSlot.inert = state !== "pill";
  }

  function tick() {
    for (const node of dashSlot.querySelectorAll("[data-countdown]")) node.textContent = countdown(remaining(node._meter));
    for (const node of dashSlot.querySelectorAll("[data-updated]")) node.textContent = updatedText();
    const badge = dashSlot.querySelector(".prime-time");
    const peaking = services.some((s) => inPeak(s.id));
    if (Boolean(badge) !== peaking) render();
    renderSchedule();
  }

  function startStage() {
    dashRoot = el("div", "limita");
    dashSlot.replaceChildren(dashRoot);
    pillSlot.append(pill());
    render();
    glyph.hidden = false;
    if (!finePointer.matches) hint.textContent = hint.dataset.touch;

    glyph.addEventListener("click", () => setState(stage.dataset.state === "dashboard" ? "hidden" : "dashboard"));

    // The one orchestrated moment: on a desktop with motion welcome, the screen starts
    // empty, the pill drops in after 1.2 s, and opens into the dashboard 1.4 s later.
    // Otherwise the dashboard is simply there.
    if (finePointer.matches && !reduceMotion.matches) {
      setState("hidden");
      let interrupted = false;
      const stop = () => { interrupted = true; };
      glyph.addEventListener("click", stop, { once: true });
      setTimeout(() => {
        if (interrupted || stage.dataset.state !== "hidden") return;
        setState("pill");
        setTimeout(() => {
          if (!interrupted && stage.dataset.state === "pill" && !pillHovered) setState("dashboard");
        }, 1400);
      }, 1200);
    } else {
      setState("dashboard");
    }

    // The top edge: as in the app, resting the pointer there brings the pill in under it.
    let pillHovered = false;
    let hideTimer = 0;
    const pillNode = pillSlot.firstElementChild;
    pillNode.addEventListener("pointerenter", () => { pillHovered = true; clearTimeout(hideTimer); });
    pillNode.addEventListener("pointerleave", () => {
      pillHovered = false;
      scheduleHide();
    });
    function scheduleHide() {
      clearTimeout(hideTimer);
      hideTimer = setTimeout(() => {
        if (stage.dataset.state === "pill" && !pillHovered) setState("hidden");
      }, 700);
    }
    document.addEventListener("pointermove", (event) => {
      if (event.pointerType !== "mouse" || !hoverPill) return;
      const atTop = event.clientY <= 6 || (window.scrollY < 4 && event.target.closest?.(".menubar"));
      if (!atTop) {
        if (stage.dataset.state === "pill" && !pillHovered) scheduleHide();
        return;
      }
      if (stage.dataset.state === "dashboard") return;
      const half = pillNode.offsetWidth / 2 + 12;
      const x = Math.min(Math.max(event.clientX, half), document.documentElement.clientWidth - half);
      pillSlot.style.left = `${x}px`;
      clearTimeout(hideTimer);
      if (stage.dataset.state !== "pill") setState("pill");
    });

    // Clicking elsewhere or Escape closes the dashboard, as in the app.
    document.addEventListener("pointerdown", (event) => {
      if (stage.dataset.state !== "dashboard" || !finePointer.matches) return;
      if (event.target.closest(".dashboard, .mb-glyph, .pill")) return;
      setState("hidden");
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && stage.dataset.state !== "hidden") {
        const inside = stage.contains(document.activeElement);
        setState("hidden");
        if (inside) glyph.focus();
      }
    });

    setInterval(tick, 15_000);
  }

  // MARK: - Menu-bar clock

  const clock = document.querySelector(".mb-clock");
  function renderClock() {
    const now = new Date();
    const day = now.toLocaleDateString(lang, { weekday: "short" });
    const time = now.toLocaleTimeString(lang, { hour: "2-digit", minute: "2-digit" });
    clock.textContent = `${day} ${time}`;
    clock.dateTime = now.toISOString();
  }

  // MARK: - Heatmaps

  /** Half a year of plausible days, the same on every visit. */
  function renderHeatmaps() {
    for (const map of document.querySelectorAll(".heatmap")) {
      let seed = Number(map.dataset.seed) || 1;
      const random = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
      const weeks = 18;
      const cells = [];
      for (let w = 0; w < weeks; w++) {
        const busy = w / weeks;
        for (let d = 0; d < 7; d++) {
          const r = random() * (0.4 + busy) - (d >= 5 ? 0.35 : 0);
          const level = r < 0.25 ? 0 : r < 0.5 ? 1 : r < 0.75 ? 2 : r < 1 ? 3 : 4;
          cells.push(`<i class="l${level}"></i>`);
        }
      }
      map.innerHTML = cells.join("");
    }
  }

  // MARK: - Downloads

  /** The newest release with a DMG and the newest with a Windows installer; one release
   *  can ship before the other platform's build is attached. */
  async function resolveDownloads() {
    try {
      const response = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=10`, { headers: { Accept: "application/vnd.github+json" } });
      if (!response.ok) return;
      const releases = (await response.json()).filter((r) => !r.draft && !r.prerelease);
      const find = (pattern) => {
        for (const release of releases) {
          const asset = release.assets.find((a) => pattern.test(a.name));
          if (asset) return { url: asset.browser_download_url, version: release.tag_name.replace(/^v/, "") };
        }
        return null;
      };
      const mac = find(/^Limita-[\d.]+\.dmg$/);
      const win = find(/_x64-setup\.exe$/);
      if (mac) document.querySelectorAll('[data-download="mac"]').forEach((a) => { a.href = mac.url; });
      if (win) document.querySelectorAll('[data-download="win"]').forEach((a) => { a.href = win.url; });
      if (mac) {
        version = mac.version;
        document.querySelectorAll("[data-version]").forEach((node) => { node.textContent = version; });
        if (dashRoot) render();
      }
    } catch {
      // The links keep pointing at the latest release page.
    }
  }

  renderClock();
  setInterval(renderClock, 10_000);
  renderHeatmaps();
  renderSchedule();
  startStage();
  resolveDownloads();
})();
