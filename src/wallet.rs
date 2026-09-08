use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

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
struct Settings {
    mints: Vec<Mint>,
    selected: Option<String>,
    #[serde(default)]
    needs_restore: bool,
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
}

pub struct Session {
    metadata: Connection,
    mnemonic: Mnemonic,
    db: Arc<WalletSqliteDatabase>,
    settings: Settings,
    wallets: BTreeMap<String, Wallet>,
    sync_status: BTreeMap<String, &'static str>,
}

fn encrypted_connection(path: &Path, password: &str) -> Result<Connection> {
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
    connection
        .pragma_update(None, "temp_store", "MEMORY")
        .map_err(|_| "Cannot protect temporary storage.")?;
    connection
        .pragma_update(None, "synchronous", "FULL")
        .map_err(|_| "Cannot configure durable storage.")?;
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

    pub async fn restore_phrase(
        storage: &Storage,
        password: &str,
        phrase: &str,
        urls: &[String],
    ) -> Result<Self> {
        let mnemonic =
            Mnemonic::parse(phrase).map_err(|_| "Check your recovery words and their order.")?;
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
        if password.chars().count() < 12 {
            return Err("Use a wallet password of at least 12 characters.");
        }
        // create_new prevents overwriting an existing wallet, including an incomplete one.
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&storage.path)
            .map_err(|_| "A wallet file already exists or cannot be created.")?;
        let connection = encrypted_connection(&storage.path, password)?;
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
        let connection = encrypted_connection(&storage.path, password)?;
        let (version, phrase, settings): (i64, String, String) = connection
            .query_row(
                "SELECT version,mnemonic,settings FROM chaumarchy_meta WHERE id=1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .map_err(|_| "Wallet metadata is missing or damaged.")?;
        let phrase = Zeroizing::new(phrase);
        if version != 1 {
            return Err("This wallet requires a newer Chaumarchy version.");
        }
        let mnemonic = Mnemonic::parse(phrase.as_str()).map_err(|_| "Recovery data is damaged.")?;
        let settings: Settings =
            serde_json::from_str(&settings).map_err(|_| "Wallet settings are damaged.")?;
        let db = Arc::new(
            WalletSqliteDatabase::new((storage.path.clone(), password.to_owned()))
                .await
                .map_err(|_| "Cannot initialize the CDK wallet database.")?,
        );
        // CDK performs schema migrations on its own connection. Reopen ours so
        // SQLCipher export sees the completed schema rather than a cached one.
        drop(connection);
        let connection = encrypted_connection(&storage.path, password)?;
        let mut session = Self {
            metadata: connection,
            mnemonic,
            db,
            settings,
            wallets: BTreeMap::new(),
            sync_status: BTreeMap::new(),
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

    fn save_settings(&self) -> Result<()> {
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
        let info = tokio::time::timeout(Duration::from_secs(15), wallet.fetch_mint_info())
            .await
            .map_err(|_| "Mint did not respond in time.")?
            .map_err(|_| "Cannot fetch this mint's information.")?
            .ok_or("Mint did not return its information.")?;
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
                "This mint does not advertise the restoration support required by Chaumarchy.",
            );
        }
        let name = info["name"]
            .as_str()
            .filter(|name| !name.is_empty())
            .unwrap_or(&url);
        self.settings.mints.push(Mint {
            url: url.clone(),
            name: name.chars().take(100).collect(),
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

    pub async fn reconcile(&mut self) {
        let mut restored_all = true;
        for (url, wallet) in &self.wallets {
            let outcome = tokio::time::timeout(
                Duration::from_secs(if self.settings.needs_restore { 180 } else { 20 }),
                async {
                    if self.settings.needs_restore {
                        wallet.restore().await?;
                    }
                    let report = wallet.recover_incomplete_sagas().await?;
                    if report.failed > 0 {
                        return Err(cdk::Error::Custom("Recovery incomplete".into()));
                    }
                    wallet.mint_unissued_quotes().await?;
                    wallet.finalize_pending_melts().await?;
                    wallet.check_all_pending_proofs().await?;
                    let proofs = wallet.get_unspent_proofs().await?;
                    if !proofs.is_empty() {
                        wallet.check_proofs_spent(proofs).await?;
                    }
                    Ok::<_, cdk::Error>(())
                },
            )
            .await;
            let synced = matches!(outcome, Ok(Ok(())));
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
        let mut history = Vec::new();
        let mut pending_sends = Vec::new();
        let mut pending_invoices = Vec::new();
        if let Ok(wallet) = self.selected_wallet() {
            for quote in self
                .db
                .get_mint_quotes()
                .await
                .map_err(|_| "Cannot read saved invoices.")?
            {
                if quote.mint_url == wallet.mint_url
                    && quote.payment_method == PaymentMethod::BOLT11
                    && quote.state != cdk::nuts::MintQuoteState::Issued
                {
                    pending_invoices.push(json!({"id":quote.id,"amount":quote.amount.unwrap_or_default().to_string(),"expiry":quote.expiry}));
                }
            }
            let transactions = wallet
                .list_transactions(None)
                .await
                .map_err(|_| "Cannot read payment history.")?;
            for tx in transactions.iter().take(100) {
                history.push(json!({"id":tx.id().to_string(),"amount":tx.amount.to_string(),"fee":tx.fee.to_string(),
                    "direction":tx.direction.to_string(),"status":tx.status.to_string(),"timestamp":tx.timestamp,
                    "kind":if tx.payment_method.is_some() {"Lightning"} else {"Ecash"}}));
            }
            for id in wallet
                .get_pending_sends()
                .await
                .map_err(|_| "Cannot read pending sends.")?
            {
                pending_sends.push(json!({"id":id.to_string()}));
            }
        }
        Ok(
            json!({"unlocked":true,"exists":true,"mints":mints,"selected":self.settings.selected,
            "history":history,"pending_sends":pending_sends,"pending_invoices":pending_invoices,"restoring":self.settings.needs_restore}),
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
            json!({"invoice":quote.request,"quote_id":quote.id,"amount":amount.to_string(),"expiry":quote.expiry}),
        )
    }

    pub async fn pending_token(&self, input: &str) -> Result<Value> {
        let id = input.parse().map_err(|_| "Invalid transfer reference.")?;
        let wallet = self.selected_wallet()?;
        if !wallet
            .get_pending_sends()
            .await
            .map_err(|_| "Cannot read pending sends.")?
            .contains(&id)
        {
            return Err("This transfer is no longer pending at the selected mint.");
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
            return Ok(json!({"token":token.to_string(),"operation_id":input}));
        }
        Err("This is not an ecash send.")
    }

    pub async fn saved_invoice(&self, id: &str) -> Result<Value> {
        let wallet = self.selected_wallet()?;
        let quote = self
            .db
            .get_mint_quote(id)
            .await
            .map_err(|_| "Cannot read saved invoice.")?
            .ok_or("Invoice not found.")?;
        if quote.mint_url != wallet.mint_url || quote.payment_method != PaymentMethod::BOLT11 {
            return Err("This invoice does not belong to the selected mint.");
        }
        Ok(
            json!({"invoice":quote.request,"quote_id":quote.id,"amount":quote.amount.unwrap_or_default().to_string(),"expiry":quote.expiry}),
        )
    }

    pub fn recovery_phrase(&self) -> Value {
        json!({"phrase": self.mnemonic.to_string(), "mints": self.settings.mints})
    }

    pub fn export_backup(&self, destination: &Path, password: &str) -> Result<()> {
        export_encrypted(&self.metadata, destination, password)
    }

    pub async fn import_backup(
        storage: &Storage,
        source: &Path,
        backup_password: &str,
        new_password: &str,
    ) -> Result<Self> {
        if storage.exists() {
            return Err("Restore into a new wallet; an existing wallet will not be overwritten.");
        }
        let backup = encrypted_connection(source, backup_password)?;
        let (version, phrase): (i64, String) = backup
            .query_row(
                "SELECT version,mnemonic FROM chaumarchy_meta WHERE id=1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|_| "This is not a Chaumarchy backup.")?;
        let phrase = Zeroizing::new(phrase);
        if version != 1 || Mnemonic::parse(phrase.as_str()).is_err() {
            return Err("Unsupported or damaged backup.");
        }
        export_encrypted(&backup, &storage.path, new_password)?;
        Self::open(storage, new_password).await
    }
}

pub fn parse_amount(input: &str) -> Result<Amount> {
    let amount: u64 = input.parse().map_err(|_| "Enter a whole number of sats.")?;
    if amount == 0 || amount > 2_100_000_000_000_000 {
        return Err("Enter a valid positive amount in sats.");
    }
    Ok(Amount::from(amount))
}

fn export_encrypted(connection: &Connection, destination: &Path, password: &str) -> Result<()> {
    if !destination.is_absolute() {
        return Err("Choose an absolute backup file path.");
    }
    if password.chars().count() < 12 {
        return Err("Use a backup password of at least 12 characters.");
    }
    let parent = destination.parent().ok_or("Choose a backup directory.")?;
    // Publish only a complete, durable file. Restoration is already marked in
    // its encrypted metadata before publication, including after interruption.
    let file = tempfile::NamedTempFile::new_in(parent)
        .map_err(|_| "Cannot create a private backup file.")?;
    let path = file.path().to_str().ok_or("Unsupported file path.")?;
    let exported: Result<()> = (|| {
        connection
            .execute(
                "ATTACH DATABASE ?1 AS chaumarchy_backup KEY ?2",
                params![path, password],
            )
            .map_err(|_| "Cannot create the encrypted backup.")?;
        let result = connection
            .query_row("SELECT sqlcipher_export('chaumarchy_backup')", [], |_| {
                Ok(())
            })
            .map_err(|error| {
                #[cfg(test)]
                eprintln!("SQLCipher export test failure: {error}");
                #[cfg(not(test))]
                let _ = error;
                "Cannot export the encrypted backup."
            })
            .and_then(|_| {
                let raw: String = connection
                    .query_row(
                        "SELECT settings FROM chaumarchy_backup.chaumarchy_meta WHERE id=1",
                        [],
                        |row| row.get(0),
                    )
                    .map_err(|_| "Cannot read backup settings.")?;
                let mut settings: Settings =
                    serde_json::from_str(&raw).map_err(|_| "Invalid backup settings.")?;
                settings.needs_restore = true;
                let encoded = serde_json::to_string(&settings)
                    .map_err(|_| "Cannot encode backup settings.")?;
                connection
                    .execute(
                        "UPDATE chaumarchy_backup.chaumarchy_meta SET settings=?1 WHERE id=1",
                        [encoded],
                    )
                    .map_err(|_| "Cannot mark backup for recovery.")?;
                Ok(())
            });
        let detached = connection
            .execute_batch("DETACH DATABASE chaumarchy_backup")
            .map_err(|_| "Cannot finish the encrypted backup.");
        result?;
        detached?;
        file.as_file()
            .sync_all()
            .map_err(|_| "Cannot flush the backup to disk.")?;
        Ok(())
    })();
    exported?;
    file.persist_noclobber(destination)
        .map_err(|_| "Choose a new file; backups never overwrite an existing file.")?;
    File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|_| "Cannot flush the backup directory.")?;
    Ok(())
}

pub fn validate_mint_url(input: &str) -> Result<String> {
    let mut parsed = url::Url::parse(input.trim()).map_err(|_| "Enter a valid HTTPS mint URL.")?;
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
    async fn backup_has_its_own_password_and_never_overwrites() {
        let temp = tempfile::tempdir().unwrap();
        let original = Storage::new(&temp.path().join("original")).unwrap();
        let session = Session::create(&original, "original password 123")
            .await
            .unwrap();
        let phrase = session.mnemonic.to_string();
        let backup_path = temp.path().join("wallet.backup");
        session
            .export_backup(&backup_path, "backup password 456")
            .unwrap();
        assert!(!session.settings.needs_restore);
        let backup = encrypted_connection(&backup_path, "backup password 456").unwrap();
        let raw: String = backup
            .query_row("SELECT settings FROM chaumarchy_meta", [], |row| row.get(0))
            .unwrap();
        assert!(
            serde_json::from_str::<Settings>(&raw)
                .unwrap()
                .needs_restore
        );
        drop(backup);
        assert!(session
            .export_backup(&backup_path, "different password")
            .is_err());
        assert!(encrypted_connection(&backup_path, "original password 123").is_err());
        let restored = Storage::new(&temp.path().join("restored")).unwrap();
        let restored_session = Session::import_backup(
            &restored,
            &backup_path,
            "backup password 456",
            "restored password 789",
        )
        .await
        .unwrap();
        assert_eq!(restored_session.mnemonic.to_string(), phrase);
        assert!(restored_session.settings.needs_restore);
        assert!(restored_session.selected_wallet().is_err());
        assert!(Session::import_backup(
            &original,
            &backup_path,
            "backup password 456",
            "restored password 789"
        )
        .await
        .is_err());
    }

    #[tokio::test]
    async fn corrupted_backup_does_not_create_a_wallet() {
        let temp = tempfile::tempdir().unwrap();
        let storage = Storage::new(&temp.path().join("destination")).unwrap();
        let source = temp.path().join("damaged.backup");
        fs::write(&source, b"not an encrypted wallet").unwrap();
        assert!(Session::import_backup(
            &storage,
            &source,
            "backup password 123",
            "wallet password 456"
        )
        .await
        .is_err());
        assert!(!storage.exists());
    }
}
