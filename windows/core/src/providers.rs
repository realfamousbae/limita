use std::{
    collections::BTreeMap,
    path::Path,
    process::{Command, Stdio},
    time::Duration,
};

use chrono::{Days, NaiveDate};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    live, locator,
    model::{AccountDetails, Balance, LimitSnapshot, LimitWindow, LiveReading, Service},
    secrets::{CredentialStore, SecretStore},
    time::{self, Timestamp},
};

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ProviderData {
    pub quotas: Vec<Quota>,
    pub metrics: BTreeMap<String, String>,
    pub total_credits: Option<f64>,
    pub history: Option<SpendHistory>,
    pub notice: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Quota {
    pub name: String,
    pub short_name: String,
    pub window: LimitWindow,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct SpendHistory {
    pub currency: String,
    pub days: BTreeMap<String, BTreeMap<String, f64>>,
    #[serde(default)]
    pub estimated: bool,
    #[serde(default)]
    pub account_scope: Option<String>,
}

pub struct SpendSummary {
    pub today: Option<f64>,
    pub yesterday: Option<f64>,
    pub month: Option<f64>,
    pub month_complete: bool,
    pub daily_average: Option<f64>,
    pub week_complete: bool,
    pub top_model: Option<String>,
}

impl SpendHistory {
    pub fn summary(&self, service: Service, now: Timestamp) -> SpendSummary {
        use chrono::Datelike;

        let offset = if service == Service::QwenApi { 8 } else { 0 };
        let today = (now + chrono::TimeDelta::hours(offset)).date_naive();
        let month_start = today.with_day(1).unwrap();
        let today_key = today.to_string();
        let month_key = month_start.to_string();
        let week: Vec<_> = (1..=7)
            .filter_map(|day| self.days.get(&(today - Days::new(day)).to_string()))
            .collect();
        let month: Vec<_> = self
            .days
            .range(month_key..=today_key.clone())
            .map(|(_, amounts)| amounts)
            .collect();
        let sum = |amounts: &BTreeMap<String, f64>| amounts.values().sum::<f64>();
        let mut models: BTreeMap<&str, f64> = BTreeMap::new();
        for amounts in &week {
            for (model, amount) in *amounts {
                if !model.is_empty() && model != "Other" {
                    *models.entry(model).or_default() += amount;
                }
            }
        }
        let top_model = models
            .into_iter()
            .filter(|(_, amount)| *amount > 0.0)
            .max_by(|(left_name, left), (right_name, right)| {
                left.total_cmp(right)
                    .then_with(|| right_name.cmp(left_name))
            })
            .map(|(model, _)| model.to_owned());
        SpendSummary {
            today: self.days.get(&today_key).map(sum),
            yesterday: self.days.get(&(today - Days::new(1)).to_string()).map(sum),
            month: (!month.is_empty()).then(|| month.into_iter().map(sum).sum()),
            month_complete: (0..u64::from(today.day0())).all(|offset| {
                self.days
                    .contains_key(&(month_start + Days::new(offset)).to_string())
            }),
            daily_average: (!week.is_empty())
                .then(|| week.iter().map(|amounts| sum(amounts)).sum::<f64>() / week.len() as f64),
            week_complete: week.len() == 7,
            top_model,
        }
    }

    pub fn new(currency: impl Into<String>) -> Self {
        Self {
            currency: currency.into(),
            days: BTreeMap::new(),
            estimated: false,
            account_scope: None,
        }
    }

    pub fn add(&mut self, day: &str, model: &str, charge: f64) {
        if NaiveDate::parse_from_str(day, "%Y-%m-%d").is_ok() && charge.is_finite() {
            *self
                .days
                .entry(day.into())
                .or_default()
                .entry(model.into())
                .or_default() += charge;
        }
    }

    pub fn load(path: &Path) -> Option<Self> {
        serde_json::from_slice(&std::fs::read(path).ok()?).ok()
    }

    pub fn merge(&self, path: &Path) -> Self {
        let mut merged = Self::load(path)
            .filter(|prior| {
                prior.currency == self.currency && prior.account_scope == self.account_scope
            })
            .unwrap_or_else(|| self.clone());
        merged.days.extend(self.days.clone());
        while merged.days.len() > 370 {
            merged.days.pop_first();
        }
        if let (Some(parent), Ok(bytes)) = (path.parent(), serde_json::to_vec(&merged)) {
            let next = path.with_extension("tmp");
            let _ = std::fs::create_dir_all(parent)
                .and_then(|_| std::fs::write(&next, bytes))
                .and_then(|_| std::fs::rename(next, path));
        }
        merged
    }
}

#[derive(Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Credentials {
    pub key: String,
    pub workspace: String,
    pub refresh_token: Option<String>,
    pub expires_at: Option<Timestamp>,
    pub organization: Option<String>,
    pub project: Option<String>,
}

pub fn is_demo() -> bool {
    std::env::var("LIMITA_FAKE_PROVIDERS").as_deref() == Ok("1")
}

fn request_url(url: &str) -> String {
    if !is_demo() {
        return url.into();
    }
    let (host, path) = url
        .strip_prefix("https://")
        .and_then(|rest| rest.split_once('/'))
        .expect("provider URL");
    let fixture = match host {
        "api.z.ai" => "zai",
        "opencode.ai" => "opencode",
        "openrouter.ai" => "openrouter",
        "modelstudio.invalid" => "qwen",
        _ => unreachable!("unknown demo provider"),
    };
    format!("http://127.0.0.1:8377/providers/{fixture}/{path}")
}

pub fn credential_store(service: Service) -> CredentialStore {
    CredentialStore {
        target: format!(
            "Limita/{}{}-connection",
            if is_demo() { "fake/" } else { "" },
            service.id()
        ),
    }
}

pub fn setup_link(service: Service) -> Option<&'static str> {
    Some(match service {
        Service::ZaiCoding => "https://z.ai/manage-apikey/apikey-list",
        Service::ZaiApi => "https://z.ai/manage-apikey/billing",
        Service::QwenCoding | Service::QwenToken => {
            "https://docs.modelstudio.console.alibabacloud.com/en/model-studio/cli/installation"
        }
        Service::QwenApi => "https://api.alibabacloud.com/api-tools/cli/ModelStudio/2026-02-10",
        Service::OpenCodeGo | Service::OpenCodeApi => "https://opencode.ai/console",
        Service::OpenRouter => "https://openrouter.ai/settings/keys",
        _ => return None,
    })
}

