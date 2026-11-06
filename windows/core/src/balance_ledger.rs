//! Limita's own record of a prepaid balance over time. Port of `BalanceLedger.swift`.
//!
//! DeepSeek reports only the balance, so what was spent today, the pace and how long the
//! money lasts are worked out from how the balance moved between readings:
//!
//! - A drop is spending, dated by the reading that saw it: a drop that happened while
//!   Limita was not running lands on the first reading after.
//! - A rise is a top-up; the balance right after the last one is the bar's full width.
//! - Granted (bonus) money that expires also lowers the balance; DeepSeek does not say
//!   which is which, so it counts as spending.
//!
//! Readings are kept only when the balance changed, one per hour after a day and for 90
//! days, in `deepseek-balance.json` next to the other files Limita writes. The format is
//! the macOS app's. The history cannot be rebuilt, so it is written atomically.

use std::path::PathBuf;

use chrono::{Datelike, NaiveDate, TimeZone, Utc};
use serde::{Deserialize, Serialize};

use crate::model::Balance;
use crate::paths;
use crate::time::{seconds_between, Timestamp};

const DAY: f64 = 24.0 * 60.0 * 60.0;
pub const KEEP_FOR: f64 = 90.0 * DAY;
/// How much history the pace needs before it is shown.
pub const MINIMUM_HISTORY: f64 = DAY;

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Sample {
    #[serde(with = "crate::time::iso_seconds")]
    pub date: Timestamp,
    pub total: f64,
}

/// What the history says, for `Balance`'s derived fields.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Summary {
    pub spent_today: Option<f64>,
    pub spent_this_month: Option<f64>,
    pub daily_burn: Option<f64>,
    pub full_scale: Option<f64>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Stored {
    /// The currency the samples are in; another one starts the history over.
    currency: Option<String>,
    samples: Vec<Sample>,
    /// A low-balance notification went out and the balance has not recovered since.
    alerted_low: bool,
    /// A "calls are rejected" notification went out and calls work again since.
    alerted_unavailable: bool,
}

#[derive(Debug, Default)]
pub struct BalanceLedger {
    /// `None` keeps the history in memory only, for tests and `limita-cli --dump`.
    file: Option<PathBuf>,
    stored: Stored,
}

pub fn standard_file() -> PathBuf {
    paths::app_data().join("deepseek-balance.json")
}

impl BalanceLedger {
    pub fn open(file: Option<PathBuf>) -> Self {
        let stored = file
            .as_ref()
            .and_then(|file| std::fs::read(file).ok())
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default();
        Self { file, stored }
    }

    pub fn samples(&self) -> &[Sample] {
        &self.stored.samples
    }

    pub fn alerted_low(&self) -> bool {
        self.stored.alerted_low
    }

    pub fn set_alerted_low(&mut self, value: bool) {
        if self.stored.alerted_low != value {
            self.stored.alerted_low = value;
            self.save();
        }
    }

    pub fn alerted_unavailable(&self) -> bool {
        self.stored.alerted_unavailable
    }

    pub fn set_alerted_unavailable(&mut self, value: bool) {
        if self.stored.alerted_unavailable != value {
            self.stored.alerted_unavailable = value;
            self.save();
        }
    }

    /// Adds a reading and returns what the history now says.
    pub fn record<Tz: TimeZone>(&mut self, total: f64, currency: &str, at: Timestamp, tz: &Tz) -> Summary {
        let mut next = self.stored.clone();
        if next.currency.as_deref() != Some(currency) {
            next = Stored { currency: Some(currency.into()), samples: Vec::new(), ..self.stored.clone() };
        }
        // An older reading (a slow request finishing late) must not reorder the history.
        if next.samples.last().is_some_and(|last| at < last.date) {
            return summarize(&next.samples, at, tz);
        }
        if next.samples.last().is_none_or(|last| last.total != total) {
            next.samples.push(Sample { date: at, total });
        }
        next.samples = compacted(&next.samples, at);
        if next != self.stored {
            self.stored = next;
            self.save();
        }
        summarize(&self.stored.samples, at, tz)
    }

    /// Forgets everything, for a disconnected or replaced key.
    pub fn clear(&mut self) {
        self.stored = Stored::default();
        if let Some(file) = &self.file {
            let _ = std::fs::remove_file(file);
        }
    }

    fn save(&self) {
        let Some(file) = &self.file else { return };
        if let Some(parent) = file.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_vec(&self.stored) {
            let _ = crate::claude_cache::write_atomically(file, &json);
        }
    }
}

