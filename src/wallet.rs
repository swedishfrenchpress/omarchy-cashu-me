use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use crate::access::Access;
use crate::diagnostics::{logged, note};
use crate::rates;
use bip39::Mnemonic;
use cdk::cdk_database::WalletDatabase;
use cdk::nuts::CurrencyUnit;
use cdk::nuts::{PaymentMethod, Token};
use cdk::wallet::Wallet;
use cdk::Amount;
use cdk_sqlite::WalletSqliteDatabase;
use fs2::FileExt;
use rusqlite::{params, Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use zeroize::Zeroizing;

pub type Result<T> = std::result::Result<T, &'static str>;

#[derive(Clone, Serialize, Deserialize)]
pub struct Mint {
    pub url: String,
    pub name: String,
}

#[derive(Default, Serialize, Deserialize)]
pub(crate) struct Settings {
    pub(crate) mints: Vec<Mint>,
    pub(crate) selected: Option<String>,
    #[serde(default)]
    pub(crate) needs_restore: bool,
    #[serde(default)]
    pub(crate) display: Display,
    #[serde(default)]
    pub(crate) privacy: Privacy,
    #[serde(default)]
    pub(crate) lightning: LightningAddress,
    #[serde(default)]
    pub(crate) locked: Locked,
}

/// Settings → Privacy, after cashubtc/wallet. Each one only decides which
/// mint calls the wallet makes on its own; nothing here changes an amount.
#[derive(Clone, Serialize, Deserialize)]
pub struct Privacy {
    /// Look for paid invoices and Lightning-address payments on every
    /// reconciliation. Off, incoming payments are found only on Refresh.
    #[serde(default = "yes")]
    pub check_incoming: bool,
    /// Keep reconciling every 30 s while the wallet is open. Off, the wallet
    /// reconciles once on unlock and then only on Refresh.
    #[serde(default = "yes")]
    pub repeat_checks: bool,
    /// Ask mints whether sent ecash was claimed. Off, sent tokens stay
    /// pending until Refresh or a reclaim.
    #[serde(default = "yes")]
    pub check_sent: bool,
    /// Read a Cashu token from the clipboard when the receive page opens.
    /// Handled by the interface; stored here so it survives like the rest.
    #[serde(default = "yes")]
    pub auto_paste: bool,
}

fn yes() -> bool {
    true
}

impl Default for Privacy {
    fn default() -> Self {
        Self {
            check_incoming: true,
            repeat_checks: true,
            check_sent: true,
            auto_paste: true,
        }
    }
}

/// Settings → Payments → Lightning: an npub.cash Lightning address whose
/// payments are minted as ecash at the chosen mint. CDK owns the protocol;
/// this records the choice so it survives a restart.
#[derive(Clone, Serialize, Deserialize)]
pub struct LightningAddress {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "yes")]
    pub auto_claim: bool,
    #[serde(default)]
    pub mint: Option<String>,
    #[serde(default)]
    pub last_checked: Option<u64>,
}

impl Default for LightningAddress {
    fn default() -> Self {
        Self {
            enabled: false,
            auto_claim: true,
            mint: None,
            last_checked: None,
        }
    }
}

/// Settings → Payments → Locked Ecash. The seed key is derived, never
/// stored. Device keys live only in this encrypted database, like the
/// reference wallet's device-only keys live only in its keychain.
#[derive(Default, Clone, Serialize, Deserialize)]
pub struct Locked {
    #[serde(default)]
    pub quick_lock: bool,
    #[serde(default)]
    pub device_keys: Vec<DeviceKey>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct DeviceKey {
    pub id: String,
    pub nickname: String,
    pub pubkey: String,
    pub secret: String,
    #[serde(default)]
    pub used_count: u64,
}

impl Drop for DeviceKey {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.secret.zeroize();
    }
}

pub(crate) fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or_default()
}

/// Presentation-only preferences. Neither field changes what unit any
/// amount is stored, sent, or requested in: mints are always sats. Both
/// default off so an existing wallet's screens read exactly as before.
#[derive(Default, Clone, Serialize, Deserialize)]
pub struct Display {
    #[serde(default)]
    pub bitcoin_symbol: bool,
    #[serde(default)]
    pub fiat_currency: Option<String>,
}

pub struct Storage {
    pub path: PathBuf,
    _lock: File,
}