pub fn fetch(
    service: Service,
    supplied: Option<&Credentials>,
    now: Timestamp,
) -> Result<LiveReading, String> {
    let saved;
    let credentials = if let Some(supplied) = supplied {
        supplied
    } else {
        let raw = credential_store(service)
            .read()?
            .ok_or_else(|| format!("Connect {} in Settings", service.display_name()))?;
        let stored =
            serde_json::from_str(&raw).map_err(|_| "The stored provider connection is invalid")?;
        saved = if service == Service::OpenCodeApi {
            renewed_open_code(stored, now)?
        } else {
            stored
        };
        &saved
    };
    if is_demo()
        && !matches!(
            credentials.key.as_str(),
            "" | "demo"
                | "demo-management"
                | "demo-bad"
                | "demo-limited"
                | "demo-partial"
                | "demo-session"
        )
    {
        return Err("Use a demo credential in fake API mode.".into());
    }
    let mut provider = ProviderData::default();
    let mut balance = None;
    match service {
        Service::ZaiCoding => {
            let response = json(
                "https://api.z.ai/api/monitor/usage/quota/limit",
                &credentials.key,
                "",
            )?;
            provider.quotas = zai_quotas(&response);
        }
        Service::OpenCodeGo => {
            let root = json(
                "https://opencode.ai/inference/go/v1/usage",
                &bearer(&credentials.key),
                "",
            )?;
            provider.quotas = [
                ("rolling", "5 HOURS", "5h"),
                ("weekly", "7 DAYS", "7d"),
                ("monthly", "MONTH", "1m"),
            ]
            .into_iter()
            .filter_map(|(key, name, short)| {
                quota(
                    name,
                    short,
                    &root["usage"][key]["percent"],
                    &root["usage"][key]["resetsAt"],
                    1.0,
                )
            })
            .collect();
        }
        Service::QwenCoding | Service::QwenToken => {
            let plan = if service == Service::QwenCoding {
                "coding-plan"
            } else {
                "token-plan"
            };
            let root = cli(&["bl", "bailian"], &["usage", plan, "--output", "json"],
                           "Install Bailian CLI and sign in with bl auth login --console --console-site international.")?;
            provider.quotas = qwen_quotas(&root, service == Service::QwenCoding);
        }
        Service::QwenApi => (balance, provider) = qwen_billing(&credentials.workspace, now),
        Service::OpenCodeApi => (balance, provider) = open_code(credentials)?,
        Service::OpenRouter => (balance, provider) = open_router(&credentials.key, now)?,
        Service::ZaiApi => (balance, provider) = zai_billing(credentials, now)?,
        _ => return Err("Unsupported provider connection".into()),
    };
    if balance.is_none()
        && provider.quotas.is_empty()
        && provider.metrics.is_empty()
        && provider.history.is_none()
    {
        return Err(provider.notice.unwrap_or_else(|| {
            "No usage received. Check the provider account and permissions.".into()
        }));
    }
    let mut snapshot = LimitSnapshot::new(None, None, now);
    if let Some(headline) = provider.quotas.first() {
        snapshot = if headline.short_name == "5h" {
            LimitSnapshot::new(Some(headline.window), None, now)
        } else {
            LimitSnapshot::with_flag(None, Some(headline.window), now, true)
                .with_long_window_days(if headline.short_name == "1m" { 30 } else { 7 })
        };
    }
    snapshot.balance = balance;
    Ok(LiveReading {
        snapshot,
        details: AccountDetails {
            provider: Some(provider),
            ..Default::default()
        },
    })
}

pub static CREDENTIALS_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
const OPEN_CODE_AUTH: &str = "https://opencode.ai/console/auth/device";
const OPEN_CODE_CLIENT: &str = "opencode-cli";

#[derive(Deserialize)]
pub struct OpenCodeDevice {
    device_code: String,
    pub user_code: String,
    verification_uri_complete: String,
    expires_in: u64,
    interval: u64,
}

impl OpenCodeDevice {
    pub fn verification_uri(&self) -> Option<String> {
        let url = &self.verification_uri_complete;
        if is_demo() && url == "/demo-opencode" {
            return Some(format!("http://127.0.0.1:8377{url}"));
        }
        if url.starts_with("https://opencode.ai/") {
            return Some(url.clone());
        }
        if url.starts_with("/console/") {
            return Some(format!("https://opencode.ai{url}"));
        }
        None
    }
}

