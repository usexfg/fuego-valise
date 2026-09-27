use crate::error::{Result, SdkError};
use crate::serialization::{
    parse_extra_pubkey, CommitmentSpendInput, OutputTarget, TransactionPrefix, TxInput, HEAT_TERM,
};
use crate::transaction_builder::{
    build_transaction as build_signed_transaction, compute_change, select_inputs,
    BuildDestination, BuiltTransaction, DecoyEntry, SpendableOutput, DEFAULT_DUST_THRESHOLD,
};
use crate::types::{Address, Balance};
use crate::vault::WalletVault;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, RwLock};

/// A spendable key output owned by this wallet, with everything needed to
/// build and sign a transaction.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UtxoEntry {
    pub amount: u64,
    /// One-time output key P.
    pub output_key: [u8; 32],
    /// One-time secret key x (x*G == P).
    pub secret_key: [u8; 32],
    /// Key image I = x * H_p(P).
    pub key_image: [u8; 32],
    /// Global output index (from /get_o_indexes.bin, attached after scan).
    pub global_index: u32,
    pub tx_hash: [u8; 32],
    /// Position of this output within its funding transaction.
    pub output_position: u32,
    pub block_height: u64,
}

impl From<&UtxoEntry> for SpendableOutput {
    fn from(u: &UtxoEntry) -> Self {
        SpendableOutput {
            amount: u.amount,
            output_key: u.output_key,
            secret_key: u.secret_key,
            key_image: u.key_image,
            global_index: u.global_index,
            tx_hash: u.tx_hash,
            output_position: u.output_position,
        }
    }
}

/// A commitment output owned by this wallet (HEAT, HEAT CDs, XFG CDs).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommitmentEntry {
    pub amount: u64,
    pub commit_key: [u8; 32],
    pub key_scalar: [u8; 32],
    pub key_image: [u8; 32],
    pub global_index: u32,
    pub tx_hash: [u8; 32],
    pub output_position: u32,
    /// Lock term in blocks. HEAT_TERM = HEAT (spendable); finite term = CD.
    pub term: u32,
    pub block_height: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HistoryDirection {
    Incoming,
    Outgoing,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub tx_hash: [u8; 32],
    pub block_height: u64,
    pub direction: HistoryDirection,
    pub amount: u64,
    pub fee: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScannerStateSnapshot {
    pub height: u64,
    pub utxos: Vec<UtxoEntry>,
    pub commitments: Vec<CommitmentEntry>,
    pub spent_images: Vec<[u8; 32]>,
    pub history: Vec<HistoryEntry>,
    /// Which address received each owned key output, by key image.
    pub owners: Vec<([u8; 32], OutputOwner)>,
}

/// Which of the wallet's addresses an output was sent to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum OutputOwner {
    Primary,
    /// Suite-scheme sub-address (major 0, minor n), n >= 1.
    Subaddress(u32),
    /// Pre-suite-scheme "sub-address" n: an independent keypair (vault keys n
    /// and n + 1) that only a separate scan finds. Funds here are swept to
    /// the primary address.
    LegacySubaddress(u32),
}

/// Sub-addresses scanned beyond the highest one used or created, so outputs
/// to recently handed-out addresses are found even after a seed restore.
pub const SUBADDRESS_LOOKAHEAD: u32 = 50;

/// Spend keys the scanner recognises after underiving an output key with the
/// master view derivation, and the legacy accounts that need their own.
struct ScanKeys {
    view_secret: [u8; 32],
    spend_public: [u8; 32],
    spend_secret: [u8; 32],
    by_spend_key: HashMap<[u8; 32], (OutputOwner, [u8; 32])>,
    subaddress_top: u32,
    legacy: Vec<LegacyAccount>,
}

struct LegacyAccount {
    index: u32,
    view_secret: [u8; 32],
    spend_public: [u8; 32],
    spend_secret: [u8; 32],
}

impl ScanKeys {
    fn new(keys: &WalletKeys) -> Self {
        let mut by_spend_key = HashMap::new();
        by_spend_key.insert(keys.spend_public, (OutputOwner::Primary, keys.spend_secret));
        let mut table = Self {
            view_secret: keys.view_secret,
            spend_public: keys.spend_public,
            spend_secret: keys.spend_secret,
            by_spend_key,
            subaddress_top: 0,
            legacy: Vec::new(),
        };
        table.extend_subaddresses(SUBADDRESS_LOOKAHEAD);
        table
    }

