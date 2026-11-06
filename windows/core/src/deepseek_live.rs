//! The DeepSeek balance with the user's API key. Port of `DeepSeekClient.swift`.
//!
//! `GET https://api.deepseek.com/user/balance` is DeepSeek's documented endpoint and the
//! only one an API key can read: it reports the balance per currency and whether it still
//! covers API calls. There are no rate-limit windows; spending and the forecast come from
//! Limita's own history of these readings (`balance_ledger`).
//!
//! The key is read from the Windows Credential Manager (`secrets`) and is only ever sent
//! to api.deepseek.com. Set `LIMITA_DEEPSEEK_API` to another origin (see
//! `scripts/fake-api.py`) to test against fake responses; the key is then a dummy.

use std::time::Duration;

use serde_json::Value;

use crate::live::{agent, rate_limited};
use crate::model::{AccountDetails, Balance, BalanceAmount, LimitSnapshot, LiveReading};
use crate::time::Timestamp;

const API: &str = "https://api.deepseek.com";
const TIMEOUT: Duration = Duration::from_secs(20);

/// Where a key is made; Settings links there.
pub const KEYS_PAGE: &str = "https://platform.deepseek.com/api_keys";

/// No key is stored: the service is connected but has nothing to ask with.
pub const MISSING_KEY: &str = "Add your DeepSeek API key in Settings";

const RATE_LIMITED: &str = "DeepSeek is rate-limiting balance requests";

/// `LIMITA_DEEPSEEK_API`, when set: the fake server's origin, e.g. `http://127.0.0.1:8377/ds-low`.
pub fn api_override() -> Option<String> {
    std::env::var("LIMITA_DEEPSEEK_API").ok().filter(|url| !url.is_empty())
}

#[derive(Clone, Debug, Default)]
pub struct DeepSeekClient;

impl DeepSeekClient {
    /// The balance with `key`, also to check a key before it is stored.
    pub fn fetch(&self, key: &str, now: Timestamp) -> Result<LiveReading, String> {
        let api = api_override().unwrap_or_else(|| API.to_string());
        let response = agent()?
            .get(&format!("{}/user/balance", api.trim_end_matches('/')))
            .timeout(TIMEOUT)
            .set("Authorization", &format!("Bearer {key}"))
            .set("Accept", "application/json")
            .call();
        match response {
            Ok(response) => {
                let body = response
                    .into_string()
                    .map_err(|error| format!("Could not read the DeepSeek balance: {error}"))?;
                let balance = balance_from_response(body.as_bytes())?;
                Ok(LiveReading { snapshot: LimitSnapshot::with_balance(balance, now), details: AccountDetails::default() })
            }
            Err(ureq::Error::Status(status @ (401 | 403), _)) => {
                Err(format!("DeepSeek rejected the API key ({status}) — check it in Settings"))
            }
            Err(ureq::Error::Status(429, response)) => Err(rate_limited(
                RATE_LIMITED,
                response.header("Retry-After").and_then(|header| crate::claude_live::retry_after(header, now)),
            )),
            Err(ureq::Error::Status(status, _)) => Err(format!("DeepSeek balance API returned {status}")),
            Err(ureq::Error::Transport(error)) => Err(format!("Could not reach DeepSeek: {error}")),
        }
    }
}