pub fn begin_open_code_sign_in() -> Result<OpenCodeDevice, String> {
    let root = open_code_auth(
        "code",
        serde_json::json!({ "client_id": OPEN_CODE_CLIENT, "supports_org_scope": true }),
    )?;
    let device: OpenCodeDevice =
        serde_json::from_value(root).map_err(|_| "Invalid OpenCode sign-in response")?;
    if device.verification_uri().is_none() {
        return Err("Invalid OpenCode sign-in URL".into());
    }
    Ok(device)
}

pub fn finish_open_code_sign_in(
    device: OpenCodeDevice,
    cancelled: impl Fn() -> bool,
) -> Result<Credentials, String> {
    let mut interval = device.interval.clamp(1, 30);
    let deadline = std::time::Instant::now() + Duration::from_secs(device.expires_in.min(900));
    while std::time::Instant::now() < deadline {
        for _ in 0..interval {
            if cancelled() {
                return Err("OpenCode sign-in cancelled".into());
            }
            std::thread::sleep(Duration::from_secs(1));
        }
        let root = open_code_auth(
            "token",
            serde_json::json!({
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": device.device_code, "client_id": OPEN_CODE_CLIENT,
            }),
        )?;
        match root["error"].as_str() {
            Some("authorization_pending") => {}
            Some("slow_down") => interval = (interval + 5).min(60),
            None => return open_code_token(&root, None),
            _ => return Err("OpenCode sign-in ended. Try again in Settings.".into()),
        }
    }
    Err("OpenCode sign-in code expired. Try again.".into())
}

fn open_code_token(root: &Value, workspace: Option<&str>) -> Result<Credentials, String> {
    let error = "OpenCode did not return a workspace session. Select a workspace when you sign in.";
    let key = root["access_token"]
        .as_str()
        .filter(|key| !key.is_empty())
        .ok_or(error)?;
    let refresh = root["refresh_token"]
        .as_str()
        .filter(|key| !key.is_empty())
        .ok_or(error)?;
    let expiry = root["expires_in"]
        .as_i64()
        .filter(|seconds| *seconds > 0 && *seconds < 86_400 * 365)
        .ok_or(error)?;
    let scope = root["org_id"]
        .as_str()
        .or(workspace)
        .filter(|id| !id.is_empty())
        .ok_or(error)?;
    Ok(Credentials {
        key: key.into(),
        workspace: scope.into(),
        refresh_token: Some(refresh.into()),
        expires_at: Some(chrono::Utc::now() + chrono::TimeDelta::seconds(expiry)),
        ..Default::default()
    })
}

fn renewed_open_code(stored: Credentials, now: Timestamp) -> Result<Credentials, String> {
    let Some(refresh) = stored.refresh_token.as_deref().filter(|_| {
        stored
            .expires_at
            .is_some_and(|expiry| time::seconds_between(now, expiry) < 60.0)
    }) else {
        return Ok(stored);
    };
    let root = open_code_auth(
        "token",
        serde_json::json!({
            "grant_type": "refresh_token", "refresh_token": refresh, "client_id": OPEN_CODE_CLIENT,
        }),
    )?;
    let renewed = open_code_token(&root, Some(&stored.workspace))?;
    if renewed.workspace != stored.workspace {
        return Err("OpenCode workspace changed. Reconnect in Settings.".into());
    }
    let _guard = CREDENTIALS_LOCK
        .lock()
        .unwrap_or_else(|guard| guard.into_inner());
    let secret = credential_store(Service::OpenCodeApi);
    if secret
        .read()?
        .as_deref()
        .and_then(|s| serde_json::from_str::<Credentials>(s).ok())
        != Some(stored)
    {
        return Err("OpenCode connection changed".into());
    }
    secret
        .save(&serde_json::to_string(&renewed).map_err(|_| "Could not save OpenCode session")?)?;
    Ok(renewed)
}

fn open_code_auth(operation: &str, body: Value) -> Result<Value, String> {
    let address = request_url(&format!("{OPEN_CODE_AUTH}/{operation}"));
    let request = live::agent_no_redirect()?
        .post(&address)
        .timeout(Duration::from_secs(15))
        .set("Content-Type", "application/json");
    let result = match request.send_string(&body.to_string()) {
        Err(ureq::Error::Status(400, response)) if operation == "token" => Ok(response),
        result => result,
    };
    let body = read_http(result)?;
    serde_json::from_str(&body).map_err(|_| "Invalid OpenCode sign-in response".into())
}

pub const ZAI_SESSION_SCRIPT: &str = r#"
(() => {
  if (location.origin !== 'https://z.ai') return null;
  const user = JSON.parse(localStorage.getItem('platform-user-info') || '{}');
  return {
    key: localStorage.getItem('z-ai-open-platform-token-production') || '',
    workspace: String(user.customerNumber || ''),
    organization: localStorage.getItem('Bigmodel-Organization'),
    project: localStorage.getItem('Bigmodel-Project')
  };
})()
"#;