    fn extend_subaddresses(&mut self, top: u32) {
        while self.subaddress_top < top {
            let minor = self.subaddress_top + 1;
            if let Some(k) = fuego_crypto::derive_subaddress_keys(
                &self.view_secret,
                &self.spend_public,
                Some(&self.spend_secret),
                0,
                minor,
            ) {
                self.by_spend_key.insert(
                    k.spend_public,
                    (OutputOwner::Subaddress(minor), k.spend_secret.unwrap()),
                );
            }
            self.subaddress_top = minor;
        }
    }
}

impl Drop for ScanKeys {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.view_secret.zeroize();
        self.spend_secret.zeroize();
        for (_, (_, secret)) in self.by_spend_key.iter_mut() {
            secret.zeroize();
        }
        for acct in self.legacy.iter_mut() {
            acct.view_secret.zeroize();
            acct.spend_secret.zeroize();
        }
    }
}

pub struct UtxoScanner {
    vault: WalletVault,
    state: Arc<RwLock<ScannerState>>,
    scan_keys: RwLock<ScanKeys>,
}

struct ScannerState {
    height: u64,
    utxos: Vec<UtxoEntry>,
    commitments: Vec<CommitmentEntry>,
    spent_images: HashSet<[u8; 32]>,
    history: Vec<HistoryEntry>,
    balance: Balance,
    owners: HashMap<[u8; 32], OutputOwner>,
}

/// The wallet's core key material: index 0 = spend, index 1 = view
/// (matches WalletVault::get_address layout).
pub struct WalletKeys {
    pub spend_secret: [u8; 32],
    pub spend_public: [u8; 32],
    pub view_secret: [u8; 32],
    pub view_public: [u8; 32],
}

impl UtxoScanner {
    pub fn new(vault: WalletVault) -> Self {
        let keys = primary_keys(&vault);
        Self {
            vault,
            state: Arc::new(RwLock::new(ScannerState {
                height: 0,
                utxos: Vec::new(),
                commitments: Vec::new(),
                spent_images: HashSet::new(),
                history: Vec::new(),
                balance: Balance::default(),
                owners: HashMap::new(),
            })),
            scan_keys: RwLock::new(ScanKeys::new(&keys)),
        }
    }

    pub fn vault(&self) -> &WalletVault {
        &self.vault
    }

    pub fn vault_mut(&mut self) -> &mut WalletVault {
        &mut self.vault
    }

    /// Primary wallet keys: keypair(0) = spend, keypair(1) = view.
    pub fn wallet_keys(&self) -> WalletKeys {
        primary_keys(&self.vault)
    }

    /// Public keys (spend D, view A) of suite-scheme sub-address `minor` (>= 1),
    /// and make sure the scanner looks at least SUBADDRESS_LOOKAHEAD past it.
    pub fn subaddress(&self, minor: u32) -> Option<([u8; 32], [u8; 32])> {
        let keys = self.wallet_keys();
        let sub = fuego_crypto::derive_subaddress_keys(
            &keys.view_secret,
            &keys.spend_public,
            None,
            0,
            minor,
        )?;
        self.scan_keys
            .write()
            .unwrap()
            .extend_subaddresses(minor.saturating_add(SUBADDRESS_LOOKAHEAD));
        Some((sub.spend_public, sub.view_public))
    }

    /// Scan for pre-suite-scheme sub-addresses `indices` (vault keypairs n and
    /// n + 1). Returns true when the set grew, i.e. a rescan is needed to find
    /// outputs already on chain.
    pub fn set_legacy_subaddresses(&self, indices: &[u32]) -> bool {
        let mut table = self.scan_keys.write().unwrap();
        let mut grew = false;
        for &index in indices {
            if index == 0 || index == u32::MAX || table.legacy.iter().any(|a| a.index == index) {
                continue;
            }
            let spend = self.vault.derive_keypair(index);
            let view = self.vault.derive_keypair(index + 1);
            table.legacy.push(LegacyAccount {
                index,
                view_secret: view.secret,
                spend_public: spend.public,
                spend_secret: spend.secret,
            });
            grew = true;
        }
        grew
    }

