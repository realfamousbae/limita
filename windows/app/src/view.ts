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
  subtitle: string | null;
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
}
