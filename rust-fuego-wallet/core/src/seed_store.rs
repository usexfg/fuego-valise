//! Encrypted storage of the walletd master seed (`master_seed.enc`).
//!
//! Layout: MAGIC(6) | mode(1) | salt(16) | m_cost u32 LE | t_cost u32 LE |
//! p_cost u32 LE | nonce(12) | ChaCha20-Poly1305(seed) (48). The whole header
//! is the AEAD associated data, so no field can be altered undetected.
//!
//! Key sources, in order:
//! - passphrase (`--passphrase-file` or `FUEGO_WALLET_PASSPHRASE`): Argon2id;
//! - otherwise a random 32-byte key held in the OS keyring.
//!
//! There is no plaintext or key-beside-the-file fallback: without a
//! passphrase and without a working keyring the wallet refuses to start.
//! A legacy plaintext `master_seed.bin` is encrypted, verified, then
//! overwritten with zeros and removed.

use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::ChaCha20Poly1305;
use rand::rngs::OsRng;
use rand::RngCore;
use std::io::Write;
use std::path::{Path, PathBuf};
use zeroize::{Zeroize, Zeroizing};

const MAGIC: &[u8; 6] = b"FSEED1";
const MODE_KEYRING: u8 = 1;
const MODE_PASSPHRASE: u8 = 2;
const HEADER_LEN: usize = 6 + 1 + 16 + 12 + 12;
const SEALED_LEN: usize = 32 + 16;

// Argon2id parameters for new files: 64 MiB, 3 passes, 1 lane.
const M_COST: u32 = 64 * 1024;
const T_COST: u32 = 3;
const P_COST: u32 = 1;

const KEYRING_SERVICE: &str = "fuego-walletd";

pub const ENCRYPTED_FILE: &str = "master_seed.enc";
pub const LEGACY_PLAINTEXT_FILE: &str = "master_seed.bin";

/// Where the seed key comes from.
pub enum SeedKeySource {
    Passphrase(Zeroizing<String>),
    Keyring,
}

impl SeedKeySource {
    /// Passphrase from `passphrase_file` (first line) or FUEGO_WALLET_PASSPHRASE,
    /// else the OS keyring.
    pub fn resolve(passphrase_file: Option<&Path>) -> Result<Self, String> {
        if let Some(path) = passphrase_file {
            let raw = Zeroizing::new(
                std::fs::read_to_string(path).map_err(|e| format!("read passphrase file: {e}"))?,
            );
            let line = raw.lines().next().unwrap_or("").to_string();
            if line.is_empty() {
                return Err("passphrase file is empty".into());
            }
            return Ok(SeedKeySource::Passphrase(Zeroizing::new(line)));
        }
        if let Ok(p) = std::env::var("FUEGO_WALLET_PASSPHRASE") {
            if !p.is_empty() {
                return Ok(SeedKeySource::Passphrase(Zeroizing::new(p)));
            }
        }
        Ok(SeedKeySource::Keyring)
    }
}

fn keyring_account(wallet_dir: &Path) -> String {
    // One key per wallet directory.
    let canonical = wallet_dir.canonicalize().unwrap_or_else(|_| wallet_dir.to_path_buf());
    format!("seed-key:{}", hex::encode(&fuego_crypto::cn_fast_hash(canonical.to_string_lossy().as_bytes())[..16]))
}

fn keyring_key(wallet_dir: &Path, create: bool) -> Result<Zeroizing<[u8; 32]>, String> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, &keyring_account(wallet_dir))
        .map_err(|e| format!("OS keyring unavailable ({e}); set --passphrase-file or FUEGO_WALLET_PASSPHRASE"))?;
    match entry.get_password() {
        Ok(stored) => {
            let stored = Zeroizing::new(stored);
            let bytes = Zeroizing::new(hex::decode(stored.trim()).map_err(|_| "corrupt keyring entry".to_string())?);
            if bytes.len() != 32 {
                return Err("corrupt keyring entry".into());
            }
            let mut key = Zeroizing::new([0u8; 32]);
            key.copy_from_slice(&bytes);
            Ok(key)
        }
        Err(keyring::Error::NoEntry) if create => {
            let mut key = Zeroizing::new([0u8; 32]);
            OsRng.fill_bytes(key.as_mut());
            entry
                .set_password(&hex::encode(key.as_ref()))
                .map_err(|e| format!("OS keyring write failed ({e}); set --passphrase-file or FUEGO_WALLET_PASSPHRASE"))?;
            // Read back: some backends accept writes they cannot return.
            let check = keyring_key(wallet_dir, false)?;
            if check.as_ref() != key.as_ref() {
                return Err("OS keyring did not persist the seed key".into());
            }
            Ok(key)
        }
        Err(e) => Err(format!(
            "seed key not readable from the OS keyring ({e}); set --passphrase-file or FUEGO_WALLET_PASSPHRASE"
        )),
    }
}

