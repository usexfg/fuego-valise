use crate::error::{Result, SdkError};
use crate::scanner::{
    CommitmentEntry, HistoryEntry, ScannerStateSnapshot, UtxoEntry, UtxoScanner, WalletKeys,
};
use crate::serialization::TransactionPrefix;
use crate::transaction_builder::{BuiltTransaction, DecoyEntry};
use crate::types::*;
use crate::vault::WalletVault;
use crate::chain::{ChainSpv, PaymentProof};
use sha2::{Sha256, Digest};
use std::path::PathBuf;

pub struct Wallet {
    pub(crate) scanner: UtxoScanner,
}

impl Wallet {
    pub fn generate() -> Result<Self> {
        Ok(Self {
            scanner: UtxoScanner::new(WalletVault::generate()),
        })
    }

    pub fn from_seed(seed: [u8; 32]) -> Result<Self> {
        Ok(Self {
            scanner: UtxoScanner::new(WalletVault::from_seed(seed)),
        })
    }

    pub(crate) fn from_vault(vault: WalletVault) -> Self {
        Self {
            scanner: UtxoScanner::new(vault),
        }
    }

    pub fn load(path: PathBuf, passphrase: &[u8]) -> Result<Self> {
        let vault = WalletVault::load(path, passphrase)?;
        Ok(Self {
            scanner: UtxoScanner::new(vault),
        })
    }

    pub fn save(&self, path: PathBuf, passphrase: &[u8]) -> Result<()> {
        self.scanner.vault().save(path, passphrase)
    }

    pub fn primary_address(&self) -> Address {
        self.get_address(0)
    }

    pub fn get_address(&self, index: u32) -> Address {
        let addr = self.scanner.vault().get_address(index);
        Address(addr.0)
    }

    pub fn get_keypair(&self, index: u32) -> Keypair {
        let kp = self.scanner.vault().derive_keypair(index);
        Keypair {
            secret: SecretKey(kp.secret),
            public: PublicKey(kp.public),
        }
    }

    pub fn balance(&self) -> Balance {
        self.scanner.balance()
    }

    pub fn height(&self) -> u64 {
        self.scanner.height()
    }

    pub fn wallet_keys(&self) -> WalletKeys {
        self.scanner.wallet_keys()
    }

    pub fn scan_tx_prefix(
        &self,
        tx_hash: &[u8; 32],
        prefix: &TransactionPrefix,
        block_height: u64,
    ) -> Result<(u64, u64)> {
        self.scanner.scan_tx_prefix(tx_hash, prefix, block_height)
    }

    pub fn attach_global_indices(&self, tx_hash: &[u8; 32], indices: &[u64]) {
        self.scanner.attach_global_indices(tx_hash, indices);
    }

    pub fn select_for_send(
        &self,
        total_needed: u64,
        rng: &mut impl rand::RngCore,
    ) -> Result<Vec<UtxoEntry>> {
        self.scanner.select_for_send(total_needed, rng)
    }

