use crate::error::{Result, SdkError};
use crate::scanner::{
    BalanceBreakdown, CommitmentEntry, HistoryEntry, ScannerStateSnapshot, UtxoEntry, UtxoScanner,
    WalletKeys,
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

    pub fn scan_tx_prefix_at(
        &self,
        tx_hash: &[u8; 32],
        prefix: &TransactionPrefix,
        block_height: u64,
        block_timestamp: u64,
    ) -> Result<(u64, u64)> {
        self.scanner
            .scan_tx_prefix_at(tx_hash, prefix, block_height, block_timestamp)
    }

    pub fn balance_breakdown(&self) -> BalanceBreakdown {
        self.scanner.balance_breakdown()
    }

    pub fn spendable_heat_outputs(&self) -> Vec<CommitmentEntry> {
        self.scanner.spendable_heat_outputs()
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

    /// HTLC redeem script for Bitcoin-family chains, byte-identical to the
    /// suite's LtcHtlcScript::createHashTimeLockScript:
    ///
    /// OP_IF OP_SHA256 <hash:32> OP_EQUALVERIFY <recipient:33> OP_CHECKSIG
    /// OP_ELSE <timelock:scriptnum> OP_CHECKLOCKTIMEVERIFY OP_DROP
    ///         <sender:33> OP_CHECKSIG
    /// OP_ENDIF
    pub fn build_htlc_script(
        hash_lock: &str,
        recipient_pubkey: &str,
        sender_pubkey: &str,
        timelock: u64,
    ) -> Result<Vec<u8>> {
        fn decode(name: &str, value: &str, len: usize) -> Result<Vec<u8>> {
            let bytes = hex::decode(value)
                .map_err(|e| SdkError::Serialization(format!("Invalid {name} hex: {e}")))?;
            if bytes.len() != len {
                return Err(SdkError::Serialization(format!(
                    "{name} must be {len} bytes, got {}",
                    bytes.len()
                )));
            }
            Ok(bytes)
        }
        let hash = decode("hash_lock", hash_lock, 32)?;
        let recipient = decode("recipient_pubkey", recipient_pubkey, 33)?;
        let sender = decode("sender_pubkey", sender_pubkey, 33)?;
        let timelock = u32::try_from(timelock).map_err(|_| {
            SdkError::Serialization(format!("timelock must fit in 32 bits, got {timelock}"))
        })?;

        const OP_IF: u8 = 0x63;
        const OP_ELSE: u8 = 0x67;
        const OP_ENDIF: u8 = 0x68;
        const OP_DROP: u8 = 0x75;
        const OP_EQUALVERIFY: u8 = 0x88;
        const OP_SHA256: u8 = 0xa8;
        const OP_CHECKSIG: u8 = 0xac;
        const OP_CHECKLOCKTIMEVERIFY: u8 = 0xb1;

        fn push(script: &mut Vec<u8>, data: &[u8]) {
            if data.is_empty() {
                script.push(0x00);
            } else {
                script.push(data.len() as u8);
                script.extend_from_slice(data);
            }
        }
        // CScriptNum: minimal little-endian, sign byte when the top bit is set.
        let mut lock = Vec::new();
        let mut v = timelock;
        while v > 0 {
            lock.push((v & 0xff) as u8);
            v >>= 8;
        }
        if lock.last().is_some_and(|b| b & 0x80 != 0) {
            lock.push(0x00);
        }

        let mut script = Vec::with_capacity(114);
        script.push(OP_IF);
        script.push(OP_SHA256);
        push(&mut script, &hash);
        script.push(OP_EQUALVERIFY);
        push(&mut script, &recipient);
        script.push(OP_CHECKSIG);
        script.push(OP_ELSE);
        push(&mut script, &lock);
        script.push(OP_CHECKLOCKTIMEVERIFY);
        script.push(OP_DROP);
        push(&mut script, &sender);
        script.push(OP_CHECKSIG);
        script.push(OP_ENDIF);
        Ok(script)
    }

    /// Verify a payment on any supported chain using SPV.
    pub async fn verify_payment(
        chain_spv: &dyn ChainSpv,
        tx_hash: &str,
        from_address: &str,
        to_address: &str,
        amount: u64,
        min_confirmations: u32,
    ) -> Result<PaymentProof> {
        let proof = chain_spv.build_payment_proof(tx_hash, from_address, to_address, amount).await?;
        let verified = chain_spv.verify_payment_proof(&proof, min_confirmations).await?;
        let mut proof = proof;
        proof.verified = verified;
        Ok(proof)
    }
}