fn zai_billing(
    credentials: &Credentials,
    now: Timestamp,
) -> Result<(Option<Balance>, ProviderData), String> {
    if credentials.key.is_empty() || credentials.workspace.is_empty() {
        return Err("Sign in to Z.ai and open Billing before connecting.".into());
    }
    let base = "https://api.z.ai/api/platform-charge-zai";
    let agent = live::agent_no_redirect()?;
    let setup = |mut request: ureq::Request| {
        request = request
            .timeout(Duration::from_secs(15))
            .set("Authorization", &bearer(&credentials.key))
            .set("Refer", "https://z.ai/manage-apikey/billing");
        if let Some(org) = &credentials.organization {
            request = request.set("Bigmodel-Organization", org);
        }
        if let Some(project) = &credentials.project {
            request = request.set("Bigmodel-Project", project);
        }
        request
    };
    let request = setup(agent.post(&request_url(&format!("{base}/business/accountBalance"))))
        .set("Content-Type", "application/json");
    let body = serde_json::json!({"customerId": credentials.workspace});
    let mut provider = ProviderData::default();
    let balance = match read_http(request.send_string(&body.to_string()))
        .and_then(|text| zai_data(&text))
    {
        Ok(report) => number(&report["totalBalance"]).map(|amount| simple_balance(amount, "USD")),
        Err(error) if live::rate_limit_of(&error).is_some() => return Err(error),
        Err(_) => {
            provider.notice =
                Some("Z.ai balance unavailable. Reconnect if the session has expired.".into());
            None
        }
    };
    let today = now.date_naive();
    let months = [
        today,
        today
            .checked_sub_months(chrono::Months::new(1))
            .unwrap_or(today),
    ];
    let mut history = SpendHistory::new("USD");
    let mut coverage = false;
    for date in months {
        let period = date.format("%Y-%m").to_string();
        let mut month = SpendHistory::new("USD");
        let mut complete = false;
        for page in 1..=25 {
            let request = setup(agent.get(&request_url(&format!("{base}/bill/day"))))
                .query("customerId", &credentials.workspace)
                .query("billingPeriod", &period)
                .query("pageNum", &page.to_string())
                .query("pageSize", "100");
            let report = match read_http(request.call()).and_then(|text| zai_data(&text)) {
                Ok(report) => report,
                Err(error) if live::rate_limit_of(&error).is_some() => return Err(error),
                Err(_) => break,
            };
            let Some(rows) = report["records"].as_array() else {
                break;
            };
            for row in rows {
                if let (Some(day), Some(cost)) = (
                    row["billingDate"].as_str().and_then(|d| d.get(..10)),
                    number(&row["settlementAmount"]),
                ) {
                    if day.starts_with(&period) {
                        let model = row["modelCode"]
                            .as_str()
                            .filter(|name| !name.is_empty())
                            .unwrap_or("Other");
                        month.add(day, model, cost);
                    }
                }
            }
            if rows.len() < 100
                || number(&report["total"]).is_some_and(|total| f64::from(page * 100) >= total)
            {
                complete = true;
                break;
            }
        }
        if complete {
            coverage = true;
            history.days.extend(month.days);
        } else {
            provider.notice = Some(
                "Some Z.ai billing history is unavailable. Open billing or reconnect in Settings."
                    .into(),
            );
        }
    }
    provider.history = coverage.then_some(history);
    Ok((balance, provider))
}

fn zai_data(text: &str) -> Result<Value, String> {
    let root: Value = serde_json::from_str(text).map_err(|_| "Invalid Z.ai billing response")?;
    if !matches!(number(&root["code"]), Some(0.0 | 200.0)) || !root["data"].is_object() {
        return Err("Z.ai billing rejected the session. Sign in again in Settings.".into());
    }
    Ok(root["data"].clone())
}

fn number(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_str()?.parse().ok())
        .filter(|value| value.is_finite())
}

fn date(value: &Value) -> Option<Timestamp> {
    if let Some(raw) = number(value).filter(|n| *n > 0.0) {
        time::from_unix(if raw > 10_000_000_000.0 {
            raw / 1000.0
        } else {
            raw
        })
    } else {
        time::parse_flexible(value.as_str()?)
    }
}

fn quota(name: &str, short: &str, percent: &Value, reset: &Value, scale: f64) -> Option<Quota> {
    let used_percent = number(percent).filter(|used| *used >= 0.0)? * scale;
    Some(Quota {
        name: name.into(),
        short_name: short.into(),
        window: LimitWindow {
            used_percent,
            resets_at: date(reset),
        },
    })
}

fn zai_quotas(root: &Value) -> Vec<Quota> {
    let mut windows: Vec<_> = root["data"]["limits"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|item| {
            let (name, short, order) = match (
                item["type"].as_str()?,
                number(&item["number"]),
                number(&item["unit"]),
            ) {
                ("TIME_LIMIT", _, _) => ("MONTHLY TOOLS", "1m", 3),
                ("TOKENS_LIMIT", Some(5.0), _) => ("5 HOURS", "5h", 0),
                ("TOKENS_LIMIT", Some(7.0), _) | ("TOKENS_LIMIT", _, Some(6.0)) => {
                    ("7 DAYS", "7d", 1)
                }
                ("TOKENS_LIMIT", _, _) => ("MODEL QUOTA", "quota", 2),
                _ => return None,
            };
            Some((
                order,
                quota(
                    name,
                    short,
                    &item["percentage"],
                    &item["nextResetTime"],
                    1.0,
                )?,
            ))
        })
        .collect();
    windows.sort_by_key(|(order, _)| *order);
    windows.into_iter().map(|(_, quota)| quota).collect()
}

