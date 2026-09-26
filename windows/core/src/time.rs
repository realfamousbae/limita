//! Timestamps: parsing what the CLIs and APIs send, and relative wording.

use chrono::{DateTime, TimeZone, Utc};

pub type Timestamp = DateTime<Utc>;

/// Parses ISO 8601 / RFC 3339 with or without fractional seconds (of any length) and
/// with `Z` or a numeric offset.
pub fn parse_flexible(value: &str) -> Option<Timestamp> {
    DateTime::parse_from_rfc3339(value.trim())
        .ok()
        .map(|date| date.with_timezone(&Utc))
}

/// Seconds since 1970, rejecting zero, negative and non-finite values.
pub fn from_unix(seconds: f64) -> Option<Timestamp> {
    if !seconds.is_finite() || seconds <= 0.0 {
        return None;
    }
    let whole = seconds.floor();
    let nanos = ((seconds - whole) * 1e9).round().min(999_999_999.0) as u32;
    Utc.timestamp_opt(whole as i64, nanos).single()
}

/// Seconds from `from` to `to`, fractional.
pub fn seconds_between(from: Timestamp, to: Timestamp) -> f64 {
    (to - from).num_milliseconds() as f64 / 1000.0
}

/// "3 hours ago" / "in 3 hours", in the style of Apple's `RelativeDateTimeFormatter`
/// (full units, largest unit that fits, rounded down), measured from `now`.
pub fn relative_text(date: Timestamp, now: Timestamp) -> String {
    let delta = seconds_between(now, date);
    let magnitude = delta.abs();
    const UNITS: [(f64, &str); 7] = [
        (365.0 * 86400.0, "year"),
        (30.0 * 86400.0, "month"),
        (7.0 * 86400.0, "week"),
        (86400.0, "day"),
        (3600.0, "hour"),
        (60.0, "minute"),
        (1.0, "second"),
    ];
    let (size, name) = UNITS
        .iter()
        .copied()
        .find(|(size, _)| magnitude >= *size)
        .unwrap_or((1.0, "second"));
    let count = (magnitude / size).floor() as i64;
    let unit = if count == 1 { name.to_string() } else { format!("{name}s") };
    if delta < 0.0 || count == 0 && delta <= 0.0 {
        format!("{count} {unit} ago")
    } else {
        format!("in {count} {unit}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_fractions_offsets_and_plain() {
        let plain = parse_flexible("2026-09-24T04:59:59Z").unwrap();
        let micro = parse_flexible("2026-09-24T04:59:59.943648+00:00").unwrap();
        assert_eq!(seconds_between(plain, micro).round(), 1.0);
        assert!(parse_flexible("2030-01-07T10:00:00.123Z").is_some());
        assert!(parse_flexible("nope").is_none());
    }

    #[test]
    fn relative_wording() {
        let now = from_unix(1_000_000.0).unwrap();
        let at = |offset: f64| from_unix(1_000_000.0 + offset).unwrap();
        assert_eq!(relative_text(at(-7200.0), now), "2 hours ago");
        assert_eq!(relative_text(at(-3.0 * 3600.0), now), "3 hours ago");
        assert_eq!(relative_text(at(-60.0), now), "1 minute ago");
        assert_eq!(relative_text(at(-86400.0 * 2.0), now), "2 days ago");
        assert_eq!(relative_text(at(3600.0), now), "in 1 hour");
    }
}

/// Serde for `Option<Timestamp>` as ISO 8601 with whole seconds, which is what the macOS
/// app's `JSONDecoder.iso8601` accepts, so both apps read each other's cache.
pub mod iso_seconds_opt {
    use super::{parse_flexible, Timestamp};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(value: &Option<Timestamp>, serializer: S) -> Result<S::Ok, S::Error> {
        match value {
            Some(date) => serializer.serialize_str(&date.format("%Y-%m-%dT%H:%M:%SZ").to_string()),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<Timestamp>, D::Error> {
        let raw = Option::<String>::deserialize(deserializer)?;
        Ok(raw.as_deref().and_then(parse_flexible))
    }
}

/// Serde for a required `Timestamp`, see `iso_seconds_opt`.
pub mod iso_seconds {
    use super::{parse_flexible, Timestamp};
    use serde::{de::Error, Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(value: &Timestamp, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&value.format("%Y-%m-%dT%H:%M:%SZ").to_string())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Timestamp, D::Error> {
        let raw = String::deserialize(deserializer)?;
        parse_flexible(&raw).ok_or_else(|| D::Error::custom(format!("bad date {raw}")))
    }
}