    pub fn legacy_subaddresses(&self) -> Vec<u32> {
        self.scan_keys.read().unwrap().legacy.iter().map(|a| a.index).collect()
    }

    /// Unspent, unreserved key outputs grouped by the address that received them.
    pub fn balance_by_owner(&self) -> HashMap<OutputOwner, u64> {
        let state = self.state.read().unwrap();
        let mut out = HashMap::new();
        for u in &state.utxos {
            if state.spent_images.contains(&u.key_image) {
                continue;
            }
            let owner = state.owners.get(&u.key_image).copied().unwrap_or(OutputOwner::Primary);
            *out.entry(owner).or_insert(0) += u.amount;
        }
        out
    }

    /// Owned outputs received on legacy sub-addresses (to sweep).
    pub fn legacy_utxos(&self) -> Vec<UtxoEntry> {
        let state = self.state.read().unwrap();
        state
            .utxos
            .iter()
            .filter(|u| {
                matches!(state.owners.get(&u.key_image), Some(OutputOwner::LegacySubaddress(_)))
                    && !state.spent_images.contains(&u.key_image)
            })
            .cloned()
            .collect()
    }

    pub fn height(&self) -> u64 {
        self.state.read().unwrap().height
    }

    pub fn set_height(&self, height: u64) {
        self.state.write().unwrap().height = height;
    }

    pub fn balance(&self) -> Balance {
        self.state.read().unwrap().balance.clone()
    }

    pub fn utxos(&self) -> Vec<UtxoEntry> {
        self.state.read().unwrap().utxos.clone()
    }

    /// All owned commitments.
    pub fn commitments(&self) -> Vec<CommitmentEntry> {
        self.state.read().unwrap().commitments.clone()
    }

    /// Spendable HEAT (term == HEAT_TERM, not reserved).
    pub fn heat_outputs(&self) -> Vec<CommitmentEntry> {
        let state = self.state.read().unwrap();
        state
            .commitments
            .iter()
            .filter(|c| c.term == HEAT_TERM && !state.spent_images.contains(&c.key_image))
            .cloned()
            .collect()
    }

    /// Finite-term deposits (CDs). Mature when block_height + term <= height.
    pub fn deposits(&self) -> Vec<CommitmentEntry> {
        let state = self.state.read().unwrap();
        state
            .commitments
            .iter()
            .filter(|c| c.term != HEAT_TERM && !state.spent_images.contains(&c.key_image))
            .cloned()
            .collect()
    }

    pub fn history(&self, limit: usize) -> Vec<HistoryEntry> {
        let state = self.state.read().unwrap();
        state.history.iter().rev().take(limit).cloned().collect()
    }

    pub fn is_spent(&self, key_image: &[u8; 32]) -> bool {
        self.state.read().unwrap().spent_images.contains(key_image)
    }