fn qwen_quotas(root: &Value, coding: bool) -> Vec<Quota> {
    if coding {
        return [
            ("per5Hour", "5 HOURS", "5h"),
            ("perWeek", "7 DAYS", "7d"),
            ("perBillMonth", "BILLING MONTH", "1m"),
        ]
        .into_iter()
        .filter_map(|(key, name, short)| {
            quota(
                name,
                short,
                &root[key]["percentage"],
                &root[key]["resetTime"],
                100.0,
            )
        })
        .collect();
    }
    root.as_object()
        .into_iter()
        .flat_map(|items| items.iter())
        .filter_map(|(key, percent)| {
            let window = key.strip_prefix("per")?.strip_suffix("Percentage")?;
            let (label, short) = match window {
                "1Month" | "BillMonth" => ("MONTH".into(), "1m".into()),
                _ => (window.to_uppercase(), window.to_lowercase()),
            };
            quota(
                &label,
                &short,
                percent,
                &root[format!("per{window}ResetTime")],
                100.0,
            )
        })
        .collect()
}

fn bearer(key: &str) -> String {
    format!("Bearer {key}")
}

fn get(address: &str, auth: &str, workspace: &str) -> Result<String, String> {
    let agent = live::agent_no_redirect()?;
    let mut request = agent
        .get(&request_url(address))
        .set("Authorization", auth)
        .timeout(Duration::from_secs(15));
    if !workspace.is_empty() {
        request = request.set("x-org-id", workspace);
    }
    read_http(request.call())
}

fn read_http(result: Result<ureq::Response, ureq::Error>) -> Result<String, String> {
    match result {
        Ok(response) => response
            .into_string()
            .map_err(|_| "Could not read provider response".into()),
        Err(ureq::Error::Status(429, response)) => Err(live::rate_limited(
            "Provider is rate-limiting usage requests",
            response
                .header("Retry-After")
                .and_then(|value| value.parse().ok()),
        )),
        Err(ureq::Error::Status(code @ (401 | 403), _)) => Err(format!(
            "The provider denied access ({code}). Check the key and its permissions."
        )),
        Err(ureq::Error::Status(code, _)) => {
            Err(format!("Provider usage request returned HTTP {code}"))
        }
        Err(_) => Err("Could not reach the provider".into()),
    }
}

fn json(address: &str, auth: &str, workspace: &str) -> Result<Value, String> {
    serde_json::from_str(&get(address, auth, workspace)?)
        .map_err(|_| "Provider returned unreadable usage".into())
}

fn simple_balance(total: f64, currency: &str) -> Balance {
    Balance {
        currency: currency.into(),
        total,
        granted: 0.0,
        topped_up: 0.0,
        is_available: true,
        others: Vec::new(),
        spent_today: None,
        spent_this_month: None,
        daily_burn: None,
        full_scale: None,
        low_threshold: None,
    }
}

fn open_router(key: &str, now: Timestamp) -> Result<(Option<Balance>, ProviderData), String> {
    let auth = bearer(key);
    let response = match json("https://openrouter.ai/api/v1/key", &auth, "") {
        Ok(response) => response,
        Err(error) if error.contains("(403)") => Value::Null,
        Err(error) => return Err(error),
    };
    let info = &response["data"];
    let mut provider = ProviderData::default();
    let mut balance = None;
    if info["is_management_key"].as_bool() != Some(false) {
        match json("https://openrouter.ai/api/v1/credits", &auth, "") {
            Ok(credits) => {
                let credits = &credits["data"];
                balance = number(&credits["total_credits"])
                    .zip(number(&credits["total_usage"]))
                    .map(|(bought, used)| {
                        provider.total_credits = (bought > 0.0).then_some(bought);
                        simple_balance(bought - used, "USD")
                    });
            }
            Err(error) if live::rate_limit_of(&error).is_some() => return Err(error),
            Err(_) => provider.notice = Some("Account balance unavailable with this key.".into()),
        }
        match json("https://openrouter.ai/api/v1/activity", &auth, "") {
            Ok(report) => provider.history = open_router_history(&report, now),
            Err(error) if live::rate_limit_of(&error).is_some() => return Err(error),
            Err(_) => {}
        }
    }
    if provider.history.is_none() {
        for (field, title) in [
            ("usage_daily", "KEY SPEND TODAY"),
            ("usage_weekly", "KEY SPEND THIS WEEK"),
            ("usage_monthly", "KEY SPEND THIS MONTH"),
            ("limit_remaining", "KEY LIMIT LEFT"),
        ] {
            if let Some(amount) = number(&info[field]) {
                provider
                    .metrics
                    .insert(title.into(), Balance::format(amount, "USD"));
            }
        }
        if let Some(daily) = number(&info["usage_daily"]) {
            let mut history = SpendHistory::new("USD");
            history.add(&now.date_naive().to_string(), "", daily);
            provider.history = Some(history);
        }
        provider.notice =
            Some("Use a Management key to view model history and account credits.".into());
    }
    Ok((balance, provider))
}

fn open_router_history(report: &Value, now: Timestamp) -> Option<SpendHistory> {
    let rows = report["data"].as_array()?;
    let mut output = SpendHistory::new("USD");
    for offset in 1..=30 {
        let day = now.date_naive().checked_sub_days(Days::new(offset))?;
        output.days.entry(day.to_string()).or_default();
    }
    for row in rows {
        let Some(day) = row["date"].as_str().and_then(|value| value.get(..10)) else {
            continue;
        };
        if let (true, Some(cost)) = (output.days.contains_key(day), number(&row["usage"])) {
            output.add(day, row["model"].as_str().unwrap_or("Other"), cost);
        }
    }
    Some(output)
}

