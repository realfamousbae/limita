//! Current Claude rate limits with Claude Code's own OAuth login. Port of
//! `ClaudeLiveClient.swift`.
//!
//! This uses `GET https://api.anthropic.com/api/oauth/usage`, the endpoint behind Claude
//! Code's `/usage` screen. It is **undocumented** and may change without notice; the
//! status-line capture remains the fallback.
//!
//! The access token is read from Claude Code's credentials (`~/.claude/.credentials.json`
//! on Windows, the Keychain on macOS) and is only ever sent to api.anthropic.com. It is
//! never stored or refreshed by Limita: refreshing would rotate the token under Claude
//! Code's feet.

use std::path::PathBuf;
use std::time::Duration;

use serde::Deserialize;
use serde_json::Value;

use crate::model::{AccountDetails, Allowance, LimitSnapshot, LimitWindow, LiveReading, UsageCredits};
use crate::paths;
use crate::time::{from_unix, parse_flexible, relative_text, Timestamp};

pub const ENDPOINT: &str = "https://api.anthropic.com/api/oauth/usage";
const TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Clone, Debug)]
pub struct ClaudeLiveClient {
    pub credentials_file: PathBuf,
}

impl Default for ClaudeLiveClient {
    fn default() -> Self {
        Self { credentials_file: paths::claude_dir().join(".credentials.json") }
    }
}

impl ClaudeLiveClient {
    pub fn fetch(&self, now: Timestamp) -> Result<LiveReading, String> {
        let token = self.access_token(now)?;
        let response = agent()?
            .get(ENDPOINT)
            .timeout(TIMEOUT)
            .set("Authorization", &format!("Bearer {token}"))
            .set("anthropic-beta", "oauth-2025-04-20")
            .set("Accept", "application/json")
            .call();
        match response {
            Ok(response) => {
                let body = response
                    .into_string()
                    .map_err(|error| format!("Could not read the Claude usage response: {error}"))?;
                reading_from_response(body.as_bytes(), now)
            }
            Err(ureq::Error::Status(status @ (401 | 403), _)) => {
                Err(format!("Claude rejected the login ({status}) — open Claude Code to renew it"))
            }
            Err(ureq::Error::Status(429, _)) => Err("Claude is rate-limiting usage requests".into()),
            Err(ureq::Error::Status(status, _)) => Err(format!("Claude usage API returned {status}")),
            Err(ureq::Error::Transport(error)) => Err(format!("Could not reach Claude: {error}")),
        }
    }

    pub fn access_token(&self, now: Timestamp) -> Result<String, String> {
        let data = match std::fs::read(&self.credentials_file) {
            Ok(data) => data,
            Err(_) => platform_credentials().ok_or("Not signed in to Claude Code — sign in there first")?,
        };
        access_token_from_credentials(&data, now)
    }
}

/// HTTPS through the system's TLS (SChannel on Windows), so the system's certificates
/// and any corporate root CA are trusted.
fn agent() -> Result<ureq::Agent, String> {
    let tls = native_tls::TlsConnector::new().map_err(|error| format!("Could not set up TLS: {error}"))?;
    Ok(ureq::AgentBuilder::new().tls_connector(std::sync::Arc::new(tls)).build())
}