fn argon2_key(passphrase: &str, salt: &[u8; 16], m: u32, t: u32, p: u32) -> Result<Zeroizing<[u8; 32]>, String> {
    let params = Params::new(m, t, p, Some(32)).map_err(|e| format!("argon2 params: {e}"))?;
    let mut key = Zeroizing::new([0u8; 32]);
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(passphrase.as_bytes(), salt, key.as_mut())
        .map_err(|e| format!("argon2: {e}"))?;
    Ok(key)
}

fn seal(seed: &[u8; 32], source: &SeedKeySource, wallet_dir: &Path) -> Result<Vec<u8>, String> {
    let mut salt = [0u8; 16];
    let mut nonce = [0u8; 12];
    OsRng.fill_bytes(&mut salt);
    OsRng.fill_bytes(&mut nonce);
    let (mode, key) = match source {
        SeedKeySource::Passphrase(p) => (MODE_PASSPHRASE, argon2_key(p, &salt, M_COST, T_COST, P_COST)?),
        SeedKeySource::Keyring => (MODE_KEYRING, keyring_key(wallet_dir, true)?),
    };
    let mut header = Vec::with_capacity(HEADER_LEN);
    header.extend_from_slice(MAGIC);
    header.push(mode);
    header.extend_from_slice(&salt);
    header.extend_from_slice(&M_COST.to_le_bytes());
    header.extend_from_slice(&T_COST.to_le_bytes());
    header.extend_from_slice(&P_COST.to_le_bytes());
    header.extend_from_slice(&nonce);
    let sealed = ChaCha20Poly1305::new_from_slice(key.as_ref()).map_err(|_| "seed key length".to_string())?
        .encrypt(&nonce.into(), Payload { msg: seed, aad: &header })
        .map_err(|_| "seed encryption failed".to_string())?;
    let mut out = header;
    out.extend_from_slice(&sealed);
    Ok(out)
}

fn open(data: &[u8], source: &SeedKeySource, wallet_dir: &Path) -> Result<Zeroizing<[u8; 32]>, String> {
    if data.len() != HEADER_LEN + SEALED_LEN || &data[..6] != MAGIC {
        return Err("master_seed.enc is not a Fuego seed file".into());
    }
    let (header, sealed) = data.split_at(HEADER_LEN);
    let mode = header[6];
    let mut salt = [0u8; 16];
    salt.copy_from_slice(&header[7..23]);
    let word = |at: usize| u32::from_le_bytes(header[at..at + 4].try_into().unwrap());
    let (m, t, p) = (word(23), word(27), word(31));
    let mut nonce = [0u8; 12];
    nonce.copy_from_slice(&header[35..47]);
    let key = match (mode, source) {
        (MODE_PASSPHRASE, SeedKeySource::Passphrase(pass)) => argon2_key(pass, &salt, m, t, p)?,
        (MODE_PASSPHRASE, SeedKeySource::Keyring) => {
            return Err("seed is passphrase-protected: set --passphrase-file or FUEGO_WALLET_PASSPHRASE".into())
        }
        (MODE_KEYRING, _) => keyring_key(wallet_dir, false)?,
        _ => return Err("unknown seed protection mode".into()),
    };
    let plain = Zeroizing::new(
        ChaCha20Poly1305::new_from_slice(key.as_ref()).map_err(|_| "seed key length".to_string())?
            .decrypt(&nonce.into(), Payload { msg: sealed, aad: header })
            .map_err(|_| "wrong passphrase or corrupted master_seed.enc".to_string())?,
    );
    if plain.len() != 32 {
        return Err("corrupted master_seed.enc".into());
    }
    let mut seed = Zeroizing::new([0u8; 32]);
    seed.copy_from_slice(&plain);
    Ok(seed)
}

/// Write `data` to `path` atomically (temp file, fsync, rename) with 0600 permissions.
fn write_private(path: &Path, data: &[u8]) -> Result<(), String> {
    let tmp = path.with_extension("enc.tmp");
    {
        let mut opts = std::fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut f = opts.open(&tmp).map_err(|e| format!("create {}: {e}", tmp.display()))?;
        f.write_all(data).map_err(|e| format!("write seed: {e}"))?;
        f.sync_all().map_err(|e| format!("sync seed: {e}"))?;
    }
    std::fs::rename(&tmp, path).map_err(|e| format!("install seed file: {e}"))?;
    if let Some(dir) = path.parent() {
        if let Ok(d) = std::fs::File::open(dir) {
            let _ = d.sync_all();
        }
    }
    Ok(())
}

/// Overwrite a legacy plaintext seed with zeros, sync, then unlink it.
fn wipe_plaintext(path: &Path) -> Result<(), String> {
    let len = std::fs::metadata(path).map(|m| m.len() as usize).unwrap_or(32);
    {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .open(path)
            .map_err(|e| format!("open plaintext seed for wiping: {e}"))?;
        f.write_all(&vec![0u8; len.max(32)]).map_err(|e| format!("wipe plaintext seed: {e}"))?;
        f.sync_all().map_err(|e| format!("sync wiped seed: {e}"))?;
    }
    std::fs::remove_file(path).map_err(|e| format!("remove plaintext seed: {e}"))
}