/// Spending today and this month, the average daily spend over the last week, and the
/// balance right after the last top-up (or the highest seen, without one). Days and
/// months are `tz`'s, the user's local time in the app.
pub fn summarize<Tz: TimeZone>(samples: &[Sample], now: Timestamp, tz: &Tz) -> Summary {
    let Some(first) = samples.first() else { return Summary::default() };
    let today = now.with_timezone(tz).date_naive();
    let start_of_day = local_midnight(tz, today).unwrap_or(now);
    let start_of_month = today.with_day(1).and_then(|first| local_midnight(tz, first)).unwrap_or(start_of_day);
    let week_ago = now - chrono::Duration::days(7);

    let (mut today_spent, mut month_spent, mut week_spent) = (0.0, 0.0, 0.0);
    let mut full_scale = samples.iter().map(|sample| sample.total).reduce(f64::max);
    for pair in samples.windows(2) {
        let (previous, sample) = (pair[0], pair[1]);
        let delta = sample.total - previous.total;
        if delta > 0.0 {
            full_scale = Some(sample.total);
        } else if delta < 0.0 {
            let spent = -delta;
            if sample.date >= start_of_day {
                today_spent += spent;
            }
            if sample.date >= start_of_month {
                month_spent += spent;
            }
            if sample.date >= week_ago {
                week_spent += spent;
            }
        }
    }

    let covered = seconds_between(first.date, now);
    let daily_burn = (covered >= MINIMUM_HISTORY).then(|| {
        let span = seconds_between(first.date.max(week_ago), now);
        week_spent / (span / DAY)
    });
    // Spending is only known for the part of the day and month history covers.
    Summary { spent_today: Some(today_spent), spent_this_month: Some(month_spent), daily_burn, full_scale }
}

/// Midnight of `date` in `tz`; the first moment of the day where a clock change skips it.
fn local_midnight<Tz: TimeZone>(tz: &Tz, date: NaiveDate) -> Option<Timestamp> {
    (0..3)
        .find_map(|hour| tz.from_local_datetime(&date.and_hms_opt(hour, 0, 0)?).earliest())
        .map(|local| local.with_timezone(&Utc))
}

/// Drops samples older than `KEEP_FOR` and keeps one per hour (the hour's last) among
/// those older than a day. The newest sample is always kept.
pub fn compacted(samples: &[Sample], now: Timestamp) -> Vec<Sample> {
    let cutoff = now - chrono::Duration::milliseconds((KEEP_FOR * 1000.0) as i64);
    let day_ago = now - chrono::Duration::days(1);
    let hour = |date: Timestamp| date.timestamp().div_euclid(3600);
    let mut result: Vec<Sample> = Vec::new();
    for &sample in samples.iter().filter(|sample| sample.date >= cutoff) {
        match result.last_mut() {
            Some(last) if last.date < day_ago && sample.date < day_ago && hour(last.date) == hour(sample.date) => *last = sample,
            _ => result.push(sample),
        }
    }
    result
}

