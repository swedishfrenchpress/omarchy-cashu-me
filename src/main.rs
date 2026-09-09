mod access;
mod diagnostics;
mod payments;
mod wallet;

use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{BufRead, Read, Write};
use std::path::PathBuf;
use std::time::Duration;
use wallet::{Session, Storage};
use zeroize::{Zeroize, Zeroizing};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    id: u64,
    method: String,
    #[serde(default)]
    password: String,
    #[serde(default)]
    url: String,
    #[serde(default)]
    path: String,
    #[serde(default)]
    backup_password: String,
    #[serde(default)]
    amount: String,
    #[serde(default)]
    text: String,
    #[serde(default)]
    review_id: String,
    #[serde(default)]
    operation_id: String,
    #[serde(default)]
    phrase: String,
    #[serde(default)]
    mint_urls: Vec<String>,
}

impl Drop for Request {
    fn drop(&mut self) {
        self.password.zeroize();
        self.backup_password.zeroize();
        self.phrase.zeroize();
        self.text.zeroize();
    }
}

fn emit(mut value: Value) {
    use base64::Engine;
    let share_text = value["result"]["token"]
        .as_str()
        .or(value["result"]["invoice"].as_str());
    if let Some(text) = share_text {
        if let Ok(code) = qrcode::QrCode::new(text.as_bytes()) {
            let svg = code
                .render::<qrcode::render::svg::Color>()
                .min_dimensions(300, 300)
                .build();
            let encoded = base64::engine::general_purpose::STANDARD.encode(svg);
            value["result"]["qr"] = Value::String(format!("data:image/svg+xml;base64,{encoded}"));
        }
    }
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    if serde_json::to_writer(&mut out, &value).is_err()
        || writeln!(out).is_err()
        || out.flush().is_err()
    {
        // A broken pipe is a failure, not a clean shutdown; report it as one.
        std::process::exit(1);
    }
}