impl Storage {
    pub fn new(directory: &Path) -> Result<Self> {
        fs::create_dir_all(directory).map_err(|_| "Cannot create the wallet data directory.")?;
        let metadata =
            fs::symlink_metadata(directory).map_err(|_| "Cannot inspect wallet storage.")?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err("Wallet storage must be a regular directory.");
        }
        fs::set_permissions(directory, fs::Permissions::from_mode(0o700))
            .map_err(|_| "Cannot protect wallet storage permissions.")?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .custom_flags(libc::O_NOFOLLOW)
            .mode(0o600)
            .open(directory.join("wallet.lock"))
            .map_err(|_| "Cannot open the wallet lock.")?;
        lock.try_lock_exclusive()
            .map_err(|_| "Another wallet worker is already running.")?;
        Ok(Self {
            path: directory.join("wallet.sqlite"),
            _lock: lock,
        })
    }

    pub fn exists(&self) -> bool {
        self.path.exists()
    }

    /// Removes every file the wallet owns: the database and its journals,
    /// the device key and the password vault. Exported backups are the
    /// user's and are left alone. Safe only while nothing holds the
    /// database open, which is why an open session exits after asking.
    pub fn delete_files(&self) -> Result<()> {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let mut name = self
                .path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("wallet.sqlite")
                .to_owned();
            name.push_str(suffix);
            let path = self.path.with_file_name(name);
            if path.exists() {
                fs::remove_file(&path).map_err(|_| "Could not delete the wallet database.")?;
            }
        }
        Access::new(&self.path).delete()?;
        let marker = self.path.with_file_name("deleted");
        if marker.exists() {
            fs::remove_file(&marker).map_err(|_| "Could not finish deleting the wallet.")?;
        }
        Ok(())
    }

    /// A delete leaves this marker so the next start, with no connection
    /// pool alive, removes anything a closing pool recreated.
    pub fn mark_deleted(&self) -> Result<()> {
        fs::write(self.path.with_file_name("deleted"), b"")
            .map_err(|_| "Could not record the wallet deletion.")
    }

    pub fn finish_pending_delete(&self) -> Result<()> {
        if self.path.with_file_name("deleted").exists() {
            self.delete_files()?;
        }
        Ok(())
    }
}

pub struct Session {
    metadata: Connection,
    pub(crate) mnemonic: Mnemonic,
    db: Arc<WalletSqliteDatabase>,
    pub(crate) settings: Settings,
    pub(crate) wallets: BTreeMap<String, Wallet>,
    sync_status: BTreeMap<String, &'static str>,
    // Mints whose NUT-13 restore has completed since this session opened,
    // so a restore driven mint by mint from the interface knows when the
    // whole wallet is recovered.
    restored: std::collections::BTreeSet<String>,
    access: Access,
    data_key: Zeroizing<String>,
    password_required: bool,
    // Fetched, never persisted: a stale or missing rate must fall back to
    // sats, not to a figure written before the last restart.
    rates: BTreeMap<String, f64>,
    rates_fetched_at: Option<std::time::Instant>,
    rates_fetched_unix: Option<u64>,
    // The Lightning address is re-registered with npub.cash after every
    // unlock; until that succeeds the interface shows it as connecting.
    pub(crate) lightning_ready: bool,
    pub(crate) lightning_error: Option<&'static str>,
}

pub(crate) fn encrypted_connection(path: &Path, password: &str) -> Result<Connection> {
    let file_metadata = fs::symlink_metadata(path).map_err(|_| "Wallet file is missing.")?;
    if !file_metadata.is_file() || file_metadata.file_type().is_symlink() {
        return Err("Wallet must be a regular file.");
    }
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)
        .map_err(|_| "Cannot open the wallet file.")?;
    let cipher: String = connection
        .query_row("PRAGMA cipher_version", [], |row| row.get(0))
        .map_err(|_| "SQLCipher is unavailable; refusing to open wallet data.")?;
    if cipher.is_empty() {
        return Err("SQLCipher is unavailable.");
    }
    connection
        .pragma_update(None, "key", password)
        .map_err(|_| "Cannot initialize encryption.")?;
    // With the wrong key, SQLCipher fails on the first statement that touches
    // the file, which may be one of these pragmas; report it as the password.
    connection
        .pragma_update(None, "temp_store", "MEMORY")
        .map_err(|_| "Incorrect password or damaged wallet file.")?;
    connection
        .pragma_update(None, "synchronous", "FULL")
        .map_err(|_| "Incorrect password or damaged wallet file.")?;
    connection
        .query_row("SELECT count(*) FROM sqlite_master", [], |row| {
            row.get::<_, i64>(0)
        })
        .map_err(|_| "Incorrect password or damaged wallet file.")?;
    Ok(connection)
}

impl Session {
    pub async fn create(storage: &Storage, password: &str) -> Result<Self> {
        let mnemonic =
            Mnemonic::generate(12).map_err(|_| "Could not generate a recovery phrase.")?;
        Self::initialize(storage, password, mnemonic, Settings::default()).await
    }

    /// The restore flow validates the words before it touches the current
    /// wallet, so a typo never costs anyone the wallet they have.
    pub fn validate_phrase(phrase: &str) -> Result<()> {
        Mnemonic::parse(phrase.trim())
            .map(|_| ())
            .map_err(|_| "That seed phrase doesn't look right. Check the spelling and try again.")
    }

    pub async fn restore_phrase(
        storage: &Storage,
        password: &str,
        phrase: &str,
        urls: &[String],
    ) -> Result<Self> {
        let mnemonic = Mnemonic::parse(phrase.trim()).map_err(|_| {
            "That seed phrase doesn't look right. Check the spelling and try again."
        })?;
        if urls.is_empty() {
            return Err("Enter the mint URLs used with this recovery phrase.");
        }
        let mut settings = Settings {
            needs_restore: true,
            ..Settings::default()
        };
        for input in urls {
            let url = validate_mint_url(input)?;
            if !settings.mints.iter().any(|mint| mint.url == url) {
                settings.mints.push(Mint {
                    name: url.clone(),
                    url,
                });
            }
        }
        settings.selected = settings.mints.first().map(|mint| mint.url.clone());
        Self::initialize(storage, password, mnemonic, settings).await
    }

