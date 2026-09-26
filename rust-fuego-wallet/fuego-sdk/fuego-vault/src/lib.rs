use fuego_crypto::{Keypair, Address, make_address};
use serde::{Serialize, Deserialize};
use std::path::PathBuf;
use std::fs;
use curve25519_dalek::scalar::Scalar;
use curve25519_dalek::constants::RISTRETTO_BASEPOINT_TABLE;
use sha3::{Digest, Keccak256};
use rand::rngs::OsRng;
use rand::RngCore;
use std::ops::Mul;
use chacha20poly1305::{AeadCore, AeadInPlace, ChaCha20Poly1305, KeyInit};
use zeroize::{Zeroize, ZeroizeOnDrop};

pub mod recovery;
pub use recovery::RecoveryRequest;

const VAULT_FILE_VERSION: u8 = 1;

#[derive(Debug, Clone, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
pub struct Vault {
    pub master_seed: [u8; 32],
    #[zeroize(skip)]
    pub encrypted_backup: Option<Vec<u8>>,
    #[zeroize(skip)]
    pub display_name: Option<String>,
    #[zeroize(skip)]
    pub guardians: Vec<Address>,
    #[zeroize(skip)]
    pub recovery_threshold: u8,
    /// Unused. Kept so serialized vaults keep their layout; sub-addresses follow
    /// fuego-suite's scheme (fuego_crypto::derive_subaddress_keys) and walletd
    /// tracks how many were handed out.
    #[zeroize(skip)]
    pub subaddress_count: u32,
}

impl Vault {
    /// Create vault from a raw 32-byte seed.
    pub fn new(seed: [u8; 32]) -> Self {
        Vault {
            master_seed: seed,
            encrypted_backup: None,
            display_name: None,
            guardians: Vec::new(),
            recovery_threshold: 0,
            subaddress_count: 0,
        }
    }

    /// Generate a fresh random vault.
    pub fn generate() -> Self {
        let mut seed = [0u8; 32];
        OsRng.fill_bytes(&mut seed);
        Self::new(seed)
    }

    /// Derive a keypair: hash(seed || index) as the secret key.
    pub fn derive_keypair(&self, index: u32) -> Keypair {
        let mut hasher = Keccak256::new();
        hasher.update(&self.master_seed);
        hasher.update(index.to_le_bytes());
        let hash = hasher.finalize();
        let mut secret = [0u8; 32];
        secret.copy_from_slice(&hash);
        Keypair::from_secret(secret)
    }

    /// Address built from keypairs `index` (spend) and `index + 1` (view).
    /// Index 0 is the primary address. Other indices are the pre-suite-scheme
    /// "sub-addresses": independent keypairs that overlap their neighbours
    /// (index n's view key is index n+1's spend key). Only for recovering
    /// funds sent to them; never hand one out.
    pub fn get_address(&self, index: u32) -> Address {
        let spend_kp = self.derive_keypair(index);
        let view_kp = self.derive_keypair(index + 1);
        make_address(&spend_kp.public, &view_kp.public)
    }

    pub fn set_display_name(&mut self, name: String) {
        self.display_name = Some(name);
    }

    pub fn add_guardian(&mut self, address: Address) -> Result<(), String> {
        if self.guardians.contains(&address) {
            return Err("Guardian already exists".to_string());
        }
        self.guardians.push(address);
        self.recovery_threshold = ((self.guardians.len() * 2 + 1) / 3).max(1) as u8;
        Ok(())
    }

    pub fn remove_guardian(&mut self, address: &Address) -> Result<(), String> {
        let pos = self.guardians.iter().position(|a| a == address)
            .ok_or("Guardian not found")?;
        self.guardians.remove(pos);
        self.recovery_threshold = ((self.guardians.len() * 2 + 1) / 3).max(1) as u8;
        Ok(())
    }

    pub fn set_recovery_threshold(&mut self, threshold: u8) -> Result<(), String> {
        if threshold == 0 || threshold > self.guardians.len() as u8 {
            return Err("Invalid threshold".to_string());
        }
        self.recovery_threshold = threshold;
        Ok(())
    }

    pub fn verify_recovery(&self, request: &RecoveryRequest) -> Result<bool, String> {
        if !request.is_complete() {
            return Err("Recovery request not complete: not enough signatures".to_string());
        }
        for sig in &request.signatures {
            if !self.guardians.contains(&sig.guardian_address) {
                return Err(format!("Signature from non-guardian: {}", sig.guardian_address));
            }
        }
        Ok(true)
    }

    pub fn finalize_recovery(&mut self, request: RecoveryRequest) -> Result<(), String> {
        self.verify_recovery(&request)?;
        let mut hasher = Keccak256::new();
        hasher.update(self.master_seed);
        hasher.update(request.new_public_key);
        let new_seed: [u8; 32] = hasher.finalize().into();
        self.master_seed = new_seed;
        self.guardians.clear();
        self.recovery_threshold = 0;
        Ok(())
    }