    /// Scan one transaction prefix for outputs we own and inputs spending
    /// our outputs, using the standard CryptoNote discovery rules:
    /// key outputs: P == Hs(a·R || i) · G + B;
    /// commitment outputs: commitKey == deriveCommitmentKeys(Hs(D || i)).commitKey
    /// with D = a·R.
    pub fn scan_tx_prefix(
        &self,
        tx_hash: &[u8; 32],
        prefix: &TransactionPrefix,
        block_height: u64,
    ) -> Result<(u64, u64)> {
        let view_secret = self.scan_keys.read().unwrap().view_secret;
        let mut state = self.state.write().unwrap();

        let mut received = 0u64;
        let mut spent = 0u64;

        // Spend detection first: any input key image matching our unspent
        // outputs removes it.
        for input in &prefix.inputs {
            let image = match input {
                TxInput::Key(k) => &k.key_image,
                TxInput::CommitmentSpend(c) => &c.key_image,
            };
            if let Some(idx) = state
                .utxos
                .iter()
                .position(|u| u.key_image == *image)
            {
                let entry = state.utxos.remove(idx);
                state.spent_images.insert(entry.key_image);
                spent += entry.amount;
                state.history.push(HistoryEntry {
                    tx_hash: *tx_hash,
                    block_height,
                    direction: HistoryDirection::Outgoing,
                    amount: entry.amount,
                    fee: prefix_inputs_amount_delta(prefix),
                });
                continue;
            }
            if let Some(idx) = state
                .commitments
                .iter()
                .position(|c| c.key_image == *image)
            {
                let entry = state.commitments.remove(idx);
                state.spent_images.insert(entry.key_image);
                spent += entry.amount;
                state.history.push(HistoryEntry {
                    tx_hash: *tx_hash,
                    block_height,
                    direction: HistoryDirection::Outgoing,
                    amount: entry.amount,
                    fee: prefix_inputs_amount_delta(prefix),
                });
            }
        }

        // Output detection.
        let r = match parse_extra_pubkey(&prefix.extra) {
            Some(k) => k,
            None => return Ok((received, spent)),
        };
        let derivation = match fuego_crypto::generate_key_derivation(
            &fuego_crypto::PublicKey(r),
            &view_secret,
        ) {
            Some(d) => d,
            None => return Ok((received, spent)),
        };

        let table = self.scan_keys.read().unwrap();
        // Legacy accounts have their own view keys, hence their own derivations.
        let legacy_derivations: Vec<Option<[u8; 32]>> = table
            .legacy
            .iter()
            .map(|a| fuego_crypto::generate_key_derivation(&fuego_crypto::PublicKey(r), &a.view_secret))
            .collect();
        let mut highest_subaddress = 0u32;

        for (i, output) in prefix.outputs.iter().enumerate() {
            match &output.target {
                OutputTarget::Key(output_key) => {
                    let mut hit: Option<(OutputOwner, [u8; 32])> = None;
                    // One master derivation serves the primary address and every
                    // sub-address: P - Hs(aR, i)G is the recipient's spend key.
                    if let Some(base) = fuego_crypto::underive_public_key(
                        &derivation,
                        i as u64,
                        &fuego_crypto::PublicKey(*output_key),
                    ) {
                        if let Some((owner, spend_secret)) = table.by_spend_key.get(&base.0) {
                            hit = fuego_crypto::derive_secret_key(&derivation, i as u64, spend_secret)
                                .map(|x| (*owner, x));
                        }
                    }
                    if hit.is_none() {
                        for (acct, d) in table.legacy.iter().zip(&legacy_derivations) {
                            let Some(d) = d else { continue };
                            let matches = fuego_crypto::derive_public_key(d, i as u64, &acct.spend_public)
                                .map(|p| p.0 == *output_key)
                                .unwrap_or(false);
                            if matches {
                                hit = fuego_crypto::derive_secret_key(d, i as u64, &acct.spend_secret)
                                    .map(|x| (OutputOwner::LegacySubaddress(acct.index), x));
                                break;
                            }
                        }
                    }
                    let Some((owner, secret)) = hit else { continue };
                    if let OutputOwner::Subaddress(minor) = owner {
                        highest_subaddress = highest_subaddress.max(minor);
                    }
                    let key_image = fuego_crypto::generate_key_image(
                        &fuego_crypto::PublicKey(*output_key),
                        &secret,
                    );
                    state.owners.insert(key_image.0, owner);
                    state.utxos.push(UtxoEntry {
                        amount: output.amount,
                        output_key: *output_key,
                        secret_key: secret,
                        key_image: key_image.0,
                        global_index: 0,
                        tx_hash: *tx_hash,
                        output_position: i as u32,
                        block_height,
                    });
                    received += output.amount;
                }
                OutputTarget::Commitment(commit) => {
                    let deposit_secret =
                        fuego_crypto::ring::derive_deposit_secret(&derivation, i as u32);
                    let ck = fuego_crypto::ring::derive_commitment_keys(&deposit_secret);
                    if ck.commit_key != commit.commit_key {
                        continue;
                    }
                    state.commitments.push(CommitmentEntry {
                        amount: output.amount,
                        commit_key: commit.commit_key,
                        key_scalar: ck.key_scalar,
                        key_image: ck.key_image,
                        global_index: 0,
                        tx_hash: *tx_hash,
                        output_position: i as u32,
                        term: commit.term,
                        block_height,
                    });
                    received += output.amount;
                }
            }
        }

        drop(table);
        if highest_subaddress > 0 {
            self.scan_keys
                .write()
                .unwrap()
                .extend_subaddresses(highest_subaddress.saturating_add(SUBADDRESS_LOOKAHEAD));
        }

        if received > 0 || spent > 0 {
            state.history.push(HistoryEntry {
                tx_hash: *tx_hash,
                block_height,
                direction: if received > 0 {
                    HistoryDirection::Incoming
                } else {
                    HistoryDirection::Outgoing
                },
                amount: received.max(spent),
                fee: 0,
            });
        }

        state.balance.confirmed = state.utxos.iter().map(|u| u.amount).sum();
        Ok((received, spent))
    }