impl Balance {
    /// This balance with what the history says and the user's threshold.
    pub fn with_summary(mut self, summary: Summary, low_threshold: Option<f64>) -> Self {
        self.spent_today = summary.spent_today;
        self.spent_this_month = summary.spent_this_month;
        self.daily_burn = summary.daily_burn;
        self.full_scale = summary.full_scale.map(|full| full.max(self.total));
        self.low_threshold = low_threshold;
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time::from_unix;

    /// 2030-01-15 12:00 UTC.
    fn noon() -> Timestamp {
        from_unix(1_894_708_800.0).unwrap()
    }

    fn sample(hours_before_noon: f64, total: f64) -> Sample {
        Sample { date: noon() - chrono::Duration::milliseconds((hours_before_noon * 3_600_000.0) as i64), total }
    }

    #[test]
    fn drops_are_spending_and_rises_are_top_ups() {
        let samples = [
            sample(30.0 * 24.0, 50.0), // Dec 16
            sample(10.0 * 24.0, 40.0), // Jan 5: spent 10 this month
            sample(5.0 * 24.0, 140.0), // Jan 10: topped up
            sample(13.0, 130.0),       // Jan 14, 23:00: spent 10
            sample(2.0, 125.0),        // today: spent 5
            sample(1.0, 123.0),        // today: spent 2
        ];
        let summary = summarize(&samples, noon(), &Utc);
        assert_eq!(summary.spent_today, Some(7.0));
        assert_eq!(summary.spent_this_month, Some(27.0));
        assert_eq!(summary.full_scale, Some(140.0), "the balance right after the last top-up");
        assert!((summary.daily_burn.unwrap() - 17.0 / 7.0).abs() < 0.0001, "spent in the last week over 7 days");
    }

    #[test]
    fn the_pace_needs_a_day_of_history() {
        let young = summarize(&[sample(5.0, 20.0), sample(1.0, 18.0)], noon(), &Utc);
        assert_eq!(young.daily_burn, None);
        assert_eq!(young.spent_today, Some(2.0));
        assert_eq!(young.full_scale, Some(20.0), "without a top-up, the highest balance seen");

        let two_days = summarize(&[sample(48.0, 20.0), sample(1.0, 16.0)], noon(), &Utc);
        assert!((two_days.daily_burn.unwrap() - 2.0).abs() < 0.0001);
        assert_eq!(summarize(&[], noon(), &Utc), Summary::default());
    }

    #[test]
    fn days_follow_the_local_time_zone() {
        // 23:00 UTC on Jan 14 is already Jan 15 in Moscow (UTC+3).
        let moscow = chrono::FixedOffset::east_opt(3 * 3600).unwrap();
        let samples = [sample(14.0, 140.0), sample(13.0, 130.0)];
        assert_eq!(summarize(&samples, noon(), &Utc).spent_today, Some(0.0));
        assert_eq!(summarize(&samples, noon(), &moscow).spent_today, Some(10.0));
    }

    #[test]
    fn records_only_changes_and_starts_over_for_another_currency() {
        let mut ledger = BalanceLedger::open(None);
        let minutes = |m: i64| noon() + chrono::Duration::minutes(m);
        ledger.record(10.0, "CNY", minutes(-2), &Utc);
        ledger.record(10.0, "CNY", minutes(-1), &Utc);
        let summary = ledger.record(9.0, "CNY", noon(), &Utc);
        assert_eq!(ledger.samples().len(), 2, "an unchanged balance is not stored again");
        assert_eq!(summary.spent_today, Some(1.0));
        ledger.record(3.0, "USD", minutes(1), &Utc);
        assert_eq!(ledger.samples().iter().map(|s| s.total).collect::<Vec<_>>(), [3.0]);
        ledger.record(2.0, "USD", noon(), &Utc);
        assert_eq!(ledger.samples().iter().map(|s| s.total).collect::<Vec<_>>(), [3.0], "an older reading is ignored");
    }

    #[test]
    fn persists_in_the_macos_format_and_clears() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("deepseek-balance.json");
        let mut ledger = BalanceLedger::open(Some(file.clone()));
        ledger.record(10.0, "CNY", noon(), &Utc);
        ledger.set_alerted_low(true);
        let json: serde_json::Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(
            json,
            serde_json::json!({"currency": "CNY", "samples": [{"date": "2030-01-15T12:00:00Z", "total": 10.0}],
                "alertedLow": true, "alertedUnavailable": false})
        );
        let reloaded = BalanceLedger::open(Some(file.clone()));
        assert_eq!(reloaded.samples().iter().map(|s| s.total).collect::<Vec<_>>(), [10.0]);
        assert!(reloaded.alerted_low());
        ledger.clear();
        assert!(!file.exists());
        assert!(BalanceLedger::open(Some(file)).samples().is_empty());
    }

    #[test]
    fn reads_a_file_the_macos_app_wrote() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("deepseek-balance.json");
        std::fs::write(&file, r#"{"alertedLow":false,"alertedUnavailable":true,"currency":"USD","samples":[{"date":"2030-01-14T09:00:00Z","total":12.5}]}"#).unwrap();
        let ledger = BalanceLedger::open(Some(file));
        assert_eq!(ledger.samples(), [Sample { date: crate::time::parse_flexible("2030-01-14T09:00:00Z").unwrap(), total: 12.5 }]);
        assert!(ledger.alerted_unavailable());
    }

    #[test]
    fn compacts_old_samples_to_one_per_hour() {
        let old: Vec<Sample> = (0..6)
            .map(|i| Sample { date: noon() - chrono::Duration::hours(48) + chrono::Duration::minutes(i * 10), total: 100.0 - i as f64 })
            .collect();
        let recent = [sample(1.0, 50.0), sample(0.5, 49.0)];
        let ancient = Sample { date: noon() - chrono::Duration::days(100), total: 500.0 };
        let all: Vec<Sample> = std::iter::once(ancient).chain(old).chain(recent).collect();
        let totals: Vec<f64> = compacted(&all, noon()).iter().map(|s| s.total).collect();
        assert_eq!(totals, [95.0, 50.0, 49.0], "the hour's last sample, nothing older than 90 days");
    }
}