    pub fn initiate_recovery(&self, new_public_key: [u8; 32]) -> RecoveryRequest {
        let mut hasher = Keccak256::new();
        hasher.update(&self.master_seed);
        let old_root: [u8; 32] = hasher.finalize().into();
        RecoveryRequest::new(old_root, new_public_key, self.recovery_threshold)
    }

    /// Save vault with ChaCha20Poly1305 encryption using passphrase.
    pub fn save(&self, path: PathBuf, passphrase: &[u8]) -> Result<(), std::io::Error> {
        let mut plaintext = bincode::serialize(self).map_err(std::io::Error::other)?;

        let mut key = [0u8; 32];
        let mut hasher = Keccak256::new();
        hasher.update(passphrase);
        hasher.update(b"fuego-vault-v1");
        key.copy_from_slice(&hasher.finalize());

        let cipher = ChaCha20Poly1305::new((&key).into());
        let nonce = ChaCha20Poly1305::generate_nonce(&mut OsRng);
        cipher
            .encrypt_in_place(&nonce, b"", &mut plaintext)
            .map_err(|e| std::io::Error::other(format!("Encryption failed: {}", e)))?;

        let mut output = Vec::with_capacity(1 + 12 + plaintext.len());
        output.push(VAULT_FILE_VERSION);
        output.extend_from_slice(nonce.as_slice());
        output.extend_from_slice(&plaintext);

        key.zeroize();

        fs::write(path, output)
    }

    /// Load vault with ChaCha20Poly1305 decryption using passphrase.
    pub fn load(path: PathBuf, passphrase: &[u8]) -> Result<Self, std::io::Error> {
        let data = fs::read(path)?;
        if data.len() < 13 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "Vault file too short",
            ));
        }

        let version = data[0];
        if version != VAULT_FILE_VERSION {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("Unsupported vault version: {}", version),
            ));
        }

        let nonce = &data[1..13];
        let ciphertext = &data[13..];

        let mut key = [0u8; 32];
        let mut hasher = Keccak256::new();
        hasher.update(passphrase);
        hasher.update(b"fuego-vault-v1");
        key.copy_from_slice(&hasher.finalize());

        let cipher = ChaCha20Poly1305::new((&key).into());
        let nonce_arr: [u8; 12] = nonce.try_into().map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, "Invalid nonce length")
        })?;
        let mut plaintext = ciphertext.to_vec();
        cipher
            .decrypt_in_place(nonce_arr.as_ref().into(), b"", &mut plaintext)
            .map_err(|_| {
                std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Decryption failed (wrong passphrase or corrupted vault)",
                )
            })?;

        key.zeroize();

        bincode::deserialize(&plaintext).map_err(std::io::Error::other)
    }

    /// Unencrypted save (for FFI backward compatibility).
    pub fn save_unencrypted(&self, path: PathBuf) -> Result<(), std::io::Error> {
        let data = bincode::serialize(self).map_err(std::io::Error::other)?;
        fs::write(path, data)
    }

    /// Unencrypted load (for FFI backward compatibility).
    pub fn load_unencrypted(path: PathBuf) -> Result<Self, std::io::Error> {
        let data = fs::read(path)?;
        bincode::deserialize(&data).map_err(std::io::Error::other)
    }
}

// --- Atomic Swap Implementation ---

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SwapParams {
    pub counterparty_address: Address,
    pub xfg_amount: u64,
    pub counterparty_chain: String,
    pub counterparty_amount: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SwapInfo {
    pub swap_id: String,
    pub escrow_pubkey: [u8; 32],
    pub adaptor_point: [u8; 32],
    pub xfg_amount: u64,
    pub counterparty_amount: u64,
    pub counterparty_chain: String,
    pub tx_hash: String,
    pub created_at: u64,
    pub expires_at: u64,
}

pub struct AtomicSwap;

impl AtomicSwap {
    pub fn initiate(vault: &Vault, index: u32, params: SwapParams) -> Result<SwapInfo, String> {
        let kp = vault.derive_keypair(index);
        
        let mut seed = [0u8; 32];
        OsRng.fill_bytes(&mut seed);
        let secret = Scalar::from_bytes_mod_order(seed);
        let adaptor_point = RISTRETTO_BASEPOINT_TABLE.mul(&secret);
        
        let tx_hash = hex::encode(Keccak256::digest(adaptor_point.compress().as_bytes()));
        
        Ok(SwapInfo {
            swap_id: tx_hash.clone(),
            escrow_pubkey: kp.public,
            adaptor_point: *adaptor_point.compress().as_bytes(),
            xfg_amount: params.xfg_amount,
            counterparty_amount: params.counterparty_amount,
            counterparty_chain: params.counterparty_chain,
            tx_hash,
            created_at: std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs(),
            expires_at: std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() + 86400,
        })
    }

    pub fn extract_secret(_pre_sig: &[u8], _final_sig: &[u8], _adaptor_point: &[u8]) -> Result<Vec<u8>, String> {
        Ok(vec![0u8; 32])
    }
}
