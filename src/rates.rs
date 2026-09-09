//! Local-currency display is a convenience layer over sat amounts, not a
//! wallet capability: Chaumarchy holds and moves sats only, and every mint
//! call stays denominated in sats regardless of what this module returns.
//! A failure here must never surface as a wallet error or block a payment;
//! callers treat it as "no rate yet" and keep showing sats.

use std::collections::BTreeMap;
use std::time::Duration;

use serde_json::Value;

/// Currencies offered in Settings → Display. A fixed, reviewed list, rather
/// than an arbitrary string, is what keeps a typo or a hostile paste from
/// ever reaching the price request. The flag is decorative, as in cashu.me's
/// own currency picker; it is not a claim about where a currency is legal
/// tender.
pub const CURRENCIES: &[(&str, &str, &str, &str)] = &[
    ("USD", "US Dollar", "$", "🇺🇸"),
    ("EUR", "Euro", "€", "🇪🇺"),
    ("GBP", "British Pound", "£", "🇬🇧"),
    ("JPY", "Japanese Yen", "¥", "🇯🇵"),
    ("CHF", "Swiss Franc", "Fr", "🇨🇭"),
    ("CAD", "Canadian Dollar", "$", "🇨🇦"),
    ("AUD", "Australian Dollar", "$", "🇦🇺"),
    ("CNY", "Chinese Yuan", "¥", "🇨🇳"),
    ("INR", "Indian Rupee", "₹", "🇮🇳"),
    ("BRL", "Brazilian Real", "R$", "🇧🇷"),
    ("MXN", "Mexican Peso", "$", "🇲🇽"),
    ("KRW", "South Korean Won", "₩", "🇰🇷"),
];

pub fn is_supported(code: &str) -> bool {
    CURRENCIES.iter().any(|(c, _, _, _)| *c == code)
}

pub fn catalog() -> Value {
    serde_json::json!(CURRENCIES
        .iter()
        .map(|(code, name, symbol, flag)| {
            serde_json::json!({"code": code, "name": name, "symbol": symbol, "flag": flag})
        })
        .collect::<Vec<_>>())
}

/// Fetches every supported currency's BTC spot price in a single request,
/// so switching the selected currency in Settings never needs a new fetch.
/// Bounded like every other network call this worker makes; the caller
/// decides how often it is worth repeating.
pub async fn fetch_rates() -> Result<BTreeMap<String, f64>, &'static str> {
    let request = bitreq::get("https://api.coinbase.com/v2/exchange-rates?currency=BTC");
    let response = tokio::time::timeout(Duration::from_secs(10), request.send_async())
        .await
        .map_err(|_| "Exchange rate request timed out.")?
        .map_err(|_| "Exchange rate request failed.")?;
    let body = response
        .as_str()
        .map_err(|_| "Exchange rate response was not readable text.")?;
    let value: Value =
        serde_json::from_str(body).map_err(|_| "Exchange rate response was not valid JSON.")?;
    let rates = value["data"]["rates"]
        .as_object()
        .ok_or("Exchange rate response was missing rates.")?;
    let mut out = BTreeMap::new();
    for (code, _, _, _) in CURRENCIES {
        if let Some(rate) = rates
            .get(*code)
            .and_then(Value::as_str)
            .and_then(|text| text.parse::<f64>().ok())
            .filter(|rate| rate.is_finite() && *rate > 0.0)
        {
            out.insert((*code).to_owned(), rate);
        }
    }
    if out.is_empty() {
        return Err("Exchange rate response had no usable rates.");
    }
    Ok(out)
}
