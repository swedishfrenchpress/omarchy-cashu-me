//! Hold CDK's prepared operation across explicit review. Reconciliation pauses
//! during review so it cannot cancel the operation awaiting confirmation.
use crate::wallet::{parse_amount, Result, Session};
use crate::{emit, Request};
use cdk::nuts::{CurrencyUnit, PaymentMethod, Token};
use cdk::wallet::{ReceiveOptions, SendOptions};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::str::FromStr;
use std::time::Duration;
use tokio::sync::mpsc::Receiver;
use zeroize::Zeroizing;

async fn decision(
    id: u64,
    review: Value,
    receiver: &mut Receiver<Zeroizing<String>>,
) -> (u64, bool) {
    emit(json!({"id":id,"result":{"review":review,"review_id":id.to_string()}}));
    let deadline = tokio::time::Instant::now() + Duration::from_secs(300);
    loop {
        let line = match tokio::time::timeout_at(deadline, receiver.recv()).await {
            Ok(Some(line)) => line,
            _ => return (id, false),
        };
        let request: Request = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(_) => {
                emit(json!({"id":null,"error":"Invalid review response."}));
                continue;
            }
        };
        if request.method == "lock" {
            std::process::exit(0);
        }
        if request.review_id == id.to_string() {
            if request.method == "confirm_payment" {
                return (request.id, true);
            }
            if request.method == "cancel_payment" {
                return (request.id, false);
            }
        }
        emit(
            json!({"id":request.id,"error":"Confirm or cancel the current payment review first."}),
        );
    }
}

pub async fn run(
    session: &Session,
    request: &Request,
    receiver: &mut Receiver<Zeroizing<String>>,
) -> (u64, Result<Value>) {
    let mut reply_id = request.id;
    let result = async {
        match request.method.as_str() {
            "send_ecash" => {
                let amount = parse_amount(&request.amount)?;
                let wallet = session.selected_wallet()?;
                let prepared = wallet.prepare_send(amount, SendOptions::default()).await
                    .map_err(|_| "Cannot prepare this send. Check available balance, fees, and mint connectivity.")?;
                let operation_id = prepared.operation_id().to_string();
                let review = json!({"kind":"Send ecash","mint":wallet.mint_url.to_string(),
                    "amount":amount.to_string(),"fee":prepared.fee().to_string(),"total":(amount + prepared.fee()).to_string()});
                let (id, confirmed) = decision(request.id, review, receiver).await;
                reply_id = id;
                if !confirmed {
                    prepared.cancel().await.map_err(|_| "Cancellation needs reconciliation. Funds remain reserved until checked.")?;
                    return Ok(json!({"cancelled":true}));
                }
                let token = prepared.confirm(None).await
                    .map_err(|_| "Send outcome needs reconciliation. Check history and pending transfers before retrying.")?;
                Ok(json!({"token":token.to_string(),"amount":amount.to_string(),"operation_id":operation_id,"mint":wallet.mint_url.to_string()}))
            }
            "pay_invoice" => {
                let wallet = session.selected_wallet()?;
                let invoice = request.text.trim().strip_prefix("lightning:").unwrap_or(request.text.trim());
                let quote = wallet.melt_quote(PaymentMethod::BOLT11, invoice, None, None).await
                    .map_err(|_| "Cannot quote this invoice. Check its validity, expiry, and mint availability.")?;
                let prepared = wallet.prepare_melt(&quote.id, HashMap::new()).await
                    .map_err(|_| "Cannot reserve funds for this invoice. Check available balance and fees.")?;
                let fee = prepared.total_fee() + quote.fee_reserve;
                let review = json!({"kind":"Pay Lightning invoice","mint":wallet.mint_url.to_string(),
                    "amount":quote.amount.to_string(),"fee":fee.to_string(),"total":(quote.amount+fee).to_string(),"expiry":quote.expiry});
                let (id, confirmed) = decision(request.id, review, receiver).await;
                reply_id = id;
                if !confirmed {
                    prepared.cancel().await.map_err(|_| "Cancellation needs reconciliation. Funds remain reserved until checked.")?;
                    return Ok(json!({"cancelled":true}));
                }
                let paid = tokio::time::timeout(Duration::from_secs(90), prepared.confirm()).await
                    .map_err(|_| "Payment is unresolved. Background reconciliation will check its outcome; do not pay it again.")?
                    .map_err(|_| "Payment did not complete normally. Check history while the wallet reconciles its outcome.")?;
                if paid.state() != cdk::nuts::MeltQuoteState::Paid { return Err("Payment is not confirmed paid. Wait for reconciliation."); }
                Ok(json!({"paid":true,"amount":quote.amount.to_string(),"fee":paid.fee_paid().to_string()}))
            }
            "receive_token" => {
                let token = Token::from_str(request.text.trim()).map_err(|_| "This is not a supported Cashu token.")?;
                if token.unit().unwrap_or_default() != CurrencyUnit::Sat { return Err("This version accepts tokens denominated in sats."); }
                let mint_url = token.mint_url().map_err(|_| "This token contains an unsupported mint configuration.")?.to_string();
                let wallet = session.wallet_for(&mint_url)?;
                let amount = token.value().map_err(|_| "Cannot read token amount.")?;
                let review = json!({"kind":"Receive ecash","mint":mint_url,"amount":amount.to_string(),"receiving":true});
                let (id, confirmed) = decision(request.id, review, receiver).await;
                reply_id = id;
                if !confirmed { return Ok(json!({"cancelled":true})); }
                let received = wallet.receive(request.text.trim(), ReceiveOptions::default()).await
                    .map_err(|_| "Token could not be redeemed. It may be spent, unsupported, or awaiting mint reconciliation.")?;
                Ok(json!({"received":true,"amount":received.to_string()}))
            }
            "reclaim_token" => {
                let wallet = session.selected_wallet()?;
                let operation_id = request.operation_id.parse().map_err(|_| "Invalid transfer reference.")?;
                let review = json!({"kind":"Reclaim unspent ecash","mint":wallet.mint_url.to_string(),"reclaim":true});
                let (id, confirmed) = decision(request.id, review, receiver).await;
                reply_id = id;
                if !confirmed { return Ok(json!({"cancelled":true})); }
                let amount = wallet.revoke_send(operation_id).await
                    .map_err(|_| "Cannot reclaim this token. It may already be spent; the wallet will reconcile its status.")?;
                Ok(json!({"reclaimed":true,"amount":amount.to_string()}))
            }
            _ => Err("Unknown payment operation.")
        }
    }.await;
    (reply_id, result)
}
