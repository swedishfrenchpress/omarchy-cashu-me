//! Settings → Payments → Locked Ecash (NUT-11 P2PK), after cashubtc/wallet.
//!
//! "Your key" is the NIP-06 key derived from the seed, the same key the
//! reference wallet uses, so a phrase restored there receives to the same
//! key. Device keys are random or imported secp256k1 keys kept only in
//! this encrypted database. Sending can lock a token to any key; receiving
//! signs with every key this wallet holds.
use crate::wallet::{DeviceKey, Result, Session};
use cdk::nuts::{Proofs, PublicKey, SecretKey};
use nostr_sdk::prelude::{FromBech32, ToBech32};
use serde_json::{json, Value};
use zeroize::Zeroizing;

const NOT_AN_NSEC: &str = "That doesn't look like an nsec key. It should start with “nsec1”.";
pub const NOT_A_KEY: &str = "That key isn't valid. Use a 66-character hex key (02/03 prefix).";

/// The reference wallet identifies a key as `02` + its x-only public key.
/// Schnorr verification ignores the parity byte, so this is claimable with
/// the key whichever parity its full public key has.
fn lock_pubkey(secret: &SecretKey) -> String {
    format!("02{}", &secret.public_key().to_hex()[2..])
}

/// A recipient key as typed or pasted, with the reference wallet's rules:
/// bare x-only hex gets the `02` prefix, otherwise 66 hex characters with
/// an `02`/`03` prefix. npub and `nostr:` forms are not accepted.
pub fn parse_lock_key(input: &str) -> Result<PublicKey> {
    let hex = input.trim().to_ascii_lowercase();
    let hex = match hex.len() {
        64 => format!("02{hex}"),
        66 if hex.starts_with("02") || hex.starts_with("03") => hex,
        _ => return Err(NOT_A_KEY),
    };
    PublicKey::from_hex(hex).map_err(|_| NOT_A_KEY)
}

/// Two keys are the same key whatever parity byte they were written with.
fn same_key(a: &str, b: &str) -> bool {
    a.len() >= 64 && b.len() >= 64 && a[a.len() - 64..].eq_ignore_ascii_case(&b[b.len() - 64..])
}

/// The P2PK keys a token's proofs are locked to, if any. Proofs without a
/// NUT-10 secret are plain ecash and are skipped.
pub fn lock_keys_in(proofs: &Proofs) -> Vec<String> {
    let mut keys = Vec::new();
    for proof in proofs.iter() {
        let Ok(secret) = cdk::nuts::nut10::Secret::try_from(proof.secret.clone()) else {
            continue;
        };
        if secret.kind() == cdk::nuts::Kind::P2PK {
            let key = secret.secret_data().data().to_owned();
            if !keys.contains(&key) {
                keys.push(key);
            }
        }
    }
    keys
}

impl Session {
    pub(crate) fn seed_key(&self) -> Result<SecretKey> {
        let seed = Zeroizing::new(self.mnemonic.to_seed_normalized(""));
        cdk::wallet::derive_npubcash_secret_key_from_seed(&seed)
            .map_err(|_| "Cannot derive your key.")
    }

    /// Every key that can claim locked ecash for this wallet.
    pub(crate) fn signing_keys(&self) -> Vec<SecretKey> {
        let mut keys = Vec::new();
        if let Ok(key) = self.seed_key() {
            keys.push(key);
        }
        for device in &self.settings.locked.device_keys {
            if let Ok(key) = SecretKey::from_hex(&device.secret) {
                keys.push(key);
            }
        }
        keys
    }

    fn device_key(&self, id: &str) -> Result<&DeviceKey> {
        self.settings
            .locked
            .device_keys
            .iter()
            .find(|key| key.id == id)
            .ok_or("This key is no longer on this device.")
    }

    /// Whether this wallet can claim ecash locked to `pubkey`.
    pub fn holds_key(&self, pubkey: &str) -> bool {
        self.seed_key()
            .ok()
            .is_some_and(|key| same_key(&lock_pubkey(&key), pubkey))
            || self
                .settings
                .locked
                .device_keys
                .iter()
                .any(|key| same_key(&key.pubkey, pubkey))
    }

    /// "Your key" for the seed key, a device key's name, or the short hex.
    pub fn describe_key(&self, pubkey: &str) -> String {
        if self
            .seed_key()
            .ok()
            .is_some_and(|key| same_key(&lock_pubkey(&key), pubkey))
        {
            return "Your key".to_owned();
        }
        if let Some(key) = self
            .settings
            .locked
            .device_keys
            .iter()
            .find(|key| same_key(&key.pubkey, pubkey))
        {
            if !key.nickname.is_empty() {
                return key.nickname.clone();
            }
        }
        if pubkey.len() > 20 {
            format!("{}…{}", &pubkey[..10], &pubkey[pubkey.len() - 8..])
        } else {
            pubkey.to_owned()
        }
    }