fn open_code(credentials: &Credentials) -> Result<(Option<Balance>, ProviderData), String> {
    let valid = credentials
        .workspace
        .split_once('_')
        .is_some_and(|(kind, id)| {
            matches!(kind, "org" | "wrk")
                && !id.is_empty()
                && id.bytes().all(|byte| byte.is_ascii_alphanumeric())
        });
    if !valid {
        return Err("Enter the OpenCode workspace ID (org_… or wrk_…).".into());
    }
    let auth = bearer(&credentials.key);
    let workspace = &credentials.workspace;
    let mut provider = ProviderData::default();
    let balance = match json(
        "https://opencode.ai/console/api/billing/status",
        &auth,
        workspace,
    ) {
        Ok(report) => number(&report["availableMicroCents"])
            .map(|amount| simple_balance(amount / 100_000_000.0, "USD")),
        Err(error) if live::rate_limit_of(&error).is_some() => return Err(error),
        Err(_) => None,
    };
    match get(
        "https://opencode.ai/console/api/v2/usage/export?range=90d",
        &auth,
        workspace,
    ) {
        Ok(csv) => provider.history = open_code_history(&csv),
        Err(error) if live::rate_limit_of(&error).is_some() => return Err(error),
        Err(_) => {}
    }
    if balance.is_none() {
        provider.notice =
            Some("Balance requires Billing read access or a signed-in workspace owner.".into());
    }
    if provider.history.is_none() {
        provider
            .notice
            .get_or_insert_with(String::new)
            .push_str(" History requires Usage read access in this workspace.");
    }
    Ok((balance, provider))
}

fn open_code_history(csv: &str) -> Option<SpendHistory> {
    let rows = parse_csv(csv);
    let header = rows.first()?;
    let day = header.iter().position(|v| v == "day")?;
    let model = header.iter().position(|v| v == "model")?;
    let cost = header.iter().position(|v| v == "cost_micro_cents")?;
    let provider = header.iter().position(|v| v == "provider");
    let mut output = SpendHistory::new("USD");
    for row in rows.iter().skip(1).filter(|row| row.len() == header.len()) {
        if provider
            .is_some_and(|index| !matches!(row[index].as_str(), "opencode" | "opencode-go" | "zen"))
        {
            continue;
        }
        if let Ok(amount) = row[cost].parse::<f64>() {
            output.add(
                &row[day],
                if row[model].is_empty() {
                    "Other"
                } else {
                    &row[model]
                },
                amount / 100_000_000.0,
            );
        }
    }
    Some(output)
}

fn parse_csv(input: &str) -> Vec<Vec<String>> {
    let mut rows = Vec::new();
    let mut row = Vec::new();
    let mut field = String::new();
    let mut quoted = false;
    let mut chars = input.trim_start_matches('\u{feff}').chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '"' if quoted && chars.peek() == Some(&'"') => {
                chars.next();
                field.push('"');
            }
            '"' => quoted = !quoted,
            ',' if !quoted => row.push(std::mem::take(&mut field)),
            '\n' if !quoted => {
                row.push(std::mem::take(&mut field));
                rows.push(std::mem::take(&mut row));
            }
            '\r' if !quoted => {}
            _ => field.push(ch),
        }
    }
    if !row.is_empty() || !field.is_empty() {
        row.push(field);
        rows.push(row);
    }
    rows
}

fn qwen_billing(profile: &str, now: Timestamp) -> (Option<Balance>, ProviderData) {
    let mut provider = ProviderData::default();
    if !profile
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"_-. ".contains(&byte))
    {
        provider.notice = Some("Enter a valid Alibaba Cloud CLI profile name.".into());
        return (None, provider);
    }
    let day = (now + chrono::TimeDelta::hours(8)).date_naive();
    let period = serde_json::json!({"start": day - Days::new(34), "end": day}).to_string();
    let profile_args = if profile.is_empty() {
        Vec::new()
    } else {
        vec!["--profile", profile]
    };
    let failure = "Configure Alibaba Cloud CLI with a profile that can read Model Studio billing.";
    let mut identity_args = vec!["sts", "get-caller-identity"];
    identity_args.extend(&profile_args);
    let account = cli(&["aliyun"], &identity_args, failure)
        .ok()
        .and_then(|report| report["AccountId"].as_str().map(str::to_owned));
    let Some(account) = account else {
        provider.notice =
            Some("Check the Alibaba Cloud CLI profile and its STS read permission.".into());
        return (None, provider);
    };
    let mut args = vec![
        "modelstudio",
        "get-billing-trend",
        "--granularity",
        "DAY",
        "--time-period",
        &period,
        "--group-by",
        r#"[{"code":"BASE_MODEL"}]"#,
        "--filter",
        r#"{"dimensions":[{"code":"CHARGE_TYPE","values":["postpaid"],"selectType":"INCLUDE"}]}"#,
        "--region",
        "ap-southeast-1",
    ];
    args.extend(&profile_args);
    provider.history = cli(&["aliyun"], &args, failure)
        .ok()
        .and_then(|root| qwen_history(&root));
    if let Some(history) = &mut provider.history {
        history.account_scope = Some(account);
    } else {
        provider.notice = Some(failure.into());
    }
    let mut args = vec!["bssopenapi", "query-account-balance"];
    args.extend(&profile_args);
    let balance = cli(&["aliyun"], &args, failure).ok().and_then(|root| {
        Some(simple_balance(
            number(&root["Data"]["AvailableAmount"])?,
            root["Data"]["Currency"].as_str()?,
        ))
    });
    if balance.is_none() {
        provider
            .notice
            .get_or_insert_with(String::new)
            .push_str(" Alibaba Cloud balance unavailable.");
    }
    (balance, provider)
}

