//! Platform-independent core of Limita for Windows: reading Claude Code and Codex
//! rate limits and the DeepSeek balance, and turning them into what the tray, pill,
//! dashboard and Settings show. It knows nothing about Tauri, so it is tested on any OS.
//!
//! Ported from the macOS app (`Limita/Data`, `Limita/Models`); the behaviour rules are
//! the same, so a change there usually belongs here too.

pub mod activity;
pub mod balance_ledger;
pub mod claude_cache;
pub mod claude_live;
pub mod codex_live;
pub mod codex_reader;
pub mod deepseek_live;
pub mod hotkeys;
pub mod live;
pub mod locator;
pub mod model;
pub mod paths;
pub mod prime_time;
pub mod resets;
pub mod secrets;
pub mod settings;
pub mod statusline;
pub mod store;
pub mod tail;
pub mod time;
pub mod view;

pub use model::*;
