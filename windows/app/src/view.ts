// The shapes Rust sends (limita-core `view.rs`); the webview only renders them.

export type Service = "claude" | "codex";
export type Level = "normal" | "warning" | "critical";
export type Tone = "accent" | "accentSoft" | "warning" | "critical";
export type Mode = "hidden" | "pill" | "dashboard";

export interface Meter {
  title: string;
  value: string;
  fill: number;
  tone: Tone;
  caption: string;
}

export interface ServiceView {
  id: Service;
  name: string;
  level: Level | null;
  stale: boolean;
  status: string;
  setupMessage: string | null;
  meters: Meter[];
  details: { label: string; value: string }[];
  updated: string | null;
  error: string | null;
  message: string | null;
}

export interface PanelView {
  services: ServiceView[];
  connect: { id: Service; label: string }[];
  isRefreshing: boolean;
  pill: { id: Service; level: Level | null; stale: boolean; label: string }[];
  longestResetText: string;
  /** The header badge while a connected service is in its peak hours. */
  primeTime: PrimeTimeNotice | null;
}

/** `strong`, when set, starts the first line in bold; `title` follows it. */
export interface PrimeTimeNotice {
  strong: string | null;
  title: string;
  detail: string;
}

/** The activity panel under the dashboard (limita-core `activity.rs`). */
export interface ActivityPanel {
  expanded: boolean;
  grids: ActivityGrid[];
}

export interface ActivityGrid {
  id: Service;
  /** `columns[week][weekday]`, Sunday first; `null` after today. */
  columns: (ActivityDay | null)[][];
  months: { column: number; text: string }[];
  total: string;
}

export interface ActivityDay {
  key: string;
  /** 0 for no activity, 1...4 for the four shades. */
  level: number;
  label: string;
  /** Tokens in thousands, for the chip over a hovered day. */
  chip: string;
}
