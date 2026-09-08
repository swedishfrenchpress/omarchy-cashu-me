//! Optional password protection for the wallet's database key.
//! Device mode keeps a private local key; password mode wraps that key in
//! SQLCipher. Publication precedes removal so interruption never loses the key.
use crate::wallet::{encrypted_connection, Result};
use bip39::Mnemonic;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use zeroize::Zeroizing;

pub struct Access {
    directory: PathBuf,
}
impl Access {
    pub fn new(wallet_path: &Path) -> Self {
        Self {
            directory: wallet_path
                .parent()
                .expect("wallet has a directory")
                .to_owned(),
        }
    }
    fn device(&self) -> PathBuf {
        self.directory.join("device.key")
    }
    fn vault(&self) -> PathBuf {
        self.directory.join("access.sqlite")
    }
    pub fn password_required(&self) -> bool {
        self.vault().exists() || !self.device().exists()
    }
    fn flush(&self) -> Result<()> {
        File::open(&self.directory)
            .and_then(|file| file.sync_all())
            .map_err(|_| "Cannot flush security settings.")
    }
    fn device_key(&self) -> Result<Zeroizing<String>> {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.device())
            .map_err(|_| "Cannot read this device's wallet key.")?;
        if !file
            .metadata()
            .map_err(|_| "Cannot inspect device key.")?
            .is_file()
        {
            return Err("Invalid device key file.");
        }
        let mut key = Zeroizing::new(String::new());
        file.take(4096)
            .read_to_string(&mut key)
            .map_err(|_| "Cannot read device key.")?;
        if key.len() < 12 || key.len() >= 4096 {
            return Err("Device key is damaged.");
        }
        Ok(key)
    }
    fn save_device_key(&self, key: &str) -> Result<()> {
        if self.device().exists() {
            if self.device_key()?.as_str() == key {
                return Ok(());
            }
            return Err("A different device key already exists.");
        }
        let mut file = tempfile::NamedTempFile::new_in(&self.directory)
            .map_err(|_| "Cannot save device key.")?;
        file.write_all(key.as_bytes())
            .and_then(|_| file.as_file().sync_all())
            .map_err(|_| "Cannot flush device key.")?;
        file.persist_noclobber(self.device())
            .map_err(|_| "Cannot publish device key.")?;
        self.flush()
    }
    pub fn creation_key(&self, password: &str) -> Result<Zeroizing<String>> {
        if !password.is_empty() {
            if self.device().exists() || self.vault().exists() {
                return Err("Wallet access settings already exist. Reopen the wallet before changing its password.");
            }
            if password.chars().count() < 12 {
                return Err("Use a password of at least 12 characters.");
            }
            return Ok(Zeroizing::new(password.to_owned()));
        }
        if self.vault().exists() {
            return Err("Password protection already exists for this wallet.");
        }
        if !self.device().exists() {
            // Independent 256-bit random key, not the wallet recovery phrase.
            let key = Zeroizing::new(
                Mnemonic::generate(24)
                    .map_err(|_| "Cannot generate a device key.")?
                    .to_string(),
            );
            self.save_device_key(&key)?;
        }
        self.device_key()
    }
    pub fn unlock_key(&self, password: &str) -> Result<Zeroizing<String>> {
        if self.vault().exists() {
            let vault = encrypted_connection(&self.vault(), password)?;
            let key: String = vault
                .query_row("SELECT key FROM wallet_access WHERE id=1", [], |row| {
                    row.get(0)
                })
                .map_err(|_| "Wallet security settings are damaged.")?;
            // Complete an interrupted enable operation, with a validated vault.
            if self.device().exists() {
                fs::remove_file(self.device()).map_err(|_| "Cannot finish password protection.")?;
                self.flush()?;
            }
            return Ok(Zeroizing::new(key));
        }
        if self.device().exists() {
            return self.device_key();
        }
        // Compatibility with wallets created before optional passwords.
        Ok(Zeroizing::new(password.to_owned()))
    }
    pub fn enable(&self, key: &str, password: &str) -> Result<()> {
        if self.password_required() {
            return Err("Password protection is already enabled.");
        }
        if password.chars().count() < 12 {
            return Err("Use a password of at least 12 characters.");
        }
        let file = tempfile::NamedTempFile::new_in(&self.directory)
            .map_err(|_| "Cannot create security settings.")?;
        let vault = encrypted_connection(file.path(), password)?;
        vault.execute_batch("CREATE TABLE wallet_access (id INTEGER PRIMARY KEY CHECK(id=1), key TEXT NOT NULL)")
            .map_err(|_| "Cannot initialize password protection.")?;
        vault
            .execute("INSERT INTO wallet_access VALUES (1,?1)", [key])
            .map_err(|_| "Cannot protect wallet key.")?;
        drop(vault);
        file.as_file()
            .sync_all()
            .map_err(|_| "Cannot flush password protection.")?;
        file.persist_noclobber(self.vault())
            .map_err(|_| "Cannot publish password protection.")?;
        self.flush()?;
        fs::remove_file(self.device())
            .map_err(|_| "Password enabled; restart to finish removing the device key.")?;
        self.flush()
    }
    pub fn disable(&self, key: &str, password: &str) -> Result<()> {
        if self.unlock_key(password)?.as_str() != key {
            return Err("Incorrect wallet password.");
        }
        self.save_device_key(key)?;
        if self.vault().exists() {
            fs::remove_file(self.vault()).map_err(|_| "Cannot remove password protection.")?;
        }
        self.flush()
    }
}