/// `{"is_available": true, "balance_infos": [{"currency": "CNY", "total_balance": "110.00",
/// "granted_balance": "10.00", "topped_up_balance": "100.00"}]}`. The amounts are strings;
/// numbers are taken too. The currency with the most money is the main one.
pub fn balance_from_response(data: &[u8]) -> Result<Balance, String> {
    let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(data) else {
        return Err("DeepSeek sent a balance that is not JSON".into());
    };
    let is_available = root.get("is_available").and_then(Value::as_bool).unwrap_or(true);
    let infos: Vec<(String, f64, f64, f64)> = root
        .get("balance_infos")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .filter_map(|info| {
            let currency = info.get("currency")?.as_str()?.to_string();
            let total = amount(info.get("total_balance"))?;
            let granted = amount(info.get("granted_balance")).unwrap_or(0.0);
            let topped_up = amount(info.get("topped_up_balance")).unwrap_or(0.0);
            Some((currency, total, granted, topped_up))
        })
        .collect();
    // The first of equal totals wins.
    let Some(main) = infos.iter().fold(None, |best: Option<&(String, f64, f64, f64)>, info| match best {
        Some(best) if best.1 >= info.1 => Some(best),
        _ => Some(info),
    }) else {
        return Ok(Balance::new("USD", 0.0, 0.0, 0.0, is_available));
    };
    let mut balance = Balance::new(&main.0, main.1, main.2, main.3, is_available);
    balance.others = infos
        .iter()
        .filter(|info| info.0 != main.0)
        .map(|info| BalanceAmount { currency: info.0.clone(), total: info.1 })
        .collect();
    Ok(balance)
}

fn amount(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::String(text) => text.trim().parse().ok(),
        Value::Number(number) => number.as_f64(),
        _ => None,
    }
    .filter(|value: &f64| value.is_finite())
}

/// The stored key as "sk-…1a2b", for Settings; the key itself never leaves Rust.
pub fn key_hint(key: &str) -> String {
    let count = key.chars().count();
    if count <= 8 {
        return "•".repeat(count);
    }
    let prefix = if key.starts_with("sk-") { "sk-" } else { "" };
    let last: String = key.chars().skip(count - 4).collect();
    format!("{prefix}…{last}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn balance_response_is_parsed_from_strings() {
        let json = r#"{"is_available": true, "balance_infos": [{"currency": "CNY", "total_balance": "110.00",
            "granted_balance": "10.00", "topped_up_balance": "100.00"}]}"#;
        let balance = balance_from_response(json.as_bytes()).unwrap();
        assert_eq!(balance.currency, "CNY");
        assert_eq!(balance.total, 110.0);
        assert_eq!(balance.granted, 10.0);
        assert_eq!(balance.topped_up, 100.0);
        assert!(balance.is_available);
        assert_eq!(balance.others, []);
    }

    #[test]
    fn the_currency_with_the_most_money_is_the_main_one() {
        let json = r#"{"is_available": false, "balance_infos": [
            {"currency": "CNY", "total_balance": 3, "granted_balance": 3, "topped_up_balance": 0},
            {"currency": "USD", "total_balance": "12.50", "granted_balance": "0", "topped_up_balance": "12.50"}]}"#;
        let balance = balance_from_response(json.as_bytes()).unwrap();
        assert_eq!(balance.currency, "USD");
        assert_eq!(balance.total, 12.5);
        assert!(!balance.is_available);
        assert_eq!(balance.others, [BalanceAmount { currency: "CNY".into(), total: 3.0 }]);

        let tie = r#"{"balance_infos": [{"currency": "CNY", "total_balance": "5"}, {"currency": "USD", "total_balance": "5"}]}"#;
        assert_eq!(balance_from_response(tie.as_bytes()).unwrap().currency, "CNY", "the first of equal totals");
    }

    #[test]
    fn an_empty_or_broken_balance_response() {
        let empty = balance_from_response(br#"{"is_available": true, "balance_infos": []}"#).unwrap();
        assert_eq!(empty.total, 0.0);
        assert!(balance_from_response(b"<html>").is_err());
        assert!(balance_from_response(b"[1, 2]").is_err(), "an array is not a balance");
    }

    #[test]
    fn key_hints_show_only_the_end() {
        assert_eq!(key_hint("sk-0123456789abcdef"), "sk-…cdef");
        assert_eq!(key_hint("abcdefghijkl"), "…ijkl");
        assert_eq!(key_hint("short"), "•••••");
    }
}