pub fn encrypted_path(wallet_dir: &Path) -> PathBuf {
    wallet_dir.join(ENCRYPTED_FILE)
}

/// Load the master seed, creating one on first run and migrating a legacy
/// plaintext `master_seed.bin`.
pub fn load_or_create(wallet_dir: &Path, source: &SeedKeySource) -> Result<Zeroizing<[u8; 32]>, String> {
    let enc = encrypted_path(wallet_dir);
    let legacy = wallet_dir.join(LEGACY_PLAINTEXT_FILE);

    if enc.exists() {
        let data = std::fs::read(&enc).map_err(|e| format!("read {}: {e}", enc.display()))?;
        let seed = open(&data, source, wallet_dir)?;
        if legacy.exists() {
            // A previous migration stopped before the wipe.
            let mut old = std::fs::read(&legacy).map_err(|e| format!("read legacy seed: {e}"))?;
            let same = old.len() == 32 && old[..] == seed[..];
            old.zeroize();
            if !same {
                return Err(format!(
                    "{} and {} hold different seeds; move one away before starting",
                    enc.display(),
                    legacy.display()
                ));
            }
            wipe_plaintext(&legacy)?;
            log::warn!("Wiped leftover plaintext {}", legacy.display());
        }
        return Ok(seed);
    }

    let seed = if legacy.exists() {
        let mut old = std::fs::read(&legacy).map_err(|e| format!("read legacy seed: {e}"))?;
        if old.len() != 32 {
            old.zeroize();
            return Err(format!("{} is not a 32-byte seed", legacy.display()));
        }
        let mut seed = Zeroizing::new([0u8; 32]);
        seed.copy_from_slice(&old);
        old.zeroize();
        seed
    } else {
        let mut seed = Zeroizing::new([0u8; 32]);
        OsRng.fill_bytes(seed.as_mut());
        seed
    };

    let sealed = seal(&seed, source, wallet_dir)?;
    write_private(&enc, &sealed)?;
    // Verify the file opens before any plaintext is destroyed.
    let written = std::fs::read(&enc).map_err(|e| format!("re-read seed: {e}"))?;
    let check = open(&written, source, wallet_dir)?;
    if check[..] != seed[..] {
        return Err("encrypted seed verification failed; plaintext left untouched".into());
    }
    if legacy.exists() {
        wipe_plaintext(&legacy)?;
        log::info!("Migrated {} to encrypted {}", legacy.display(), enc.display());
    } else {
        log::info!("Created new encrypted wallet seed at {}", enc.display());
    }
    Ok(seed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pass(p: &str) -> SeedKeySource {
        SeedKeySource::Passphrase(Zeroizing::new(p.to_string()))
    }

    #[test]
    fn passphrase_roundtrip_and_wrong_passphrase() {
        let dir = tempfile::tempdir().unwrap();
        let seed = load_or_create(dir.path(), &pass("correct horse")).unwrap();
        let again = load_or_create(dir.path(), &pass("correct horse")).unwrap();
        assert_eq!(seed[..], again[..]);
        let err = load_or_create(dir.path(), &pass("wrong")).unwrap_err();
        assert!(err.contains("wrong passphrase"), "{err}");
        let raw = std::fs::read(encrypted_path(dir.path())).unwrap();
        assert_eq!(raw.len(), HEADER_LEN + SEALED_LEN);
        assert!(!raw.windows(32).any(|w| w == &seed[..]), "seed must not appear in the file");
    }

    #[test]
    fn migrates_and_wipes_plaintext_seed() {
        let dir = tempfile::tempdir().unwrap();
        let legacy = dir.path().join(LEGACY_PLAINTEXT_FILE);
        std::fs::write(&legacy, [7u8; 32]).unwrap();
        let seed = load_or_create(dir.path(), &pass("pw")).unwrap();
        assert_eq!(seed[..], [7u8; 32]);
        assert!(!legacy.exists());
        assert!(encrypted_path(dir.path()).exists());
    }

    #[test]
    fn header_tampering_is_rejected() {
        let dir = tempfile::tempdir().unwrap();
        load_or_create(dir.path(), &pass("pw")).unwrap();
        let path = encrypted_path(dir.path());
        let mut raw = std::fs::read(&path).unwrap();
        raw[27] ^= 1; // t_cost
        std::fs::write(&path, &raw).unwrap();
        assert!(load_or_create(dir.path(), &pass("pw")).is_err());
    }

    #[test]
    fn passphrase_file_requires_keyring_free_mode() {
        let dir = tempfile::tempdir().unwrap();
        load_or_create(dir.path(), &pass("pw")).unwrap();
        let err = load_or_create(dir.path(), &SeedKeySource::Keyring).unwrap_err();
        assert!(err.contains("passphrase-protected"), "{err}");
    }
}