    async fn initialize(
        storage: &Storage,
        password: &str,
        mnemonic: Mnemonic,
        settings: Settings,
    ) -> Result<Self> {
        if storage.exists() {
            return Err("A wallet already exists on this device.");
        }
        let key = Access::new(&storage.path).creation_key(password)?;
        // create_new prevents overwriting an existing wallet, including an incomplete one.
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&storage.path)
            .map_err(|_| "A wallet file already exists or cannot be created.")?;
        let connection = encrypted_connection(&storage.path, &key)?;
        let phrase = Zeroizing::new(mnemonic.to_string());
        connection.execute_batch("BEGIN IMMEDIATE;
            CREATE TABLE chaumarchy_meta (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL,
                mnemonic TEXT NOT NULL, settings TEXT NOT NULL);")
            .map_err(|_| "Cannot initialize wallet metadata.")?;
        connection
            .execute(
                "INSERT INTO chaumarchy_meta VALUES (1,1,?1,?2)",
                params![
                    phrase.as_str(),
                    serde_json::to_string(&settings)
                        .map_err(|_| "Cannot encode wallet settings.")?
                ],
            )
            .map_err(|_| "Cannot save wallet metadata.")?;
        connection
            .execute_batch("COMMIT")
            .map_err(|_| "Cannot save wallet metadata.")?;
        drop(connection);
        Self::open(storage, password).await
    }