fn qwen_history(root: &Value) -> Option<SpendHistory> {
    let data = root.get("data").unwrap_or(root);
    let periods = data["resultByTime"].as_array()?;
    let currency = data["costTotals"]["currency"].as_str().or_else(|| {
        periods
            .iter()
            .find_map(|row| row["total"]["currency"].as_str())
    })?;
    let mut history = SpendHistory::new(currency);
    for period in periods {
        let Some(day) = period["period"]
            .as_str()
            .and_then(|value| NaiveDate::parse_from_str(value, "%Y%m%d").ok())
        else {
            continue;
        };
        let key = day.to_string();
        let mut attributed = 0.0;
        for row in period["periodDetails"].as_array().into_iter().flatten() {
            if let Some(cost) = number(&row["amount"]) {
                let model = row["name"]
                    .as_str()
                    .or_else(|| row["key"].as_str())
                    .unwrap_or("Other");
                history.add(&key, model, cost);
                attributed += cost;
            }
        }
        if let Some(total) = number(&period["total"]["amount"]) {
            if (total - attributed).abs() > 1e-8 || !history.days.contains_key(&key) {
                history.add(&key, "Other", total - attributed);
            }
        }
    }
    Some(history)
}

fn cli(names: &[&str], args: &[&str], failure: &str) -> Result<Value, String> {
    if is_demo() {
        return json(
            &format!("https://modelstudio.invalid/{}", args[1]),
            "demo",
            "",
        );
    }
    let executable = names
        .iter()
        .find_map(|name| locator::find(name))
        .ok_or(failure)?;
    let mut cmd = Command::new(executable);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }
    use std::io::Read;
    let mut child = cmd
        .args(args)
        .env("PATH", locator::child_path())
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|_| failure)?;
    let mut pipe = child.stdout.take().ok_or(failure)?;
    let output = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        pipe.read_to_end(&mut bytes).map(|_| bytes)
    });
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    loop {
        match child.try_wait().map_err(|_| failure)? {
            Some(status) if status.success() && output.is_finished() => break,
            Some(status) if !status.success() => return Err(failure.into()),
            _ if std::time::Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(failure.into());
            }
            _ => std::thread::sleep(Duration::from_millis(40)),
        }
    }
    let stdout = output.join().map_err(|_| failure)?.map_err(|_| failure)?;
    serde_json::from_slice(&stdout).map_err(|_| "CLI returned unreadable usage".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    #[ignore = "requires the local fake provider HTTP server"]
    fn local_fake_api() {
        assert!(
            is_demo(),
            "Set LIMITA_FAKE_PROVIDERS=1 and start scripts/fake-api.py"
        );
        use crate::store::{Sources, Store};
        let fixture = tempfile::tempdir().unwrap();
        let mut sources = Sources::standard(None);
        sources.settings.file = fixture.path().join("settings.json");
        sources.ledger_file = None;
        sources.resets_file = fixture.path().join("resets.json");
        let store = Store::new(sources, Default::default, || {});
        let providers = [
            (Service::ZaiCoding, "demo", "", 3, false),
            (Service::ZaiApi, "demo-session", "demo", 0, true),
            (Service::QwenCoding, "", "", 3, false),
            (Service::QwenToken, "", "", 1, false),
            (Service::QwenApi, "", "", 0, true),
            (Service::OpenCodeGo, "demo", "", 3, false),
            (Service::OpenCodeApi, "demo", "org_demo", 0, true),
            (Service::OpenRouter, "demo-management", "", 0, true),
        ];
        for (service, key, workspace, quotas, billing) in providers {
            store
                .connect_provider(
                    service,
                    Credentials {
                        key: key.into(),
                        workspace: workspace.into(),
                        ..Default::default()
                    },
                )
                .unwrap_or_else(|error| panic!("{}: {error}", service.id()));
            let snapshot = store.snapshot();
            assert_eq!(
                snapshot.details[&service]
                    .provider
                    .as_ref()
                    .unwrap()
                    .quotas
                    .len(),
                quotas
            );
            if billing {
                assert!(
                    snapshot
                        .state(service)
                        .snapshot()
                        .unwrap()
                        .balance
                        .as_ref()
                        .unwrap()
                        .total
                        > 0.0
                );
                assert!(store.spend_history(service).unwrap().days.len() > 15);
            }
        }
        store.refresh(true).unwrap().join().unwrap();
        assert!(store.snapshot().live_errors.is_empty());

        let regular = fetch(
            Service::OpenRouter,
            Some(&Credentials {
                key: "demo".into(),
                ..Default::default()
            }),
            chrono::Utc::now(),
        )
        .unwrap();
        assert!(regular.snapshot.balance.is_none());
        assert_eq!(
            regular
                .details
                .provider
                .unwrap()
                .history
                .unwrap()
                .days
                .values()
                .next()
                .unwrap()[""],
            0.53
        );

        let partial = fetch(
            Service::OpenCodeApi,
            Some(&Credentials {
                key: "demo-partial".into(),
                workspace: "org_demo".into(),
                ..Default::default()
            }),
            chrono::Utc::now(),
        )
        .unwrap();
        assert!(partial.snapshot.balance.is_none());
        assert!(!partial
            .details
            .provider
            .unwrap()
            .history
            .unwrap()
            .days
            .is_empty());

        let bad = Credentials {
            key: "demo-bad".into(),
            ..Default::default()
        };
        assert!(store
            .connect_provider(Service::OpenCodeGo, bad)
            .unwrap_err()
            .contains("401"));
        let limited = Credentials {
            key: "demo-limited".into(),
            ..Default::default()
        };
        let error = fetch(Service::OpenCodeGo, Some(&limited), chrono::Utc::now()).unwrap_err();
        assert_eq!(live::rate_limit_of(&error).unwrap().1, Some(15.0));

        let device = begin_open_code_sign_in().unwrap();
        assert_eq!(device.user_code, "DEMO-1234");
        let credentials = finish_open_code_sign_in(device, || false).unwrap();
        assert_eq!(credentials.workspace, "org_demo");
        store.disconnect(Service::OpenCodeApi);
        assert!(!store.snapshot().enabled.contains(&Service::OpenCodeApi));
        assert!(store.snapshot().enabled.contains(&Service::OpenCodeGo));
        assert!(store.snapshot().enabled.contains(&Service::OpenRouter));
        assert!(store.spend_history(Service::OpenRouter).is_some());
        for (service, _, _, _, _) in providers {
            store.disconnect(service);
            assert!(store.spend_history(service).is_none());
            assert!(!fixture
                .path()
                .join(format!("{}-spend.json", service.id()))
                .exists());
        }
    }

    #[test]
    fn spend_summary_keeps_missing_days_distinct_from_zero() {
        let now = time::parse_flexible("2026-11-08T15:30:00Z").unwrap();
        let mut history = SpendHistory::new("USD");
        history.days.insert("2026-11-07".into(), BTreeMap::new());
        history.add("2026-11-06", "qwen", 2.0);
        let partial = history.summary(Service::OpenCodeApi, now);
        assert_eq!(partial.today, None);
        assert_eq!(partial.yesterday, Some(0.0));
        assert_eq!(partial.month, Some(2.0));
        assert!(!partial.month_complete);
        assert!(!partial.week_complete);
        assert_eq!(partial.daily_average, Some(1.0));
        assert_eq!(partial.top_model.as_deref(), Some("qwen"));

        for day in 1..=5 {
            history.add(&format!("2026-11-0{day}"), "glm", 0.3);
        }
        let complete = history.summary(Service::OpenCodeApi, now);
        assert!(complete.month_complete);
        assert!(complete.week_complete);
        assert!((complete.daily_average.unwrap() - 0.5).abs() < 1e-8);
    }

    #[test]
    fn qwen_subscription_uses_ratios_and_keeps_zero() {
        let output = qwen_quotas(
            &json!({
                "per5Hour": { "percentage": 0.25, "resetTime": 1_800_000_000_000_i64 },
                "perWeek": { "percentage": 0 },
                "perBillMonth": {}
            }),
            true,
        );
        assert_eq!(
            output
                .iter()
                .map(|q| q.short_name.as_str())
                .collect::<Vec<_>>(),
            ["5h", "7d"]
        );
        assert_eq!(output[0].window.used_percent, 25.0);
        assert_eq!(output[0].window.resets_at, time::from_unix(1_800_000_000.0));
        assert_eq!(output[1].window.used_percent, 0.0);
        assert!(qwen_quotas(&json!({ "hasQuotaData": false }), false).is_empty());
    }

    #[test]
    fn open_code_export_and_qwen_trend_show_actual_charges() {
        let report = "day,user,provider,model,cost_micro_cents\r\n2026-11-24,\"Last, First\",opencode,qwen,25000000\r\n2026-11-24,A,opencode-go,qwen,5000000\r\n2026-11-24,A,external,qwen,100000000\r\n";
        let history = open_code_history(report).unwrap();
        assert_eq!(history.days["2026-11-24"]["qwen"], 0.30);
        let history = qwen_history(&json!({ "data": {
            "costTotals": { "currency": "USD" },
            "resultByTime": [{ "period": "20261124", "total": { "amount": "0.15" },
                "periodDetails": [{ "key": "qwen-plus", "amount": "0.10" }]
            }]
        }}))
        .unwrap();
        assert_eq!(history.days["2026-11-24"]["qwen-plus"], 0.10);
        assert!((history.days["2026-11-24"]["Other"] - 0.05).abs() < 1e-8);
    }

    #[test]
    fn replacing_a_day_does_not_double_charge_and_accounts_stay_separate() {
        let folder = tempfile::tempdir().unwrap();
        let file = folder.path().join("history.json");
        let mut first = SpendHistory::new("USD");
        first.account_scope = Some("account-a".into());
        first.add("2026-11-24", "model", 0.25);
        first.merge(&file);
        assert_eq!(first.merge(&file).days["2026-11-24"]["model"], 0.25);

        let mut second = SpendHistory::new("USD");
        second.account_scope = Some("account-b".into());
        second.add("2026-11-25", "model", 0.5);
        assert_eq!(second.merge(&file).days.len(), 1);
        assert_eq!(SpendHistory::load(&file), Some(second));
    }
}
