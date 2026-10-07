//! Peak hours ("prime time"), when a service's limits run out faster. Port of
//! `PrimeTime.swift`.

use chrono::{Datelike, Duration, NaiveDate, NaiveDateTime, TimeZone, Timelike, Utc, Weekday};

use crate::model::Service;
use crate::time::Timestamp;

/// The time zones peak hours are announced in. chrono carries no time-zone data, so
/// each zone spells out its own rule.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Zone {
    /// America/Los_Angeles: UTC-8, UTC-7 from the second Sunday of March 2:00 to the
    /// first Sunday of November 2:00.
    UsPacific,
    Utc,
}

impl Zone {
    fn offset(self, utc: Timestamp) -> Duration {
        match self {
            Zone::UsPacific => {
                let year = utc.year();
                // 2:00 PST is 10:00 UTC; 2:00 PDT is 9:00 UTC.
                let starts = Utc.from_utc_datetime(&nth_sunday(year, 3, 2).and_hms_opt(10, 0, 0).unwrap());
                let ends = Utc.from_utc_datetime(&nth_sunday(year, 11, 1).and_hms_opt(9, 0, 0).unwrap());
                Duration::hours(if utc >= starts && utc < ends { -7 } else { -8 })
            }
            Zone::Utc => Duration::zero(),
        }
    }

    fn local(self, utc: Timestamp) -> NaiveDateTime {
        utc.naive_utc() + self.offset(utc)
    }

    /// The UTC instant of a local time. Peak hours never start or end inside the hour
    /// the clocks change, so a guess from roughly the right offset is exact.
    fn utc(self, local: NaiveDateTime) -> Timestamp {
        let guess = Utc.from_utc_datetime(&(local + Duration::hours(8)));
        Utc.from_utc_datetime(&(local - self.offset(guess)))
    }
}

fn nth_sunday(year: i32, month: u32, n: u8) -> NaiveDate {
    NaiveDate::from_weekday_of_month_opt(year, month, Weekday::Sun, n).expect("every month has a first and second Sunday")
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PrimeTime {
    pub zone: Zone,
    /// Days in `zone`.
    pub weekdays: &'static [Weekday],
    /// Minutes after midnight in `zone`; `end` is exclusive.
    pub start: u32,
    pub end: u32,
}

const WORKDAYS: &[Weekday] = &[Weekday::Mon, Weekday::Tue, Weekday::Wed, Weekday::Thu, Weekday::Fri];

impl PrimeTime {
    pub fn contains(&self, now: Timestamp) -> bool {
        let local = self.zone.local(now);
        let minutes = local.hour() * 60 + local.minute();
        self.weekdays.contains(&local.weekday()) && minutes >= self.start && minutes < self.end
    }

    /// The next start or end time of day after `now`, so the badge appears and goes
    /// away on time. Days outside `weekdays` also count; that only costs a redraw.
    pub fn next_change(&self, now: Timestamp) -> Timestamp {
        let today = self.zone.local(now).date();
        (0..=2)
            .flat_map(|days| [self.start, self.end].map(move |minutes| (days, minutes)))
            .map(|(days, minutes)| {
                let local = (today + Duration::days(days)).and_hms_opt(minutes / 60, minutes % 60, 0).unwrap();
                self.zone.utc(local)
            })
            .filter(|&change| change > now)
            .min()
            .expect("a start or end within two days")
    }
}

impl Service {
    /// When the service's limits run out faster; `None` when it has no peak hours.
    pub fn prime_time(self) -> Option<PrimeTime> {
        match self {
            // Anthropic, March 2026: 5-hour sessions run out faster on weekdays 5–11 AM PT.
            Service::Claude => Some(PrimeTime { zone: Zone::UsPacific, weekdays: WORKDAYS, start: 5 * 60, end: 11 * 60 }),
            // Chosen by the user: weekdays 12:00–18:00 UTC.
            Service::Codex => Some(PrimeTime { zone: Zone::Utc, weekdays: WORKDAYS, start: 12 * 60, end: 18 * 60 }),
        }
    }

    /// The prime-time badge's two lines.
    pub fn prime_time_lines(self) -> [String; 2] {
        [
            format!("{} PRIME TIME. WORK", self.display_name().to_uppercase()),
            "CAN BURN MORE TOKENS AND LIMITS".to_string(),
        ]
    }
}

/// Every service's next start or end of peak hours.
pub fn next_changes(now: Timestamp) -> Vec<Timestamp> {
    Service::ALL.into_iter().filter_map(|s| s.prime_time()).map(|p| p.next_change(now)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time::parse_flexible;

    fn at(text: &str) -> Timestamp {
        parse_flexible(text).unwrap()
    }

    #[test]
    fn claude_prime_time_is_weekday_mornings_pacific() {
        let window = Service::Claude.prime_time().unwrap();
        // October: PDT, UTC-7.
        assert!(!window.contains(at("2026-10-07T04:59:00-07:00")));
        assert!(window.contains(at("2026-10-07T05:00:00-07:00")), "Wednesday");
        assert!(window.contains(at("2026-10-07T10:59:00-07:00")));
        assert!(!window.contains(at("2026-10-07T11:00:00-07:00")));
        assert!(!window.contains(at("2026-10-10T06:00:00-07:00")), "Saturday");
        assert!(!window.contains(at("2026-10-11T06:00:00-07:00")), "Sunday");
        assert!(window.contains(at("2026-10-12T06:00:00-07:00")), "Monday");
    }

    #[test]
    fn follows_daylight_saving() {
        let window = Service::Claude.prime_time().unwrap();
        // PDT: 5 AM is 12:00 UTC. PST after 1 November 2026: 13:00 UTC.
        assert!(window.contains(at("2026-10-30T12:30:00Z")));
        assert!(!window.contains(at("2026-11-02T12:30:00Z")));
        assert!(window.contains(at("2026-11-02T13:30:00Z")));
        // DST begins 8 March 2026.
        assert!(!window.contains(at("2026-03-06T12:30:00Z")));
        assert!(window.contains(at("2026-03-09T12:30:00Z")));
    }

    #[test]
    fn next_change_is_the_next_start_or_end() {
        let window = Service::Claude.prime_time().unwrap();
        assert_eq!(window.next_change(at("2026-10-07T04:00:00-07:00")), at("2026-10-07T05:00:00-07:00"));
        assert_eq!(window.next_change(at("2026-10-07T05:00:00-07:00")), at("2026-10-07T11:00:00-07:00"));
        assert_eq!(window.next_change(at("2026-10-07T12:00:00-07:00")), at("2026-10-08T05:00:00-07:00"));
        // Across the switch back to PST on 1 November.
        assert_eq!(window.next_change(at("2026-10-31T12:00:00-07:00")), at("2026-11-01T05:00:00-08:00"));
    }

    #[test]
    fn codex_prime_time_is_weekdays_utc() {
        let window = Service::Codex.prime_time().unwrap();
        assert!(!window.contains(at("2026-10-07T11:59:00Z")));
        assert!(window.contains(at("2026-10-07T12:00:00Z")), "Wednesday");
        assert!(window.contains(at("2026-10-07T17:59:00Z")));
        assert!(!window.contains(at("2026-10-07T18:00:00Z")));
        assert!(!window.contains(at("2026-10-10T13:00:00Z")), "Saturday");
        assert_eq!(window.next_change(at("2026-10-07T13:00:00Z")), at("2026-10-07T18:00:00Z"));
    }
}
