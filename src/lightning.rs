//! Settings → Payments → Lightning: an npub.cash Lightning address, after
//! cashubtc/wallet. CDK implements the protocol (a Nostr keypair derived
//! from the seed signs requests to the server; paid invoices become mint
//! quotes at the receiving mint). This module only decides when to call it
//! and reports where it stands. No relay is ever contacted.
use crate::diagnostics::note;
use crate::wallet::{now, Result, Session};
use nostr_sdk::prelude::ToBech32;
use serde_json::{json, Value};
use std::time::Duration;

/// The same server the reference wallet uses; the address domain follows.
const NPUBCASH_URL: &str = "https://npubx.cash";

const SETUP_FAILED: &str = "Lightning address setup couldn't finish. Try again or restart the app.";

impl Session {
    /// `<npub>@npubx.cash`. The key comes from the seed alone, so the
    /// address is the same at every mint and after every restore.
    pub fn lightning_address(&self) -> Option<String> {
        let wallet = self.wallets.values().next()?;
        let keys = wallet.get_npubcash_keys().ok()?;
        let npub = keys.public_key().to_bech32().ok()?;
        let domain = url::Url::parse(NPUBCASH_URL).ok()?.host_str()?.to_owned();
        Some(format!("{npub}@{domain}"))
    }

    /// Registers the receiving mint with the server and turns on quote
    /// locking. Runs after every unlock, and again after the mint changes.
    pub async fn connect_lightning(&mut self) {
        self.lightning_ready = false;
        let Some(mint) = self.settings.lightning.mint.clone() else {
            self.lightning_error = Some("Choose a receiving mint.");
            return;
        };
        let Some(wallet) = self.wallets.get(&mint) else {
            self.lightning_error = Some("The receiving mint is no longer in this wallet.");
            return;
        };
        match tokio::time::timeout(
            Duration::from_secs(20),
            wallet.enable_npubcash(NPUBCASH_URL.to_owned()),
        )
        .await
        {
            Ok(Ok(())) => {
                self.lightning_ready = true;
                self.lightning_error = None;
            }
            Ok(Err(error)) => {
                note("enable_npubcash", &error);
                self.lightning_error = Some(SETUP_FAILED);
            }
            Err(_) => self.lightning_error = Some("npub.cash did not respond in time."),
        }
    }

    pub async fn set_lightning(
        &mut self,
        enabled: bool,
        auto_claim: bool,
        mint: Option<String>,
    ) -> Result<()> {
        let mint = match mint {
            Some(url) if !url.trim().is_empty() => {
                let url = url.trim().to_owned();
                if !self.wallets.contains_key(&url) {
                    return Err("Add this mint before receiving to it.");
                }
                Some(url)
            }
            _ => self
                .settings
                .lightning
                .mint
                .clone()
                .or_else(|| self.settings.selected.clone()),
        };
        if enabled && mint.is_none() {
            return Err("Add a mint first to use a Lightning address.");
        }
        let mint_changed = mint != self.settings.lightning.mint;
        let previous = self.settings.lightning.clone();
        self.settings.lightning.enabled = enabled;
        self.settings.lightning.auto_claim = auto_claim;
        self.settings.lightning.mint = mint;
        if let Err(error) = self.save_settings() {
            self.settings.lightning = previous;
            return Err(error);
        }
        if enabled && (!self.lightning_ready || mint_changed) {
            self.connect_lightning().await;
            if let Some(error) = self.lightning_error {
                return Err(error);
            }
        }
        if !enabled {
            self.lightning_ready = false;
            self.lightning_error = None;
        }
        Ok(())
    }

    /// "Check for payments": pull paid invoices from the server and mint
    /// them. Also what auto-claim runs on each reconciliation.
    pub async fn claim_lightning(&mut self) -> Result<Value> {
        if !self.settings.lightning.enabled {
            return Err("Enable your Lightning address first.");
        }
        if !self.settings.privacy.check_incoming {
            return Err(
                "To check for payments, allow incoming invoice checks in Privacy settings.",
            );
        }
        if !self.lightning_ready {
            self.connect_lightning().await;
        }
        if let Some(error) = self.lightning_error {
            return Err(error);
        }
        let mint = self
            .settings
            .lightning
            .mint
            .clone()
            .ok_or("Choose a receiving mint.")?;
        let wallet = self
            .wallets
            .get(&mint)
            .ok_or("The receiving mint is no longer in this wallet.")?;
        let claimed =
            match tokio::time::timeout(Duration::from_secs(60), wallet.claim_npubcash_quotes())
                .await
            {
                Ok(Ok(amount)) => amount,
                Ok(Err(error)) => {
                    note("claim_npubcash_quotes", &error);
                    return Err("Could not check for payments. Try again in a moment.");
                }
                Err(_) => return Err("Checking for payments timed out."),
            };
        self.settings.lightning.last_checked = Some(now());
        let _ = self.save_settings();
        Ok(json!({"claimed": claimed.to_string()}))
    }

    pub fn lightning_state(&self) -> Value {
        let lightning = &self.settings.lightning;
        let status = if !lightning.enabled {
            "off"
        } else if self.lightning_error.is_some() {
            "error"
        } else if self.lightning_ready {
            "connected"
        } else {
            "connecting"
        };
        json!({"enabled": lightning.enabled, "auto_claim": lightning.auto_claim, "mint": lightning.mint,
            "last_checked": lightning.last_checked, "status": status, "error": self.lightning_error,
            "address": if lightning.enabled { self.lightning_address() } else { None }})
    }
}
