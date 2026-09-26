use crate::error::{Result, SdkError};
use fuego_crypto as crypto;
use fuego_vault::Vault;
use std::path::PathBuf;

/// Encrypted vault wrapper for key management and guardian recovery
pub struct WalletVault {
    inner: Vault,
}

impl WalletVault {
    pub fn generate() -> Self {
        Self {
            inner: Vault::generate(),
        }
    }

    pub fn from_seed(seed: [u8; 32]) -> Self {
        Self {
            inner: Vault::new(seed),
        }
    }

    pub fn load(path: PathBuf, passphrase: &[u8]) -> Result<Self> {
        let vault = Vault::load(path, passphrase)
            .map_err(|e| SdkError::Vault(format!("Failed to load vault: {e}")))?;
        Ok(Self { inner: vault })
    }

    pub fn save(&self, path: PathBuf, passphrase: &[u8]) -> Result<()> {
        self.inner
            .save(path, passphrase)
            .map_err(|e| SdkError::Vault(format!("Failed to save vault: {e}")))
    }

    pub fn master_seed(&self) -> [u8; 32] {
        self.inner.master_seed
    }

    pub fn derive_keypair(&self, index: u32) -> crypto::Keypair {
        self.inner.derive_keypair(index)
    }

    pub fn get_address(&self, index: u32) -> crypto::Address {
        self.inner.get_address(index)
    }

    pub fn add_guardian(&mut self, address: crypto::Address) -> Result<()> {
        self.inner.add_guardian(address).map_err(SdkError::Vault)
    }

    pub fn initiate_recovery(&self, new_public_key: [u8; 32]) -> fuego_vault::RecoveryRequest {
        self.inner.initiate_recovery(new_public_key)
    }

    pub fn verify_recovery(&self, request: &fuego_vault::RecoveryRequest) -> Result<bool> {
        self.inner.verify_recovery(request).map_err(SdkError::Vault)
    }

    pub fn finalize_recovery(&mut self, request: fuego_vault::RecoveryRequest) -> Result<()> {
        self.inner
            .finalize_recovery(request)
            .map_err(SdkError::Vault)
    }

    pub fn display_name(&self) -> Option<&str> {
        self.inner.display_name.as_deref()
    }

    pub fn set_display_name(&mut self, name: String) {
        self.inner.set_display_name(name);
    }

    pub fn guardians(&self) -> &[crypto::Address] {
        &self.inner.guardians
    }

    pub fn recovery_threshold(&self) -> u8 {
        self.inner.recovery_threshold
    }
}

impl Default for WalletVault {
    fn default() -> Self {
        Self::generate()
    }
}