    /// Attach global output indices (from /get_o_indexes.bin, aligned with
    /// the transaction's outputs) to outputs of the given tx.
    pub fn attach_global_indices(&self, tx_hash: &[u8; 32], indices: &[u64]) {
        let mut state = self.state.write().unwrap();
        for entry in state.utxos.iter_mut() {
            if &entry.tx_hash == tx_hash {
                if let Some(&idx) = indices.get(entry.output_position as usize) {
                    if idx <= u32::MAX as u64 {
                        entry.global_index = idx as u32;
                    }
                }
            }
        }
        for entry in state.commitments.iter_mut() {
            if &entry.tx_hash == tx_hash {
                if let Some(&idx) = indices.get(entry.output_position as usize) {
                    if idx <= u32::MAX as u64 {
                        entry.global_index = idx as u32;
                    }
                }
            }
        }
    }

    /// Mark a key image as spent by a transaction that is still in the
    /// mempool (persist-before-broadcast reservation).
    pub fn reserve_key_images(&self, images: &[[u8; 32]]) {
        let mut state = self.state.write().unwrap();
        for image in images {
            state.spent_images.insert(*image);
        }
    }

    pub fn snapshot(&self) -> ScannerStateSnapshot {
        let state = self.state.read().unwrap();
        ScannerStateSnapshot {
            height: state.height,
            utxos: state.utxos.clone(),
            commitments: state.commitments.clone(),
            spent_images: state.spent_images.iter().copied().collect(),
            history: state.history.clone(),
            owners: state.owners.iter().map(|(k, o)| (*k, *o)).collect(),
        }
    }

    pub fn restore(&self, snapshot: &ScannerStateSnapshot) {
        let mut state = self.state.write().unwrap();
        state.height = snapshot.height;
        state.utxos = snapshot.utxos.clone();
        state.commitments = snapshot.commitments.clone();
        state.spent_images = snapshot.spent_images.iter().copied().collect();
        state.history = snapshot.history.clone();
        state.owners = snapshot.owners.iter().copied().collect();
        state.balance.confirmed = state.utxos.iter().map(|u| u.amount).sum();
        let highest = state
            .owners
            .values()
            .filter_map(|o| match o {
                OutputOwner::Subaddress(n) => Some(*n),
                _ => None,
            })
            .max()
            .unwrap_or(0);
        drop(state);
        self.scan_keys
            .write()
            .unwrap()
            .extend_subaddresses(highest.saturating_add(SUBADDRESS_LOOKAHEAD));
    }

    /// Phase 1 of sending: select inputs for `amount + fee` using the bucket
    /// algorithm. Returns the selected outputs.
    pub fn select_for_send(
        &self,
        total_needed: u64,
        rng: &mut impl rand::RngCore,
    ) -> Result<Vec<UtxoEntry>> {
        let state = self.state.read().unwrap();
        if state.balance.confirmed < total_needed {
            return Err(SdkError::InsufficientFunds {
                need: total_needed,
                have: state.balance.confirmed,
            });
        }
        // Only outputs with a confirmed global index are spendable (index 0
        // belongs to the genesis miner transaction and can never be ours).
        let spendable: Vec<SpendableOutput> = state
            .utxos
            .iter()
            .filter(|u| u.global_index != 0)
            .map(|u| u.into())
            .collect();
        let (selected, found) =
            select_inputs(&spendable, total_needed, DEFAULT_DUST_THRESHOLD, rng);
        if found < total_needed {
            return Err(SdkError::InsufficientFunds {
                need: total_needed,
                have: found,
            });
        }
        let selected: Vec<UtxoEntry> = state
            .utxos
            .iter()
            .filter(|u| selected.iter().any(|s| s.key_image == u.key_image))
            .cloned()
            .collect();
        Ok(selected)
    }

