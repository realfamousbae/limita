// The shapes Rust sends (limita-core `view.rs`); the webview only renders them.

export type Service = "claude" | "codex";
export type Level = "normal" | "warning" | "critical";
export type Tone = "accent" | "accentSoft" | "warning" | "critical";
export type Mode = "hidden" | "pill" | "dashboard";

export interface Meter {
  title: string;
  value: string;
  /** Dollars beside the value, e.g. "$163.05 OF $250.00". */
  amount: string | null;
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
  /** Claude's credits as meters, in rows after the limits. */
  credits: Meter[];
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
export type Period = "week" | "month" | "all";

export interface ActivityPanel {
  expanded: boolean;
  period: Period;
  grids: ActivityGrid[];
}

export interface ActivityGrid {
  id: Service;
  /** row: the last 7 days; calendar: 5 weeks from Monday; weeks: a column per week. */
  layout: "row" | "calendar" | "weeks";
  /** `cells[row][column]`; `null` after today. */
  cells: (ActivityDay | null)[][];
  columnLabels: (string | null)[];
  rowLabels: (string | null)[];
  /** Four to a row: the totals, then tokens by kind. */
  summary: { label: string; value: string }[];
}

export interface ActivityDay {
  key: string;
  /** 0 for no activity, 1...4 for the four shades. */
  level: number;
  label: string;
  /** Tokens in thousands, for the chip over a hovered day. */
  chip: string;
}
