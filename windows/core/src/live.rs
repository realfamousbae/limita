//! What the network clients share: the HTTP agent and how a 429 travels to the store.
//!
//! A client's errors are plain strings the user reads. A rate limit carries a tag the
//! store strips again (`rate_limit_of`), so it can back off from that service and show
//! only the message.

const TAG: &str = " [429";
const RETRY_AFTER: &str = ", retry after ";

/// HTTPS through the system's TLS (SChannel on Windows), so the system's certificates
/// and any corporate root CA are trusted.
pub fn agent() -> Result<ureq::Agent, String> {
    let tls = native_tls::TlsConnector::new().map_err(|error| format!("Could not set up TLS: {error}"))?;
    Ok(ureq::AgentBuilder::new().tls_connector(std::sync::Arc::new(tls)).build())
}

/// The error for a 429: `message` for the user, with the server's `Retry-After` in seconds
/// when it named one.
pub fn rate_limited(message: &str, retry_after: Option<f64>) -> String {
    match retry_after {
        Some(seconds) => format!("{message}{TAG}{RETRY_AFTER}{seconds}]"),
        None => format!("{message}{TAG}]"),
    }
}

/// The message and the wait of an error made by `rate_limited`, `None` for any other.
pub fn rate_limit_of(error: &str) -> Option<(&str, Option<f64>)> {
    let (message, tag) = error.rsplit_once(TAG)?;
    let tag = tag.strip_suffix(']')?;
    if tag.is_empty() {
        return Some((message, None));
    }
    Some((message, tag.strip_prefix(RETRY_AFTER)?.parse().ok()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rate_limits_carry_the_message_and_the_wait() {
        let error = rate_limited("DeepSeek is rate-limiting balance requests", Some(90.0));
        assert_eq!(rate_limit_of(&error), Some(("DeepSeek is rate-limiting balance requests", Some(90.0))));
        assert_eq!(rate_limit_of(&rate_limited("Busy", None)), Some(("Busy", None)));
        assert_eq!(rate_limit_of("DeepSeek balance API returned 500"), None);
        assert_eq!(rate_limit_of("A [bracket] in a message"), None);
    }
}