/// On macOS Claude Code keeps its login in the Keychain, not in the file.
#[cfg(target_os = "macos")]
fn platform_credentials() -> Option<Vec<u8>> {
    let output = std::process::Command::new("/usr/bin/security")
        .args(["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        .output()
        .ok()?;
    output.status.success().then_some(output.stdout)
}

#[cfg(not(target_os = "macos"))]
fn platform_credentials() -> Option<Vec<u8>> {
    None
}

pub fn access_token_from_credentials(data: &[u8], now: Timestamp) -> Result<String, String> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Credentials {
        claude_ai_oauth: Option<OAuth>,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct OAuth {
        access_token: String,
        /// Milliseconds since 1970.
        expires_at: Option<f64>,
    }

    let oauth = serde_json::from_slice::<Credentials>(data)
        .ok()
        .and_then(|credentials| credentials.claude_ai_oauth)
        .filter(|oauth| !oauth.access_token.is_empty())
        .ok_or("Could not read the Claude Code login")?;
    if let Some(expires_at) = oauth.expires_at.and_then(|ms| from_unix(ms / 1000.0)) {
        if expires_at <= now {
            // Claude Code renews the token only while it runs; Limita never refreshes it,
            // since that could invalidate Claude Code's own copy.
            return Err(format!(
                "Claude Code login expired {} — open Claude Code to renew it",
                relative_text(expires_at, now)
            ));
        }
    }
    Ok(oauth.access_token)
}

/// Parses the usage response. Extras never cost us the limits themselves: a balance of
/// an unexpected shape just hides its row.
pub fn reading_from_response(data: &[u8], captured_at: Timestamp) -> Result<LiveReading, String> {
    let usage: Value =
        serde_json::from_slice(data).map_err(|error| format!("Claude usage API returned invalid JSON: {error}"))?;
    let snapshot = LimitSnapshot::new(window(&usage["five_hour"]), window(&usage["seven_day"]), captured_at);
    if snapshot.is_empty() {
        return Err("Claude usage API returned no limit windows".into());
    }
    let details = AccountDetails {
        claude_usage_credits: usage_credits(&usage["spend"]),
        // Cloud session credits. The key is an internal code name, so it may change; the
        // row then disappears instead of breaking the parse.
        cloud_credits: allowance(&usage["iguana_necktie"]),
        ..AccountDetails::default()
    };
    Ok(LiveReading { snapshot, details })
}

fn window(value: &Value) -> Option<LimitWindow> {
    // `utilization` is already a percentage, 0...100.
    let used = value.get("utilization")?.as_f64().filter(|v| v.is_finite())?;
    Some(LimitWindow::new(used, value.get("resets_at").and_then(Value::as_str).and_then(parse_flexible)))
}

/// `{"amount_minor": 1234, "currency": "USD", "exponent": 2}`, or a plain number.
fn dollars(value: &Value) -> Option<f64> {
    if let Some(number) = value.as_f64() {
        return Some(number);
    }
    let minor = value.get("amount_minor")?.as_f64()?;
    let exponent = value.get("exponent").and_then(Value::as_i64).unwrap_or(2);
    Some(minor / 10f64.powi(exponent as i32))
}

/// Usage credits that cover requests past the plan limits.
fn usage_credits(spend: &Value) -> Option<UsageCredits> {
    if !spend.is_object() {
        return None;
    }
    if let Some(balance) = spend.get("balance").and_then(dollars) {
        return Some(UsageCredits::Balance { dollars: balance });
    }
    if spend.get("enabled").and_then(Value::as_bool) == Some(false) {
        return Some(UsageCredits::Off);
    }
    let used = spend.get("used").and_then(dollars)?;
    Some(UsageCredits::Spent { dollars: used, limit: spend.get("limit").and_then(dollars) })
}

fn allowance(value: &Value) -> Option<Allowance> {
    let remaining = value.get("remaining_dollars")?.as_f64()?;
    Some(Allowance {
        remaining,
        limit: value.get("limit_dollars").and_then(Value::as_f64),
        expires_at: value.get("resets_at").and_then(Value::as_str).and_then(parse_flexible),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> Timestamp {
        from_unix(1_800_000_000.0).unwrap()
    }

    #[test]
    fn usage_response_is_parsed_as_percent() {
        let response = r#"{"five_hour":{"utilization":1.0,"resets_at":"2026-09-24T04:59:59.943648+00:00"},"seven_day":{"utilization":37.0,"resets_at":"2026-09-28T11:00:00+00:00"},"seven_day_opus":null}"#;
        let snapshot = reading_from_response(response.as_bytes(), now()).unwrap().snapshot;
        let five = snapshot.five_hour.unwrap();
        assert_eq!(five.used_percent, 1.0, "utilization is already a percentage");
        assert_eq!(five.resets_at.unwrap().timestamp(), parse_flexible("2026-09-24T04:59:59Z").unwrap().timestamp());
        assert_eq!(snapshot.seven_day.unwrap().used_percent, 37.0);
        assert!(reading_from_response(b"{}", now()).is_err());
    }

    #[test]
    fn details_read_cloud_and_usage_credits() {
        let response = r#"
        {"five_hour":{"utilization":33.0,"resets_at":"2026-09-24T00:10:00.439325+00:00"},
         "seven_day":{"utilization":7.0,"resets_at":"2026-09-28T11:00:00.439346+00:00"},
         "iguana_necktie":{"utilization":4.910254,"resets_at":"2026-11-05T07:59:00+00:00","limit_dollars":100,"used_dollars":4.910254,"remaining_dollars":95.089746},
         "spend":{"used":{"amount_minor":0,"currency":"USD","exponent":2},"limit":null,"enabled":false,"balance":null}}"#;
        let details = reading_from_response(response.as_bytes(), now()).unwrap().details;
        let cloud = details.cloud_credits.unwrap();
        assert!((cloud.remaining - 95.09).abs() < 0.01);
        assert_eq!(cloud.limit, Some(100.0));
        assert_eq!(cloud.expires_at, parse_flexible("2026-11-05T07:59:00Z"));
        assert_eq!(details.claude_usage_credits, Some(UsageCredits::Off));
        assert_eq!(details.limit_resets, None);

        let enabled = r#"{"five_hour":{"utilization":1},"spend":{"enabled":true,"used":{"amount_minor":1250,"exponent":2},"limit":{"amount_minor":5000,"exponent":2}}}"#;
        assert_eq!(
            reading_from_response(enabled.as_bytes(), now()).unwrap().details.claude_usage_credits,
            Some(UsageCredits::Spent { dollars: 12.5, limit: Some(50.0) })
        );

        let with_balance = r#"{"five_hour":{"utilization":1},"spend":{"enabled":true,"balance":{"amount_minor":2000,"exponent":2}},"iguana_necktie":"unexpected"}"#;
        let parsed = reading_from_response(with_balance.as_bytes(), now()).unwrap().details;
        assert_eq!(parsed.claude_usage_credits, Some(UsageCredits::Balance { dollars: 20.0 }));
        assert_eq!(parsed.cloud_credits, None, "a changed shape hides the row instead of failing");
    }

    #[test]
    fn expired_token_says_when() {
        let expired = format!(r#"{{"claudeAiOauth":{{"accessToken":"t","expiresAt":{}}}}}"#, (1_800_000_000.0 - 3.0 * 3600.0) * 1000.0);
        let error = access_token_from_credentials(expired.as_bytes(), now()).unwrap_err();
        assert!(error.contains("3 hours ago"), "{error}");
        let valid = format!(r#"{{"claudeAiOauth":{{"accessToken":"t","expiresAt":{}}}}}"#, (1_800_000_000.0 + 60.0) * 1000.0);
        assert_eq!(access_token_from_credentials(valid.as_bytes(), now()).unwrap(), "t");
        assert!(access_token_from_credentials(b"{}", now()).is_err());
    }
}
