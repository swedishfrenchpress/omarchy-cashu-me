//! Hold CDK's prepared operation across explicit review. Reconciliation pauses
//! during review so it cannot cancel the operation awaiting confirmation.
use crate::diagnostics::note;
use crate::wallet::{parse_amount, Result, Session};
use crate::{emit, Request};
use cdk::nuts::{CurrencyUnit, PaymentMethod, SpendingConditions, Token};
use cdk::wallet::{ReceiveOptions, SendOptions};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::str::FromStr;
use std::time::Duration;
use tokio::sync::mpsc::Receiver;
use zeroize::Zeroizing;

/// CDK bounds a mint request only when that mint advertises a NUT-19 cache
/// window, so every call needs its own timeout here. The worker handles one
/// request at a time; an unresponsive mint would otherwise freeze the wallet
/// with no way to cancel from the interface.
async fn bounded<T, E: std::fmt::Display>(
    context: &str,
    seconds: u64,
    timed_out: &'static str,
    failed: &'static str,
    future: impl std::future::Future<Output = std::result::Result<T, E>>,
) -> Result<T> {
    match tokio::time::timeout(Duration::from_secs(seconds), future).await {
        Err(_) => {
            note(context, &format!("timed out after {seconds}s"));
            Err(timed_out)
        }
        Ok(Err(error)) => {
            note(context, &error);
            Err(failed)
        }
        Ok(Ok(value)) => Ok(value),
    }
}

/// `None` means the desktop locked while the review was on screen. The caller
/// releases any reservation it holds before the process exits.
async fn decision(
    id: u64,
    review: Value,
    receiver: &mut Receiver<Zeroizing<String>>,
) -> Option<(u64, bool)> {
    emit(json!({"id":id,"result":{"review":review,"review_id":id.to_string()}}));
    let deadline = tokio::time::Instant::now() + Duration::from_secs(300);
    loop {
        let line = match tokio::time::timeout_at(deadline, receiver.recv()).await {
            Ok(Some(line)) => line,
            _ => return Some((id, false)),
        };
        let request: Request = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(_) => {
                emit(json!({"id":null,"error":"Invalid review response."}));
                continue;
            }
        };
        if request.method == "lock" {
            return None;
        }
        if request.review_id == id.to_string() {
            if request.method == "confirm_payment" {
                return Some((request.id, true));
            }
            if request.method == "cancel_payment" {
                return Some((request.id, false));
            }
        }
        emit(
            json!({"id":request.id,"error":"Confirm or cancel the current payment review first."}),
        );
    }
}