    /// Phase 2 of sending: build and sign a KeyInput transaction with the
    /// given selection and per-input decoy groups.
    #[allow(clippy::too_many_arguments)]
    pub fn build_with_selection(
        &self,
        selected: &[UtxoEntry],
        destinations: &[(Address, u64)],
        fee: u64,
        mixin: usize,
        decoys: &[Vec<DecoyEntry>],
        rng: &mut impl rand::RngCore,
    ) -> Result<BuiltTransaction> {
        self.build_with_selection_ext(selected, destinations, fee, mixin, decoys, 0, &[], rng)
    }

    /// Like build_with_selection, with unlock_time and additional extra bytes
    /// (appended after the tx pubkey tag).
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
        let keys = self.wallet_keys();

        let dests_amount: u64 = destinations.iter().map(|(_, a)| *a).sum();
        let found: u64 = selected.iter().map(|u| u.amount).sum();
        let (change_chunks, dust) =
            compute_change(found, dests_amount, fee, DEFAULT_DUST_THRESHOLD)?;

        // Change returns to the primary wallet keys (same keys regardless of
        // network prefix).
        let change_spend = keys.spend_public;
        let change_view = keys.view_public;

        let mut dests: Vec<BuildDestination> =
            Vec::with_capacity(destinations.len() + change_chunks.len() + 1);
        for (addr, amount) in destinations {
            let (spend_pub, view_pub) = match fuego_crypto::parse_address(&addr.0) {
                Some(k) => k,
                None => {
                    return Err(SdkError::Crypto(format!(
                        "invalid destination address: {}",
                        addr.0
                    )))
                }
            };
            dests.push(BuildDestination {
                amount: *amount,
                spend_pub,
                view_pub,
            });
        }
        for chunk in change_chunks {
            dests.push(BuildDestination {
                amount: chunk,
                spend_pub: change_spend,
                view_pub: change_view,
            });
        }
        if dust > 0 {
            dests.push(BuildDestination {
                amount: dust,
                spend_pub: change_spend,
                view_pub: change_view,
            });
        }

        let inputs: Vec<SpendableOutput> = selected.iter().map(|u| u.into()).collect();
        let inputs = crate::transaction_builder::prepare_inputs(inputs);
        // Rebuild the input order matching `inputs` for decoy alignment:
        // decoys are indexed by position in `selected`; prepare_inputs only
        // sorts (stable by amount), so reorder decoys the same way.
        let mut order: Vec<usize> = (0..selected.len()).collect();
        order.sort_by_key(|&i| selected[i].amount);
        let mut decoys_sorted: Vec<Vec<DecoyEntry>> = Vec::with_capacity(decoys.len());
        for &i in &order {
            decoys_sorted.push(decoys[i].clone());
        }

        build_signed_transaction(
            &inputs,
            &dests,
            &keys.view_public,
            fee,
            mixin,
            &decoys_sorted,
            unlock_time,
            extra_extra,
            rng,
        )
    }

    /// Mark a pending (broadcast) transaction's inputs as reserved so they
    /// are not double-selected before confirmation.
    pub fn reserve_pending(&self, key_images: &[[u8; 32]]) {
        self.reserve_key_images(key_images);
    }
}

fn primary_keys(vault: &WalletVault) -> WalletKeys {
    let spend = vault.derive_keypair(0);
    let view = vault.derive_keypair(1);
    WalletKeys {
        spend_secret: spend.secret,
        spend_public: spend.public,
        view_secret: view.secret,
        view_public: view.public,
    }
}

impl Default for UtxoScanner {
    fn default() -> Self {
        Self::new(WalletVault::default())
    }
}

/// Approximate the fee of a spend (inputs sum - outputs sum) for history
/// display purposes.
fn prefix_inputs_amount_delta(prefix: &TransactionPrefix) -> u64 {
    let in_amount: u64 = prefix.inputs.iter().map(|i| i.amount()).sum();
    let out_amount: u64 = prefix.outputs.iter().map(|o| o.amount).sum();
    in_amount.saturating_sub(out_amount)
}

// Keep the import used for clarity in the builder call sites.
#[allow(unused)]
fn _commitment_spend_type_ref(_c: &CommitmentSpendInput) {}

#[cfg(test)]
mod subaddress_tests {
    use super::*;
    use crate::serialization::TxOutput;

    fn scanner() -> UtxoScanner {
        UtxoScanner::new(WalletVault::from_seed([0x5au8; 32]))
    }