#[tokio::main(worker_threads = 2)]
async fn main() {
    // Prevent wallet secrets from being persisted in core dumps or read through ptrace.
    unsafe {
        libc::umask(0o077);
        libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0);
        let limit = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        libc::setrlimit(libc::RLIMIT_CORE, &limit);
    }
    let directory = match std::env::var_os("CHAUMARCHY_DATA_DIR") {
        Some(path) => PathBuf::from(path),
        None => match std::env::var_os("XDG_DATA_HOME") {
            Some(path) => PathBuf::from(path).join("chaumarchy"),
            None => match std::env::var_os("HOME") {
                Some(path) => PathBuf::from(path).join(".local/share/chaumarchy"),
                None => {
                    emit(json!({"event":"fatal","error":"No wallet data directory is available."}));
                    return;
                }
            },
        },
    };
    let storage = match Storage::new(&directory) {
        Ok(value) => value,
        Err(error) => {
            emit(json!({"event":"fatal","error":error}));
            return;
        }
    };
    emit(
        json!({"event":"state","state":{"unlocked":false,"exists":storage.exists(),"password_required":storage.exists() && access::Access::new(&storage.path).password_required()}}),
    );
    let (sender, mut receiver) = tokio::sync::mpsc::channel::<Zeroizing<String>>(8);
    std::thread::spawn(move || {
        let stdin = std::io::stdin();
        let mut reader = stdin.lock();
        loop {
            let mut line = Zeroizing::new(String::new());
            match reader.by_ref().take(1_048_577).read_line(&mut line) {
                Ok(0) | Err(_) => break,
                Ok(size) if size > 1_048_576 => {
                    // Reject the request rather than ending the session. Exiting
                    // here discarded an unlocked wallet, and any payment under
                    // review with it, on a single oversized paste. The tail is
                    // drained so it cannot be read back as a further request.
                    let mut discard = Zeroizing::new(String::new());
                    let mut drained = line.ends_with('\n');
                    while !drained {
                        discard.clear();
                        match reader.by_ref().take(1_048_577).read_line(&mut discard) {
                            Ok(0) | Err(_) => return,
                            Ok(_) => drained = discard.ends_with('\n'),
                        }
                    }
                    emit(
                        json!({"id":null,"error":"That request is too large for the wallet to process."}),
                    );
                }
                Ok(_) => {
                    if sender.blocking_send(line).is_err() {
                        break;
                    }
                }
            }
        }
    });
    let mut session: Option<Session> = None;
    let mut ticker = tokio::time::interval(Duration::from_secs(30));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            line = receiver.recv() => {
                let Some(line) = line else { break; };
                let mut request = match serde_json::from_str::<Request>(&line) {
                    Ok(request) => request,
                    Err(_) => { emit(json!({"id":null,"error":"Invalid wallet request."})); continue; }
                };
                if ["send_ecash", "pay_invoice", "receive_token", "reclaim_token"].contains(&request.method.as_str()) {
                    if let Some(session) = &session {
                        let (id, result) = payments::run(session, &request, &mut receiver).await;
                        match result {
                            Ok(value) => emit(json!({"id":id,"result":value,"review_done":true})),
                            Err(error) => emit(json!({"id":id,"error":error,"review_done":true}))
                        }
                        if let Ok(state) = session.snapshot().await { emit(json!({"event":"state","state":state})); }
                    } else { emit(json!({"id":request.id,"error":"Unlock the wallet first."})); }
                    continue;
                }
                let password = Zeroizing::new(std::mem::take(&mut request.password));
                let backup_password = Zeroizing::new(std::mem::take(&mut request.backup_password));
                let phrase = Zeroizing::new(std::mem::take(&mut request.phrase));
                let result: wallet::Result<Value> = match request.method.as_str() {
                    "create" | "unlock" => {
                        if session.is_some() { Err("Wallet is already unlocked.") }
                        else {
                            let opened = if request.method == "create" { Session::create(&storage, &password).await }
                                else { Session::open(&storage, &password).await };
                            match opened {
                                Ok(opened) => { session = Some(opened); ticker.reset_immediately(); Ok(json!({})) },
                                Err(error) => Err(error)
                            }
                        }
                    }
                    "lock" => break, // Process termination discards CDK pools and their password copies.
                    "restore_backup" => {
                        if session.is_some() { Err("Lock the wallet before restoring.") }
                        else {
                            match Session::import_backup(&storage, std::path::Path::new(&request.path), &backup_password, &password).await {
                                Ok(opened) => { session = Some(opened); ticker.reset_immediately(); Ok(json!({})) },
                                Err(error) => Err(error)
                            }
                        }
                    }
                    "restore_phrase" => {
                        if session.is_some() { Err("Lock the wallet before restoring.") }
                        else {
                            match Session::restore_phrase(&storage, &password, &phrase, &request.mint_urls).await {
                                Ok(opened) => { session = Some(opened); ticker.reset_immediately(); Ok(json!({})) },
                                Err(error) => Err(error)
                            }
                        }
                    }
                    "set_password" => match session.as_mut() {
                        Some(session) => session.set_password(&password).map(|_| json!({"security_updated":true})),
                        None => Err("Open the wallet first.")
                    },
                    "remove_password" => match session.as_mut() {
                        Some(session) => session.remove_password(&password).map(|_| json!({"security_updated":true})),
                        None => Err("Open the wallet first.")
                    },
                    "recovery_phrase" => match &session {
                        Some(session) => Ok(session.recovery_phrase()),
                        None => Err("Unlock the wallet first.")
                    },
                    "export_backup" => match &session {
                        Some(session) => session.export_backup(std::path::Path::new(&request.path), &password).map(|_| json!({"backup_saved":true})),
                        None => Err("Unlock the wallet first.")
                    },
                    "create_invoice" => match &session {
                        Some(session) => session.invoice(&request.amount).await,
                        None => Err("Unlock the wallet first.")
                    },
                    "show_pending_token" => match &session {
                        Some(session) => session.pending_token(&request.operation_id).await,
                        None => Err("Unlock the wallet first.")
                    },
                    "show_invoice" => match &session {
                        Some(session) => session.saved_invoice(&request.operation_id).await,
                        None => Err("Unlock the wallet first.")
                    },
                    "sync" => match session.as_mut() {
                        Some(session) => { session.reconcile().await; Ok(json!({})) },
                        None => Err("Unlock the wallet first.")
                    },
                    "add_mint" => match session.as_mut() {
                        Some(session) => session.add_mint(&request.url).await.map(|_| json!({"mint_added":true})),
                        None => Err("Unlock the wallet first.")
                    },
                    "select_mint" => match session.as_mut() {
                        Some(session) => session.select_mint(&request.url).map(|_| json!({})),
                        None => Err("Unlock the wallet first.")
                    },
                    "status" => Ok(json!({})),
                    _ => Err("This wallet operation is not implemented yet.")
                };
                match result {
                    Ok(value) => emit(json!({"id":request.id,"result":value})),
                    Err(error) => emit(json!({"id":request.id,"error":error}))
                }
                if let Some(session) = &session {
                    match session.snapshot().await {
                        Ok(state) => emit(json!({"event":"state","state":state})),
                        Err(error) => emit(json!({"event":"error","error":error}))
                    }
                }
            }
            _ = ticker.tick(), if session.is_some() => {
                if let Some(session) = session.as_mut() {
                    session.reconcile().await;
                    if let Ok(state) = session.snapshot().await { emit(json!({"event":"state","state":state})); }
                }
            }
        }
    }
}