pub async fn run(
    session: &mut Session,
    request: &Request,
    receiver: &mut Receiver<Zeroizing<String>>,
) -> (u64, Result<Value>) {
    let mut reply_id = request.id;
    let result = async {
        match request.method.as_str() {
            "send_ecash" => {
                let amount = parse_amount(&request.amount)?;
                let wallet = session.selected_wallet()?;
                // Locked Ecash: a non-empty lock_to ties the token to that key
                // (NUT-11 P2PK), so only its holder can claim it.
                let lock_to = request.lock_to.trim();
                let conditions = if lock_to.is_empty() { None } else {
                    Some(SpendingConditions::P2PKConditions { data: crate::locked::parse_lock_key(lock_to)?, conditions: None })
                };
                let options = SendOptions { conditions, p2pk_signing_keys: session.signing_keys(), ..SendOptions::default() };
                let prepared = bounded("prepare_send", 30,
                    "Preparing this send timed out. Check history and pending transfers before retrying.",
                    "Cannot prepare this send. Check available balance, fees, and mint connectivity.",
                    wallet.prepare_send(amount, options)).await?;
                let operation_id = prepared.operation_id().to_string();
                let review = json!({"kind":"Send ecash","mint":wallet.mint_url.to_string(),
                    "amount":amount.to_string(),"fee":prepared.fee().to_string(),"total":(amount + prepared.fee()).to_string(),
                    "locked_to": if lock_to.is_empty() { Value::Null } else { Value::String(lock_to.to_owned()) }});
                let Some((id, confirmed)) = decision(request.id, review, receiver).await else {
                    // Release the reservation before locking rather than leaving
                    // it stranded until the next reconciliation.
                    let _ = tokio::time::timeout(Duration::from_secs(10), prepared.cancel()).await;
                    std::process::exit(0);
                };
                reply_id = id;
                if !confirmed {
                    bounded("send cancel", 15,
                        "Cancellation needs reconciliation. Funds remain reserved until checked.",
                        "Cancellation needs reconciliation. Funds remain reserved until checked.",
                        prepared.cancel()).await?;
                    return Ok(json!({"cancelled":true}));
                }
                let mint = wallet.mint_url.to_string();
                let fee = prepared.fee().to_string();
                let token = prepared.confirm(None).await.map_err(|error| {
                    note("send confirm", &error);
                    "Send outcome needs reconciliation. Check history and pending transfers before retrying."
                })?;
                if !lock_to.is_empty() { session.note_key_used(lock_to); }
                Ok(json!({"token":token.to_string(),"amount":amount.to_string(),"fee":fee,"operation_id":operation_id,"mint":mint}))
            }
            "pay_invoice" => {
                let wallet = session.selected_wallet()?;
                let invoice = request.text.trim().strip_prefix("lightning:").unwrap_or(request.text.trim());
                let quote = bounded("melt_quote", 30,
                    "Quoting this invoice timed out. Check the mint's availability before retrying.",
                    "Cannot quote this invoice. Check its validity, expiry, and mint availability.",
                    wallet.melt_quote(PaymentMethod::BOLT11, invoice, None, None)).await?;
                let prepared = bounded("prepare_melt", 30,
                    "Reserving funds for this invoice timed out. Check history before retrying.",
                    "Cannot reserve funds for this invoice. Check available balance and fees.",
                    wallet.prepare_melt(&quote.id, HashMap::new())).await?;
                let fee = prepared.total_fee() + quote.fee_reserve;
                let review = json!({"kind":"Pay Lightning invoice","mint":wallet.mint_url.to_string(),
                    "amount":quote.amount.to_string(),"fee":fee.to_string(),"total":(quote.amount+fee).to_string(),"expiry":quote.expiry});
                let Some((id, confirmed)) = decision(request.id, review, receiver).await else {
                    let _ = tokio::time::timeout(Duration::from_secs(10), prepared.cancel()).await;
                    std::process::exit(0);
                };
                reply_id = id;
                if !confirmed {
                    bounded("melt cancel", 15,
                        "Cancellation needs reconciliation. Funds remain reserved until checked.",
                        "Cancellation needs reconciliation. Funds remain reserved until checked.",
                        prepared.cancel()).await?;
                    return Ok(json!({"cancelled":true}));
                }
                let paid = bounded("melt confirm", 90,
                    "Payment is unresolved. Background reconciliation will check its outcome; do not pay it again.",
                    "Payment did not complete normally. Check history while the wallet reconciles its outcome.",
                    prepared.confirm()).await?;
                if paid.state() != cdk::nuts::MeltQuoteState::Paid {
                    note("melt confirm", &format!("mint reported state {:?}", paid.state()));
                    return Err("Payment is not confirmed paid. Wait for reconciliation.");
                }
                Ok(json!({"paid":true,"amount":quote.amount.to_string(),"fee":paid.fee_paid().to_string()}))
            }
            "receive_token" => {
                let token = Token::from_str(request.text.trim()).map_err(|_| "This is not a supported Cashu token.")?;
                if token.unit().unwrap_or_default() != CurrencyUnit::Sat { return Err("This version accepts tokens denominated in sats."); }
                let mint_url = token.mint_url().map_err(|_| "This token contains an unsupported mint configuration.")?.to_string();
                let wallet = session.wallet_for(&mint_url)?;
                let amount = token.value().map_err(|_| "Cannot read token amount.")?;
                // Locked ecash is checked against this wallet's keys before the
                // mint is ever contacted, as the reference wallet does.
                let keysets = bounded("keysets", 20,
                    "This mint did not answer in time. Try again in a moment.",
                    "Cannot read this mint's keysets.",
                    wallet.keysets(cdk::wallet::types::KeysetLoadPolicy::CacheThenNetwork)).await?;
                let keysets: Vec<cdk::nuts::KeySetInfo> = keysets.into_iter().map(|keyset| cdk::nuts::KeySetInfo {
                    id: keyset.id, unit: keyset.unit, active: keyset.active.unwrap_or(true),
                    input_fee_ppk: keyset.input_fee_ppk, final_expiry: keyset.final_expiry,
                }).collect();
                let proofs = token.proofs(&keysets).map_err(|_| "This token contains an unsupported mint configuration.")?;
                let lock_keys = crate::locked::lock_keys_in(&proofs);
                let locked_to = lock_keys.first().map(|key| session.describe_key(key));
                if !lock_keys.is_empty() && !lock_keys.iter().any(|key| session.holds_key(key)) {
                    return Err("This ecash is locked to a key you don't hold. Ask the sender to lock it to your key instead.");
                }
                let review = json!({"kind":"Receive ecash","mint":mint_url,"amount":amount.to_string(),"receiving":true,"locked_to":locked_to});
                let Some((id, confirmed)) = decision(request.id, review, receiver).await else {
                    std::process::exit(0);
                };
                reply_id = id;
                if !confirmed { return Ok(json!({"cancelled":true})); }
                // Every key this wallet holds signs, so a token locked to the
                // seed key or a device key redeems like any other.
                let options = ReceiveOptions { p2pk_signing_keys: session.signing_keys(), ..ReceiveOptions::default() };
                let received = bounded("receive", 60,
                    "Receiving is unresolved. Background reconciliation will check its outcome; do not redeem this token again.",
                    "Token could not be redeemed. It may be spent, locked to a key you don't hold, or awaiting mint reconciliation.",
                    wallet.receive(request.text.trim(), options)).await?;
                for key in &lock_keys { session.note_key_used(key); }
                Ok(json!({"received":true,"amount":received.to_string()}))
            }
            "reclaim_token" => {
                // Resolve the transfer's own mint: unclaimed ecash is reclaimable
                // whichever mint happens to be selected.
                let wallet = session.wallet_for_operation(&request.operation_id).await?;
                let operation_id = request.operation_id.parse().map_err(|_| "Invalid transfer reference.")?;
                // No review: taking back one's own unclaimed ecash needs no
                // second look, and the reference offers none.
                let amount = bounded("revoke_send", 30,
                    "Reclaim is unresolved. The wallet will reconcile this transfer's status.",
                    "Cannot reclaim this token. It may already be spent; the wallet will reconcile its status.",
                    wallet.revoke_send(operation_id)).await?;
                session.note_reclaimed(operation_id);
                Ok(json!({"reclaimed":true,"amount":amount.to_string()}))
            }
            _ => Err("Unknown payment operation.")
        }
    }.await;
    (reply_id, result)
}