    /// A device key was used to send or receive locked ecash; the
    /// reference wallet counts these so the list can say "Used 3 times".
    pub fn note_key_used(&mut self, pubkey: &str) {
        if let Some(key) = self
            .settings
            .locked
            .device_keys
            .iter_mut()
            .find(|key| same_key(&key.pubkey, pubkey))
        {
            key.used_count += 1;
            let _ = self.save_settings();
        }
    }

    pub fn locked_state(&self) -> Value {
        let seed_key = self.seed_key().ok().map(|key| lock_pubkey(&key));
        let device_keys: Vec<Value> = self
            .settings
            .locked
            .device_keys
            .iter()
            .map(|key| {
                json!({"id": key.id, "nickname": key.nickname, "pubkey": key.pubkey, "used_count": key.used_count})
            })
            .collect();
        json!({"seed_key": seed_key, "quick_lock": self.settings.locked.quick_lock, "device_keys": device_keys})
    }

    pub fn set_quick_lock(&mut self, on: bool) -> Result<()> {
        let previous = self.settings.locked.quick_lock;
        self.settings.locked.quick_lock = on;
        if let Err(error) = self.save_settings() {
            self.settings.locked.quick_lock = previous;
            return Err(error);
        }
        Ok(())
    }

    pub fn generate_device_key(&mut self) -> Result<Value> {
        self.add_device_key(SecretKey::generate())
    }

    pub fn import_device_key(&mut self, input: &str) -> Result<Value> {
        let input = input.trim();
        let hex = if input.starts_with("nsec1") {
            nostr_sdk::SecretKey::from_bech32(input)
                .map_err(|_| NOT_AN_NSEC)?
                .to_secret_hex()
        } else if input.len() == 64 {
            input.to_ascii_lowercase()
        } else {
            return Err(NOT_AN_NSEC);
        };
        let secret = SecretKey::from_hex(Zeroizing::new(hex).as_str()).map_err(|_| NOT_AN_NSEC)?;
        self.add_device_key(secret)
    }

    fn add_device_key(&mut self, secret: SecretKey) -> Result<Value> {
        let pubkey = lock_pubkey(&secret);
        if self.seed_key().ok().map(|key| lock_pubkey(&key)) == Some(pubkey.clone()) {
            return Err("This is already your key.");
        }
        if self
            .settings
            .locked
            .device_keys
            .iter()
            .any(|key| key.pubkey == pubkey)
        {
            return Err("This key is already on this device.");
        }
        let id = pubkey[2..18].to_owned();
        self.settings.locked.device_keys.push(DeviceKey {
            id: id.clone(),
            nickname: String::new(),
            pubkey,
            secret: secret.to_secret_hex(),
            used_count: 0,
        });
        if let Err(error) = self.save_settings() {
            self.settings.locked.device_keys.pop();
            return Err(error);
        }
        Ok(json!({"key_added": id}))
    }

    pub fn rename_device_key(&mut self, id: &str, nickname: &str) -> Result<()> {
        let nickname: String = nickname
            .chars()
            .filter(|character| !character.is_control())
            .take(60)
            .collect();
        let index = self
            .settings
            .locked
            .device_keys
            .iter()
            .position(|key| key.id == id)
            .ok_or("This key is no longer on this device.")?;
        let previous = std::mem::replace(
            &mut self.settings.locked.device_keys[index].nickname,
            nickname,
        );
        if let Err(error) = self.save_settings() {
            self.settings.locked.device_keys[index].nickname = previous;
            return Err(error);
        }
        Ok(())
    }

    pub fn remove_device_key(&mut self, id: &str) -> Result<()> {
        let index = self
            .settings
            .locked
            .device_keys
            .iter()
            .position(|key| key.id == id)
            .ok_or("This key is no longer on this device.")?;
        let removed = self.settings.locked.device_keys.remove(index);
        if let Err(error) = self.save_settings() {
            self.settings.locked.device_keys.insert(index, removed);
            return Err(error);
        }
        Ok(())
    }

    /// The private key as an nsec, for "Reveal key" and "Back up key".
    /// Asks for the wallet password first when App Lock is on.
    pub fn reveal_key(&self, id: &str, password: &str) -> Result<Value> {
        self.confirm_password(password)?;
        let secret = if id.is_empty() {
            self.seed_key()?
        } else {
            SecretKey::from_hex(&self.device_key(id)?.secret)
                .map_err(|_| "This key's private key is unavailable.")?
        };
        let hex = Zeroizing::new(secret.to_secret_hex());
        let nsec = nostr_sdk::SecretKey::from_hex(hex.as_str())
            .map_err(|_| "Cannot encode this key.")?
            .to_bech32()
            .map_err(|_| "Cannot encode this key.")?;
        Ok(json!({"nsec": nsec}))
    }

    /// "Show QR". The reference wallet wraps the seed key in a NUT-18
    /// request only when it has a Nostr transport to receive over; without
    /// one it shows the raw key, and that is what this wallet does too.
    pub fn locked_request(&self, id: &str) -> Result<Value> {
        let pubkey = if id.is_empty() {
            lock_pubkey(&self.seed_key()?)
        } else {
            self.device_key(id)?.pubkey.clone()
        };
        Ok(json!({"pubkey": pubkey, "qr_text": pubkey}))
    }
}