    pub fn build_with_selection(
        &self,
        selected: &[UtxoEntry],
        destinations: &[(Address, u64)],
        fee: u64,
        mixin: usize,
        decoys: &[Vec<DecoyEntry>],
        rng: &mut impl rand::RngCore,
    ) -> Result<BuiltTransaction> {
        self.scanner
            .build_with_selection(selected, destinations, fee, mixin, decoys, rng)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn build_with_selection_ext(
        &self,
        selected: &[UtxoEntry],
        destinations: &[(Address, u64)],
        fee: u64,
        mixin: usize,
        decoys: &[Vec<DecoyEntry>],
        unlock_time: u64,
        extra_extra: &[u8],
        rng: &mut impl rand::RngCore,
    ) -> Result<BuiltTransaction> {
        self.scanner.build_with_selection_ext(
            selected,
            destinations,
            fee,
            mixin,
            decoys,
            unlock_time,
            extra_extra,
            rng,
        )
    }

    pub fn deposits(&self) -> Vec<CommitmentEntry> {
        self.scanner.deposits()
    }

    pub fn heat_outputs(&self) -> Vec<CommitmentEntry> {
        self.scanner.heat_outputs()
    }

    pub fn reserve_pending(&self, key_images: &[[u8; 32]]) {
        self.scanner.reserve_pending(key_images);
    }

    pub fn snapshot_state(&self) -> ScannerStateSnapshot {
        self.scanner.snapshot()
    }

    pub fn restore_state(&self, snapshot: &ScannerStateSnapshot) {
        self.scanner.restore(snapshot);
    }

    pub fn get_transactions(&self, limit: usize) -> Vec<HistoryEntry> {
        self.scanner.history(limit)
    }

    pub fn utxos(&self) -> Vec<UtxoEntry> {
        self.scanner.utxos()
    }

    pub fn set_height(&self, height: u64) {
        self.scanner.set_height(height);
    }

    pub fn add_guardian(&self, _address: Address) -> Result<()> {
        Err(SdkError::Vault(
            "Use vault_mut().add_guardian() for guardian management".into(),
        ))
    }

    pub fn vault(&self) -> &WalletVault {
        self.scanner.vault()
    }

    pub fn vault_mut(&mut self) -> &mut WalletVault {
        self.scanner.vault_mut()
    }

    // ── HTLC (Hash Time-Locked Contract) ────────────────────────────

    /// Create a hash lock (preimage + hash) for an HTLC.
    /// Returns (preimage, hash_hex).
    pub fn create_htlc_hash_lock() -> ([u8; 32], String) {
        let mut preimage = [0u8; 32];
        use rand::RngCore;
        rand::thread_rng().fill_bytes(&mut preimage);
        let hash = Sha256::digest(preimage);
        let hash_hex = hex::encode(hash);
        (preimage, hash_hex)
    }

    /// Build an HTLC redeem script for Bitcoin-family chains.
    ///
    /// Script: OP_SHA256 <32-byte hash> OP_EQUALVERIFY
    ///         <33-byte recipient pubkey> OP_CHECKSIG
    ///         OP_IFDUP OP_NOTIF
    ///           <4-byte timelock (LE)> OP_CHECKLOCKTIMEVERIFY OP_DROP
    ///           <33-byte sender pubkey> OP_CHECKSIG
    ///         OP_ENDIF
    pub fn build_htlc_script(
        hash_lock: &str,
        recipient_pubkey: &str,
        sender_pubkey: &str,
        timelock: u64,
    ) -> Result<Vec<u8>> {
        // Validate inputs
        let hash_bytes = hex::decode(hash_lock)
            .map_err(|e| SdkError::Serialization(format!("Invalid hash_lock hex: {e}")))?;
        if hash_bytes.len() != 32 {
            return Err(SdkError::Serialization(format!(
                "hash_lock must be 32 bytes, got {}", hash_bytes.len()
            )));
        }

        let recv_bytes = hex::decode(recipient_pubkey)
            .map_err(|e| SdkError::Serialization(format!("Invalid recipient_pubkey hex: {e}")))?;
        if recv_bytes.len() != 33 {
            return Err(SdkError::Serialization(format!(
                "recipient_pubkey must be 33 bytes (compressed), got {}", recv_bytes.len()
            )));
        }

        let send_bytes = hex::decode(sender_pubkey)
            .map_err(|e| SdkError::Serialization(format!("Invalid sender_pubkey hex: {e}")))?;
        if send_bytes.len() != 33 {
            return Err(SdkError::Serialization(format!(
                "sender_pubkey must be 33 bytes (compressed), got {}", send_bytes.len()
            )));
        }

        if timelock > u32::MAX as u64 {
            return Err(SdkError::Serialization(format!(
                "timelock must fit in 4 bytes, got {timelock}"
            )));
        }

        let mut script = Vec::new();

        // OP_SHA256 <hash_lock:32 bytes> OP_EQUALVERIFY
        script.push(0xa8); // OP_SHA256
        script.push(0x20); // push 32 bytes
        script.extend_from_slice(&hash_bytes);
        script.push(0x87); // OP_EQUALVERIFY

        // <recipient_pubkey:33 bytes> OP_CHECKSIG
        script.push(0x21); // push 33 bytes
        script.extend_from_slice(&recv_bytes);
        script.push(0xac); // OP_CHECKSIG

        // OP_IFDUP OP_NOTIF <timelock:4 bytes LE> OP_CHECKLOCKTIMEVERIFY OP_DROP
        //     <sender_pubkey:33 bytes> OP_CHECKSIG
        // OP_ENDIF
        script.push(0x75); // OP_IFDUP
        script.push(0x63); // OP_NOTIF

        // Timelock as 4-byte little-endian
        let tl_bytes = (timelock as u32).to_le_bytes();
        script.push(0x04); // push 4 bytes
        script.extend_from_slice(&tl_bytes);
        script.push(0xb1); // OP_CHECKLOCKTIMEVERIFY
        script.push(0x75); // OP_DROP

        // <sender_pubkey:33 bytes> OP_CHECKSIG
        script.push(0x21); // push 33 bytes
        script.extend_from_slice(&send_bytes);
        script.push(0xac); // OP_CHECKSIG

        script.push(0x68); // OP_ENDIF

        Ok(script)
    }

    /// Verify a payment on any supported chain using SPV.
    pub async fn verify_payment(
        chain_spv: &dyn ChainSpv,
        tx_hash: &str,
        from_address: &str,
        to_address: &str,
        amount: u128,
        min_confirmations: u32,
    ) -> Result<PaymentProof> {
        let proof = chain_spv.build_payment_proof(tx_hash, from_address, to_address, amount).await?;
        let verified = chain_spv.verify_payment_proof(&proof, min_confirmations).await?;
        let mut proof = proof;
        proof.verified = verified;
        Ok(proof)
    }
}