    pub async fn open(storage: &Storage, password: &str) -> Result<Self> {
        let access = Access::new(&storage.path);
        let key = access.unlock_key(password)?;
        let connection = encrypted_connection(&storage.path, &key)?;
        let (version, phrase, settings): (i64, String, String) = connection
            .query_row(
                "SELECT version,mnemonic,settings FROM chaumarchy_meta WHERE id=1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .map_err(|_| "Wallet metadata is missing or damaged.")?;
        let phrase = Zeroizing::new(phrase);
        if version != 1 {
            return Err("This wallet requires a newer cashu.me version.");
        }
        let mnemonic = Mnemonic::parse(phrase.as_str()).map_err(|_| "Recovery data is damaged.")?;
        let settings: Settings =
            serde_json::from_str(&settings).map_err(|_| "Wallet settings are damaged.")?;
        let db = Arc::new(
            WalletSqliteDatabase::new((storage.path.clone(), key.to_string()))
                .await
                .map_err(|_| "Cannot initialize the CDK wallet database.")?,
        );
        // CDK performs schema migrations on its own connection. Reopen ours so
        // SQLCipher export sees the completed schema rather than a cached one.
        drop(connection);
        let connection = encrypted_connection(&storage.path, &key)?;
        let mut session = Self {
            metadata: connection,
            mnemonic,
            db,
            settings,
            wallets: BTreeMap::new(),
            sync_status: BTreeMap::new(),
            restored: std::collections::BTreeSet::new(),
            password_required: access.password_required(),
            access,
            data_key: key,
            rates: BTreeMap::new(),
            rates_fetched_at: None,
            rates_fetched_unix: None,
            lightning_ready: false,
            lightning_error: None,
        };
        for mint in &session.settings.mints {
            session
                .wallets
                .insert(mint.url.clone(), session.make_wallet(&mint.url)?);
        }
        Ok(session)
    }

    fn make_wallet(&self, url: &str) -> Result<Wallet> {
        let seed = Zeroizing::new(self.mnemonic.to_seed_normalized(""));
        Wallet::new(url, CurrencyUnit::Sat, self.db.clone(), *seed, None)
            .map_err(|_| "Cannot initialize this mint's wallet.")
    }

    pub(crate) fn save_settings(&self) -> Result<()> {
        let value =
            serde_json::to_string(&self.settings).map_err(|_| "Cannot encode wallet settings.")?;
        self.metadata
            .execute("UPDATE chaumarchy_meta SET settings=?1 WHERE id=1", [value])
            .map_err(|_| "Cannot save wallet settings.")?;
        Ok(())
    }

    pub async fn add_mint(&mut self, input: &str) -> Result<()> {
        let url = validate_mint_url(input)?;
        if self.wallets.contains_key(&url) {
            return self.select_mint(&url);
        }
        let wallet = self.make_wallet(&url)?;
        let info =
            match tokio::time::timeout(Duration::from_secs(15), wallet.fetch_mint_info()).await {
                Err(_) => return Err("Mint did not respond in time."),
                Ok(Err(error)) => {
                    note(&format!("{url} fetch_mint_info"), &error);
                    return Err("Cannot fetch this mint's information.");
                }
                Ok(Ok(None)) => return Err("Mint did not return its information."),
                Ok(Ok(Some(info))) => info,
            };
        let info = serde_json::to_value(info).map_err(|_| "Cannot read mint information.")?;
        for nut in ["4", "5"] {
            let settings = &info["nuts"][nut];
            let supported = settings["methods"].as_array().is_some_and(|methods| {
                methods
                    .iter()
                    .any(|method| method["method"] == "bolt11" && method["unit"] == "sat")
            });
            if settings["disabled"] == true || !supported {
                return Err(
                    "This mint does not currently support sending and receiving Lightning in sats.",
                );
            }
        }
        if info["nuts"]["9"]["supported"] != true {
            return Err(
                "This mint does not advertise the restoration support required by cashu.me.",
            );
        }
        let name = clean_mint_name(info["name"].as_str().unwrap_or_default());
        let name = if name.is_empty() { url.clone() } else { name };
        self.settings.mints.push(Mint {
            url: url.clone(),
            name,
        });
        let previous = self.settings.selected.replace(url.clone());
        if let Err(error) = self.save_settings() {
            self.settings.mints.pop();
            self.settings.selected = previous;
            return Err(error);
        }
        self.wallets.insert(url, wallet);
        Ok(())
    }

    pub fn select_mint(&mut self, url: &str) -> Result<()> {
        if !self.wallets.contains_key(url) {
            return Err("Add this mint before selecting it.");
        }
        let previous = self.settings.selected.replace(url.to_owned());
        if let Err(error) = self.save_settings() {
            self.settings.selected = previous;
            return Err(error);
        }
        Ok(())
    }

    /// Presentation-only: updates neither balances nor any mint's unit.
    /// Enabling a currency for the first time fetches a rate right away
    /// rather than waiting for the next reconciliation tick.
    pub async fn set_display(
        &mut self,
        bitcoin_symbol: bool,
        fiat_currency: Option<String>,
    ) -> Result<()> {
        let fiat_currency = match fiat_currency {
            Some(code) => {
                let code = code.trim().to_uppercase();
                if !rates::is_supported(&code) {
                    return Err("This currency is not offered.");
                }
                Some(code)
            }
            None => None,
        };
        let fetch_now =
            fiat_currency.is_some() && fiat_currency != self.settings.display.fiat_currency;
        let previous = std::mem::replace(
            &mut self.settings.display,
            Display {
                bitcoin_symbol,
                fiat_currency,
            },
        );
        if let Err(error) = self.save_settings() {
            self.settings.display = previous;
            return Err(error);
        }
        if fetch_now {
            self.rates_fetched_at = None;
            self.refresh_rates().await;
        }
        Ok(())
    }

    /// Best-effort and bounded like any other network call this worker
    /// makes; a failure here is noted for diagnostics and otherwise
    /// swallowed, leaving the display at "no rate yet" rather than
    /// interrupting reconciliation or any wallet operation.
    async fn refresh_rates(&mut self) {
        if self.settings.display.fiat_currency.is_none() {
            return;
        }
        let stale = self
            .rates_fetched_at
            .map(|at| at.elapsed() > Duration::from_secs(300))
            .unwrap_or(true);
        if !stale {
            return;
        }
        self.rates_fetched_at = Some(std::time::Instant::now());
        match rates::fetch_rates().await {
            Ok(fetched) => {
                self.rates = fetched;
                self.rates_fetched_unix = Some(now());
            }
            Err(error) => note("fetch_rates", &error),
        }
    }

    /// The Currency page's refresh button: fetch now, whatever the age.
    pub async fn refresh_rate_now(&mut self) -> Result<()> {
        if self.settings.display.fiat_currency.is_none() {
            return Err("Choose a currency first.");
        }
        self.rates_fetched_at = None;
        self.refresh_rates().await;
        if self.rates_fetched_unix.is_none() {
            return Err("Could not fetch the price. Check your connection and try again.");
        }
        Ok(())
    }

    pub async fn set_privacy(&mut self, privacy: Privacy) -> Result<()> {
        let previous = std::mem::replace(&mut self.settings.privacy, privacy);
        if let Err(error) = self.save_settings() {
            self.settings.privacy = previous;
            return Err(error);
        }
        Ok(())
    }

    /// NUT-13 recovery for one mint, driven from the restore page so it can
    /// show each mint's result as it settles. Names the mint from its info
    /// on the way, since a restore starts with nothing but URLs.
    pub async fn restore_mint(&mut self, url: &str) -> Result<Value> {
        let url = validate_mint_url(url)?;
        let wallet = self
            .wallets
            .get(&url)
            .ok_or("This mint is not part of the restore.")?;
        if let Ok(Ok(Some(info))) =
            tokio::time::timeout(Duration::from_secs(15), wallet.fetch_mint_info()).await
        {
            let name = clean_mint_name(info.name.as_deref().unwrap_or_default());
            if !name.is_empty() {
                if let Some(mint) = self.settings.mints.iter_mut().find(|mint| mint.url == url) {
                    mint.name = name;
                }
            }
        }
        let wallet = self
            .wallets
            .get(&url)
            .ok_or("This mint is not part of the restore.")?;
        let restored = match tokio::time::timeout(Duration::from_secs(180), wallet.restore()).await
        {
            Err(_) => return Err("This mint did not finish restoring in time. Retry."),
            Ok(Err(error)) => {
                note(&format!("{url} restore"), &error);
                return Err(
                    "This mint could not be restored. Check that it is reachable and retry.",
                );
            }
            Ok(Ok(restored)) => restored,
        };
        self.restored.insert(url.clone());
        self.sync_status.insert(url.clone(), "synced");
        if self.settings.needs_restore
            && self
                .settings
                .mints
                .iter()
                .all(|mint| self.restored.contains(&mint.url))
        {
            self.settings.needs_restore = false;
        }
        self.save_settings()?;
        Ok(
            json!({"mint": url, "recovered": restored.unspent.to_string(),
            "pending": restored.pending.to_string(), "spent": restored.spent.to_string()}),
        )
    }

    /// `periodic` is the 30 s tick, which the Privacy settings can thin
    /// out; an explicit Refresh or unlock always runs every step.
    pub async fn reconcile(&mut self, periodic: bool) {
        let privacy = self.settings.privacy.clone();
        if periodic && !privacy.repeat_checks {
            return;
        }
        self.refresh_rates().await;
        if self.settings.lightning.enabled && !self.lightning_ready {
            self.connect_lightning().await;
        }
        let mut restored_all = true;
        let needs_restore = self.settings.needs_restore;
        let check_incoming = !periodic || privacy.check_incoming;
        let check_sent = !periodic || privacy.check_sent;
        for (url, wallet) in &self.wallets {
            let outcome = tokio::time::timeout(
                Duration::from_secs(if needs_restore { 180 } else { 20 }),
                async {
                    // Every step runs even when an earlier one fails. A single
                    // unrecoverable operation must never block unissued quotes,
                    // pending melts, or spent-proof checks at this mint.
                    let mut synced = true;
                    if needs_restore {
                        synced &= logged(&format!("{url} restore"), wallet.restore().await);
                    }
                    match wallet.recover_incomplete_sagas().await {
                        Ok(report) => {
                            if report.failed > 0 {
                                note(
                                    &format!("{url} recover_incomplete_sagas"),
                                    &format!("{} operation(s) still unrecovered", report.failed),
                                );
                                synced = false;
                            }
                        }
                        Err(error) => {
                            note(&format!("{url} recover_incomplete_sagas"), &error);
                            synced = false;
                        }
                    }
                    if check_incoming {
                        synced &= logged(
                            &format!("{url} mint_unissued_quotes"),
                            wallet.mint_unissued_quotes().await,
                        );
                    }
                    synced &= logged(
                        &format!("{url} finalize_pending_melts"),
                        wallet.finalize_pending_melts().await,
                    );
                    if check_sent {
                        synced &= logged(
                            &format!("{url} check_all_pending_proofs"),
                            wallet.check_all_pending_proofs().await,
                        );
                        match wallet.get_unspent_proofs().await {
                            Ok(proofs) if !proofs.is_empty() => {
                                synced &= logged(
                                    &format!("{url} check_proofs_spent"),
                                    wallet.check_proofs_spent(proofs).await,
                                );
                            }
                            Ok(_) => {}
                            Err(error) => {
                                note(&format!("{url} get_unspent_proofs"), &error);
                                synced = false;
                            }
                        }
                    }
                    synced
                },
            )
            .await;
            let synced = outcome.unwrap_or(false);
            restored_all &= synced;
            self.sync_status
                .insert(url.clone(), if synced { "synced" } else { "retrying" });
        }
        if self.settings.needs_restore && restored_all {
            self.settings.needs_restore = false;
            if self.save_settings().is_err() {
                self.settings.needs_restore = true;
            }
        }
        // The reference wallet polls npub.cash every two minutes; a Refresh
        // always asks, the tick only when that long has passed.
        let due = self
            .settings
            .lightning
            .last_checked
            .is_none_or(|checked| now().saturating_sub(checked) >= 110);
        if check_incoming
            && self.settings.lightning.enabled
            && self.settings.lightning.auto_claim
            && (!periodic || due)
        {
            let _ = self.claim_lightning().await;
        }
    }

    /// Consumes the session and removes the wallet's files. CDK's pool may
    /// still recreate an empty database as it winds down, so the caller
    /// exits the process afterwards and the marker has the next start
    /// sweep up anything left.
    pub fn delete(self, storage: &Storage) -> Result<()> {
        drop(self);
        storage.delete_files()?;
        storage.mark_deleted()
    }

    pub async fn snapshot(&self) -> Result<Value> {
        let mut mints = Vec::new();
        for mint in &self.settings.mints {
            let wallet = self
                .wallets
                .get(&mint.url)
                .ok_or("Mint state is inconsistent.")?;
            let spendable = wallet
                .total_balance()
                .await
                .map_err(|_| "Cannot read balance.")?;
            let pending = wallet
                .total_pending_balance()
                .await
                .map_err(|_| "Cannot read pending balance.")?;
            let reserved = wallet
                .total_reserved_balance()
                .await
                .map_err(|_| "Cannot read reserved balance.")?;
            mints.push(json!({"url": mint.url, "name": mint.name, "spendable": if self.settings.needs_restore {"0".to_owned()} else {spendable.to_string()},
                "pending": pending.to_string(), "reserved": reserved.to_string(),
                "sync": self.sync_status.get(&mint.url).unwrap_or(&"waiting")}));
        }
        // Recent activity spans every mint so the total balance and its history agree.
        let mut recent = Vec::new();
        for mint in &self.settings.mints {
            let wallet = self
                .wallets
                .get(&mint.url)
                .ok_or("Mint state is inconsistent.")?;
            let transactions = wallet
                .list_transactions(None)
                .await
                .map_err(|_| "Cannot read payment history.")?;
            for tx in transactions.into_iter().take(100) {
                recent.push((tx.timestamp, json!({"id":tx.id().to_string(),"amount":tx.amount.to_string(),"fee":tx.fee.to_string(),
                    "direction":tx.direction.to_string(),"status":tx.status.to_string(),"timestamp":tx.timestamp,
                    "kind":if tx.payment_method.is_some() {"Lightning"} else {"Ecash"},
                    "mint":mint.url.clone(),"mint_name":mint.name.clone()})));
            }
        }
        recent.sort_by_key(|a| std::cmp::Reverse(a.0));
        let history: Vec<Value> = recent.into_iter().take(100).map(|(_, tx)| tx).collect();
        // Pending money spans every mint, like the balance and history above.
        // Unclaimed ecash at an unselected mint must stay visible and
        // actionable, including while a restore is still reconciling.
        let mut pending_sends = Vec::new();
        let mut pending_invoices = Vec::new();
        let mut issued_invoices = Vec::new();
        let quotes = self
            .db
            .get_mint_quotes()
            .await
            .map_err(|_| "Cannot read saved invoices.")?;
        for mint in &self.settings.mints {
            let wallet = self
                .wallets
                .get(&mint.url)
                .ok_or("Mint state is inconsistent.")?;
            for quote in &quotes {
                if quote.mint_url != wallet.mint_url
                    || quote.payment_method != PaymentMethod::BOLT11
                {
                    continue;
                }
                if quote.state == cdk::nuts::MintQuoteState::Issued {
                    issued_invoices.push(json!({"id":quote.id,"mint":quote.mint_url.to_string(),"amount":quote.amount_issued.to_string()}));
                } else {
                    pending_invoices.push(json!({"id":quote.id,"amount":quote.amount.unwrap_or_default().to_string(),
                        "expiry":quote.expiry,"mint":mint.url.clone(),"mint_name":mint.name.clone()}));
                }
            }
            for id in wallet
                .get_pending_sends()
                .await
                .map_err(|_| "Cannot read pending sends.")?
            {
                let amount = self
                    .db
                    .get_saga(&id)
                    .await
                    .map_err(|_| "Cannot read pending transfer.")?
                    .and_then(|saga| match saga.data {
                        cdk::wallet::types::OperationData::Send(data) => {
                            Some(data.amount.to_string())
                        }
                        _ => None,
                    });
                pending_sends.push(json!({"id":id.to_string(),"amount":amount,
                    "mint":mint.url.clone(),"mint_name":mint.name.clone()}));
            }
        }
        let exchange_rate = self
            .settings
            .display
            .fiat_currency
            .as_deref()
            .and_then(|currency| {
                self.rates.get(currency).map(|rate| {
                    json!({"currency": currency, "rate": rate, "fetched_at": self.rates_fetched_unix})
                })
            });
        Ok(
            json!({"unlocked":true,"exists":true,"mints":mints,"selected":self.settings.selected,
            "password_required":self.password_required,"history":history,"pending_sends":pending_sends,"pending_invoices":pending_invoices,"issued_invoices":issued_invoices,"restoring":self.settings.needs_restore,
            "display":{"bitcoin_symbol":self.settings.display.bitcoin_symbol,"fiat_currency":self.settings.display.fiat_currency},
            "currencies":rates::catalog(),"exchange_rate":exchange_rate,
            "privacy":self.settings.privacy,"version":env!("CARGO_PKG_VERSION"),
            "lightning":self.lightning_state(),
            "locked":self.locked_state()}),
        )
    }

    pub fn selected_wallet(&self) -> Result<&Wallet> {
        self.wallet_for(
            self.settings
                .selected
                .as_deref()
                .ok_or("Choose a mint first.")?,
        )
    }

    pub fn wallet_for(&self, url: &str) -> Result<&Wallet> {
        if self.settings.needs_restore {
            return Err("Backup recovery is still in progress. Wait for mint reconciliation.");
        }
        self.wallets
            .get(url)
            .ok_or("Add and trust this token's issuing mint in Settings first.")
    }

    pub async fn invoice(&self, amount: &str) -> Result<Value> {
        let amount = parse_amount(amount)?;
        let wallet = self.selected_wallet()?;
        let quote = tokio::time::timeout(
            Duration::from_secs(20),
            wallet.mint_quote(PaymentMethod::BOLT11, Some(amount), None, None),
        )
        .await
        .map_err(|_| "Invoice request timed out. Check pending invoices before retrying.")?
        .map_err(|_| "Mint could not create this invoice. Check its limits and availability.")?;
        Ok(
            json!({"invoice":quote.request,"quote_id":quote.id,"mint":wallet.mint_url.to_string(),"amount":amount.to_string(),"expiry":quote.expiry}),
        )
    }

    /// Resolve the mint that owns a saved send, so pending ecash stays
    /// actionable no matter which mint is currently selected.
    pub async fn wallet_for_operation(&self, input: &str) -> Result<&Wallet> {
        let id = input.parse().map_err(|_| "Invalid transfer reference.")?;
        let saga = self
            .db
            .get_saga(&id)
            .await
            .map_err(|_| "Cannot read saved transfer.")?
            .ok_or("Transfer not found.")?;
        self.wallet_for(&saga.mint_url.to_string())
    }

    pub async fn pending_token(&self, input: &str) -> Result<Value> {
        let id = input.parse().map_err(|_| "Invalid transfer reference.")?;
        let wallet = self.wallet_for_operation(input).await?;
        if !wallet
            .get_pending_sends()
            .await
            .map_err(|_| "Cannot read pending sends.")?
            .contains(&id)
        {
            return Err("This transfer is no longer pending at its mint.");
        }
        let saga = self
            .db
            .get_saga(&id)
            .await
            .map_err(|_| "Cannot read saved transfer.")?
            .ok_or("Transfer not found.")?;
        if let cdk::wallet::types::OperationData::Send(data) = saga.data {
            let proofs = data.proofs.ok_or("Pending transfer has no saved proofs.")?;
            let token = Token::new(saga.mint_url, proofs, None, CurrencyUnit::Sat);
            let amount = token
                .value()
                .map_err(|_| "Cannot read pending token amount.")?;
            return Ok(
                json!({"token":token.to_string(),"operation_id":input,"amount":amount.to_string(),"mint":wallet.mint_url.to_string()}),
            );
        }
        Err("This is not an ecash send.")
    }

    pub async fn saved_invoice(&self, id: &str) -> Result<Value> {
        let quote = self
            .db
            .get_mint_quote(id)
            .await
            .map_err(|_| "Cannot read saved invoice.")?
            .ok_or("Invoice not found.")?;
        if quote.payment_method != PaymentMethod::BOLT11 {
            return Err("This is not a Lightning invoice.");
        }
        let wallet = self.wallet_for(&quote.mint_url.to_string())?;
        Ok(
            json!({"invoice":quote.request,"quote_id":quote.id,"mint":wallet.mint_url.to_string(),"amount":quote.amount.unwrap_or_default().to_string(),"expiry":quote.expiry}),
        )
    }

    pub fn set_password(&mut self, password: &str) -> Result<()> {
        let result = self.access.enable(&self.data_key, password);
        self.password_required = self.access.password_required();
        result
    }

    pub fn remove_password(&mut self, password: &str) -> Result<()> {
        let result = self.access.disable(&self.data_key, password);
        self.password_required = self.access.password_required();
        result
    }

    /// With App Lock on, revealing the words asks for the password again, as
    /// the reference wallet re-authenticates before showing a seed.
    pub fn recovery_phrase(&self, password: &str) -> Result<Value> {
        self.confirm_password(password)?;
        Ok(json!({"phrase": self.mnemonic.to_string(), "mints": self.settings.mints}))
    }

    /// A no-op without App Lock, where there is nothing to check against.
    pub fn confirm_password(&self, password: &str) -> Result<()> {
        if !self.password_required {
            return Ok(());
        }
        if password.is_empty() {
            return Err("Enter your wallet password.");
        }
        if self.access.unlock_key(password)?.as_str() != self.data_key.as_str() {
            return Err("Incorrect wallet password.");
        }
        Ok(())
    }
}

/// A mint's name is mint-controlled and is rendered by shared Omarchy
/// components whose text format is not ours to pin, so keep it printable
/// and free of the delimiters that turn a label into rich text.
pub(crate) fn clean_mint_name(name: &str) -> String {
    let name: String = name
        .chars()
        .filter(|character| !character.is_control() && !matches!(character, '<' | '>'))
        .take(100)
        .collect();
    name.trim().to_owned()
}

pub fn parse_amount(input: &str) -> Result<Amount> {
    let amount: u64 = input
        .trim()
        .parse()
        .map_err(|_| "Enter a whole number of sats.")?;
    if amount == 0 || amount > 2_100_000_000_000_000 {
        return Err("Enter a valid positive amount in sats.");
    }
    Ok(Amount::from(amount))
}

pub fn validate_mint_url(input: &str) -> Result<String> {
    // A bare host is what people type; HTTPS is the only scheme it can mean.
    let input = input.trim();
    let input = if input.contains("://") {
        input.to_owned()
    } else {
        format!("https://{input}")
    };
    let mut parsed = url::Url::parse(&input).map_err(|_| "Enter a valid mint URL.")?;
    let loopback = parsed.host_str().is_some_and(|host| {
        host == "localhost"
            || host
                .parse::<std::net::IpAddr>()
                .is_ok_and(|ip| ip.is_loopback())
    });
    if (parsed.scheme() != "https" && !(parsed.scheme() == "http" && loopback))
        || parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return Err("Use an HTTPS mint URL without credentials, query parameters, or a fragment.");
    }
    // Preserve path case (Minibits uses /Bitcoin), while removing trailing slashes.
    let path = parsed.path().trim_end_matches('/').to_owned();
    parsed.set_path(&path);
    Ok(parsed.to_string().trim_end_matches('/').to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn encrypted_wallet_reopens_and_rejects_wrong_password() {
        let temp = tempfile::tempdir().unwrap();
        let storage = Storage::new(temp.path()).unwrap();
        let session = Session::create(&storage, "correct horse battery staple")
            .await
            .unwrap();
        assert_eq!(session.snapshot().await.unwrap()["unlocked"], true);
        let original = session.mnemonic.to_string();
        drop(session);
        assert!(Session::open(&storage, "incorrect password").await.is_err());
        assert!(Session::create(&storage, "a different password")
            .await
            .is_err());
        let session = Session::open(&storage, "correct horse battery staple")
            .await
            .unwrap();
        assert_eq!(session.mnemonic.to_string(), original);
        let bytes = fs::read(&storage.path).unwrap();
        assert!(!bytes.starts_with(b"SQLite format 3"));
        assert!(!bytes
            .windows(original.len())
            .any(|part| part == original.as_bytes()));
        assert_eq!(
            fs::metadata(&storage.path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn only_one_worker_can_own_storage() {
        let temp = tempfile::tempdir().unwrap();
        let first = Storage::new(temp.path()).unwrap();
        assert!(Storage::new(temp.path()).is_err());
        drop(first);
        assert!(Storage::new(temp.path()).is_ok());
    }

    #[test]
    fn mint_urls_preserve_paths_and_reject_credentials() {
        assert_eq!(
            validate_mint_url(" https://mint.minibits.cash/Bitcoin/ ").unwrap(),
            "https://mint.minibits.cash/Bitcoin"
        );
        assert_eq!(
            validate_mint_url("mint.minibits.cash/Bitcoin").unwrap(),
            "https://mint.minibits.cash/Bitcoin"
        );
        for bad in [
            "http://example.com",
            "https://user:pass@example.com",
            "https://example.com?x=1",
            "https://example.com#token",
        ] {
            assert!(validate_mint_url(bad).is_err());
        }
    }

    #[tokio::test]
    async fn optional_password_preserves_wallet_across_security_changes() {
        let temp = tempfile::tempdir().unwrap();
        let storage = Storage::new(temp.path()).unwrap();
        let mut session = Session::create(&storage, "").await.unwrap();
        let phrase = session.mnemonic.to_string();
        assert!(!session.password_required);
        assert!(temp.path().join("device.key").exists());
        assert!(session.set_password("short").is_err());
        session.set_password("optional password 123").unwrap();
        assert!(session.password_required);
        assert!(!temp.path().join("device.key").exists());
        let vault = fs::read(temp.path().join("access.sqlite")).unwrap();
        assert!(!vault.starts_with(b"SQLite format 3"));
        assert!(!vault
            .windows(session.data_key.len())
            .any(|bytes| bytes == session.data_key.as_bytes()));
        assert_eq!(
            fs::metadata(temp.path().join("access.sqlite"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        drop(session);
        assert!(Session::open(&storage, "").await.is_err());
        assert!(Session::open(&storage, "incorrect password").await.is_err());
        let mut session = Session::open(&storage, "optional password 123")
            .await
            .unwrap();
        assert_eq!(session.mnemonic.to_string(), phrase);
        assert!(session.remove_password("incorrect password").is_err());
        assert!(!temp.path().join("device.key").exists());
        session.remove_password("optional password 123").unwrap();
        assert!(!session.password_required);
        assert!(!temp.path().join("access.sqlite").exists());
        drop(session);
        let session = Session::open(&storage, "").await.unwrap();
        assert_eq!(session.mnemonic.to_string(), phrase);
        assert_eq!(
            fs::metadata(temp.path().join("device.key"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert!(!session.password_required);
    }

    #[tokio::test]
    async fn device_key_from_an_interrupted_setup_does_not_block_a_protected_wallet() {
        let temp = tempfile::tempdir().unwrap();
        let storage = Storage::new(temp.path()).unwrap();
        // Leave a device key behind, as a creation interrupted between writing
        // the key and creating the wallet file would.
        Access::new(&storage.path).creation_key("").unwrap();
        assert!(temp.path().join("device.key").exists());
        assert!(!storage.exists());
        let session = Session::create(&storage, "protected password 123")
            .await
            .unwrap();
        let phrase = session.mnemonic.to_string();
        assert!(session.password_required);
        assert!(!temp.path().join("device.key").exists());
        drop(session);
        assert!(Session::open(&storage, "incorrect password").await.is_err());
        let session = Session::open(&storage, "protected password 123")
            .await
            .unwrap();
        assert_eq!(session.mnemonic.to_string(), phrase);
    }

    #[tokio::test]
    async fn display_settings_are_display_only_and_persist_across_reopen() {
        let temp = tempfile::tempdir().unwrap();
        let storage = Storage::new(temp.path()).unwrap();
        let mut session = Session::create(&storage, "display settings password")
            .await
            .unwrap();
        // A wallet created before this feature existed has no "display" key
        // in its stored settings JSON; #[serde(default)] must still open it.
        assert!(!session.settings.display.bitcoin_symbol);
        assert_eq!(session.settings.display.fiat_currency, None);
        assert!(session
            .set_display(true, Some("XYZ".to_owned()))
            .await
            .is_err());
        assert!(!session.settings.display.bitcoin_symbol);
        // Lowercase and surrounding whitespace are normalized rather than rejected.
        session
            .set_display(true, Some(" usd ".to_owned()))
            .await
            .unwrap();
        assert!(session.settings.display.bitcoin_symbol);
        assert_eq!(
            session.settings.display.fiat_currency,
            Some("USD".to_owned())
        );
        drop(session);
        let session = Session::open(&storage, "display settings password")
            .await
            .unwrap();
        assert!(session.settings.display.bitcoin_symbol);
        assert_eq!(
            session.settings.display.fiat_currency,
            Some("USD".to_owned())
        );
        // Never a wallet-affecting setting: no mint, no selected mint, and no
        // balance exist for this test wallet regardless of what is displayed.
        assert!(session.settings.mints.is_empty());
    }
}