    /// A one-output tx paying (spend, view) the way any CryptoNote sender does:
    /// R = rG, P = Hs(rC, 0)G + D.
    fn pay(spend: &[u8; 32], view: &[u8; 32], r_seed: u8, amount: u64) -> TransactionPrefix {
        let r = fuego_crypto::Keypair::from_secret([r_seed; 32]);
        let d = fuego_crypto::generate_key_derivation(&fuego_crypto::PublicKey(*view), &r.secret).unwrap();
        let p = fuego_crypto::derive_public_key(&d, 0, spend).unwrap();
        let mut extra = vec![0x01];
        extra.extend_from_slice(&r.public);
        TransactionPrefix {
            version: 1,
            unlock_time: 0,
            inputs: Vec::new(),
            outputs: vec![TxOutput { amount, target: OutputTarget::Key(p.0) }],
            extra,
        }
    }

    fn assert_spendable(s: &UtxoScanner) {
        for u in s.utxos() {
            assert_eq!(fuego_crypto::ring::secret_key_to_public_key(&u.secret_key), u.output_key);
        }
    }

    #[test]
    fn finds_primary_and_subaddress_outputs() {
        let s = scanner();
        let keys = s.wallet_keys();
        let (d3, a3) = s.subaddress(3).unwrap();
        assert_eq!(a3, keys.view_public, "suite scheme: view key is the master one");

        s.scan_tx_prefix(&[1; 32], &pay(&keys.spend_public, &keys.view_public, 7, 100), 10).unwrap();
        s.scan_tx_prefix(&[2; 32], &pay(&d3, &a3, 8, 250), 11).unwrap();

        let by = s.balance_by_owner();
        assert_eq!(by.get(&OutputOwner::Primary), Some(&100));
        assert_eq!(by.get(&OutputOwner::Subaddress(3)), Some(&250));
        assert_eq!(s.balance().confirmed, 350);
        assert_spendable(&s);
    }

    #[test]
    fn lookahead_follows_the_highest_used_subaddress() {
        let s = scanner();
        let keys = s.wallet_keys();
        let far = |n| {
            fuego_crypto::derive_subaddress_keys(&keys.view_secret, &keys.spend_public, None, 0, n)
                .unwrap()
                .spend_public
        };
        // Beyond the initial window: not found.
        s.scan_tx_prefix(&[1; 32], &pay(&far(80), &keys.view_public, 1, 5), 1).unwrap();
        assert_eq!(s.balance().confirmed, 0);
        // A hit inside the window slides it forward...
        s.scan_tx_prefix(&[2; 32], &pay(&far(SUBADDRESS_LOOKAHEAD), &keys.view_public, 2, 7), 2).unwrap();
        // ...so the next payment to 80 is found.
        s.scan_tx_prefix(&[3; 32], &pay(&far(80), &keys.view_public, 3, 9), 3).unwrap();
        assert_eq!(s.balance_by_owner().get(&OutputOwner::Subaddress(80)), Some(&9));

        // Restoring a snapshot re-extends the window from the owners it holds.
        let restored = scanner();
        restored.restore(&s.snapshot());
        restored.scan_tx_prefix(&[4; 32], &pay(&far(120), &keys.view_public, 4, 11), 4).unwrap();
        assert_eq!(restored.balance_by_owner().get(&OutputOwner::Subaddress(120)), Some(&11));
    }

    #[test]
    fn legacy_subaddress_outputs_need_registration() {
        let s = scanner();
        // Old scheme: sub-address n = (vault key n, vault key n + 1).
        let spend = s.vault().derive_keypair(1).public;
        let view = s.vault().derive_keypair(2).public;
        let tx = pay(&spend, &view, 9, 42);

        s.scan_tx_prefix(&[1; 32], &tx, 1).unwrap();
        assert_eq!(s.balance().confirmed, 0, "invisible to the primary scan");

        assert!(s.set_legacy_subaddresses(&[1]));
        assert!(!s.set_legacy_subaddresses(&[1]), "no growth, no rescan");
        s.scan_tx_prefix(&[1; 32], &tx, 1).unwrap();
        assert_eq!(s.balance_by_owner().get(&OutputOwner::LegacySubaddress(1)), Some(&42));
        assert_eq!(s.legacy_utxos().len(), 1);
        assert_spendable(&s);
    }
}
