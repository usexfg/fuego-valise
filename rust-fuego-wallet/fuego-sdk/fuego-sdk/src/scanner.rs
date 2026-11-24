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
    /// funsa V2 sub-address (major 0, minor n), n >= 1. Credited only when the
    /// output's tx key passes the Janus check.
    SubaddressV2(u32),
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
    subaddress_v2_top: u32,
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
            subaddress_v2_top: 0,
            legacy: Vec::new(),
        };
        table.extend_subaddresses(SUBADDRESS_LOOKAHEAD);
        table.extend_subaddresses_v2(SUBADDRESS_LOOKAHEAD);
        table
    }

    fn extend_subaddresses_v2(&mut self, top: u32) {
        while self.subaddress_v2_top < top {
            let minor = self.subaddress_v2_top + 1;
            if let Some(k) = fuego_crypto::derive_subaddress_v2_keys(
                &self.view_secret,
                &self.spend_public,
                Some(&self.spend_secret),
                0,
                minor,
            ) {
                self.by_spend_key.insert(
                    k.spend_public,
                    (OutputOwner::SubaddressV2(minor), k.spend_secret.clone().unwrap()),
                );
            }
            self.subaddress_v2_top = minor;
        }
    }

    /// The owner whose spend key output `index` pays under this tx key, and the
    /// one-time secret that spends it. A V2 sub-address needs a passing Janus check.
    fn match_key_output(&self, candidate: &CandidateTxKey, index: u64, output_key: &[u8; 32]) -> Option<(OutputOwner, [u8; 32])> {
        let base = fuego_crypto::underive_public_key(&candidate.derivation, index, &fuego_crypto::PublicKey(*output_key))?;
        let (owner, spend_secret) = self.by_spend_key.get(&base.0)?;
        if !candidate.authorises(owner, spend_secret) {
            return None;
        }
        fuego_crypto::derive_secret_key(&candidate.derivation, index, spend_secret).map(|x| (*owner, x))
    }

    fn match_legacy_key_output(&self, candidate: &CandidateTxKey, index: u64, output_key: &[u8; 32]) -> Option<(OutputOwner, [u8; 32])> {
        self.legacy.iter().find_map(|acct| {
            let d = fuego_crypto::generate_key_derivation(&fuego_crypto::PublicKey(candidate.tx_pub_key), &acct.view_secret)?;
            let p = fuego_crypto::derive_public_key(&d, index, &acct.spend_public)?;
            if p.0 != *output_key {
                return None;
            }
            fuego_crypto::derive_secret_key(&d, index, &acct.spend_secret).map(|x| (OutputOwner::LegacySubaddress(acct.index), x))
        })
    }

    /// Commitment outputs are owner-bound: the scalar and key image need the
    /// recipient's spend secret, found through the same tx key candidates.
    fn match_commitment(&self, candidate: &CandidateTxKey, index: u64, commit_key: &[u8; 32]) -> Option<(OutputOwner, [u8; 32], [u8; 32])> {
        if let Some(base) = fuego_crypto::underive_public_key(&candidate.derivation, index, &fuego_crypto::PublicKey(*commit_key)) {
            if let Some((owner, spend_secret)) = self.by_spend_key.get(&base.0) {
                if candidate.authorises(owner, spend_secret) {
                    if let Some((sec, ki)) = fuego_crypto::ring::derive_owner_bound_key_image(&candidate.derivation, index, commit_key, spend_secret) {
                        return Some((*owner, sec, ki));
                    }
                }
            }
        }
        self.legacy.iter().find_map(|acct| {
            let d = fuego_crypto::generate_key_derivation(&fuego_crypto::PublicKey(candidate.tx_pub_key), &acct.view_secret)?;
            let p = fuego_crypto::derive_public_key(&d, index, &acct.spend_public)?;
            if p.0 != *commit_key {
                return None;
            }
            fuego_crypto::ring::derive_owner_bound_key_image(&d, index, commit_key, &acct.spend_secret)
                .map(|(sec, ki)| (OutputOwner::LegacySubaddress(acct.index), sec, ki))
        })
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

/// A tx key that may have produced an output: the main key, or that output's
/// own key from 0x06, with the Janus base published for it.
struct CandidateTxKey {
    tx_pub_key: [u8; 32],
    derivation: [u8; 32],
    janus_base: Option<[u8; 32]>,
}

impl CandidateTxKey {
    fn new(tx_pub_key: [u8; 32], view_secret: &[u8; 32], janus_base: Option<[u8; 32]>) -> Option<Self> {
        let derivation = fuego_crypto::generate_key_derivation(&fuego_crypto::PublicKey(tx_pub_key), view_secret)?;
        Some(Self { tx_pub_key, derivation, janus_base })
    }

    /// Every owner but a V2 sub-address accepts any tx key; a V2 sub-address
    /// needs (b + m)*J == R, which a sender probing for the primary address cannot meet.
    fn authorises(&self, owner: &OutputOwner, spend_secret: &[u8; 32]) -> bool {
        match owner {
            OutputOwner::SubaddressV2(_) => self
                .janus_base
                .map_or(false, |j| fuego_crypto::janus_check(&self.tx_pub_key, &j, spend_secret)),
            _ => true,
        }
    }
}

/// The tx keys to try for output `index`: the main key first, then the
/// output's own key when the tx carries one per output.
fn candidate_tx_keys(
    main_tx_key: Option<[u8; 32]>,
    keys: &crate::serialization::SubaddressTxKeys,
    output_count: usize,
    index: usize,
    view_secret: &[u8; 32],
) -> Vec<CandidateTxKey> {
    let per_output = keys.additional_pub_keys.len() == output_count;
    let single_janus = (keys.additional_pub_keys.is_empty() && keys.janus_bases.len() == 1).then(|| keys.janus_bases[0]);
    let mut candidates = Vec::with_capacity(2);
    if let Some(r) = main_tx_key {
        candidates.extend(CandidateTxKey::new(r, view_secret, single_janus));
    }
    if per_output {
        let janus = (keys.janus_bases.len() == output_count).then(|| keys.janus_bases[index]);
        candidates.extend(CandidateTxKey::new(keys.additional_pub_keys[index], view_secret, janus));
    }
    candidates
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

    /// Public keys (spend D, view C) of funsa V2 sub-address `minor` (>= 1),
    /// and make sure the scanner looks at least SUBADDRESS_LOOKAHEAD past it.
    pub fn subaddress_v2(&self, minor: u32) -> Option<([u8; 32], [u8; 32])> {
        let keys = self.wallet_keys();
        let sub = fuego_crypto::derive_subaddress_v2_keys(&keys.view_secret, &keys.spend_public, None, 0, minor)?;
        self.scan_keys
            .write()
            .unwrap()
            .extend_subaddresses_v2(minor.saturating_add(SUBADDRESS_LOOKAHEAD));
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

        // Output detection: each output is tried with the main tx key, then
        // with its own key from 0x06 (per-output funsa transactions).
        let main_tx_key = parse_extra_pubkey(&prefix.extra);
        let subaddress_keys = crate::serialization::parse_subaddress_tx_keys(&prefix.extra);
        let table = self.scan_keys.read().unwrap();
        let mut highest_subaddress = 0u32;
        let mut highest_subaddress_v2 = 0u32;
        let mut note_owner = |owner: OutputOwner| match owner {
            OutputOwner::Subaddress(minor) => highest_subaddress = highest_subaddress.max(minor),
            OutputOwner::SubaddressV2(minor) => highest_subaddress_v2 = highest_subaddress_v2.max(minor),
            _ => {}
        };

        for (i, output) in prefix.outputs.iter().enumerate() {
            let candidates = candidate_tx_keys(main_tx_key, &subaddress_keys, prefix.outputs.len(), i, &view_secret);
            match &output.target {
                OutputTarget::Key(output_key) => {
                    let hit = candidates
                        .iter()
                        .find_map(|c| table.match_key_output(c, i as u64, output_key))
                        .or_else(|| candidates.iter().find_map(|c| table.match_legacy_key_output(c, i as u64, output_key)));
                    let Some((owner, secret)) = hit else { continue };
                    note_owner(owner);
                    let key_image = fuego_crypto::generate_key_image(
                        &fuego_crypto::PublicKey(*output_key),
                        &secret,
                    );
                    // Re-scanning a block (a batch replayed after a restart) must
                    // neither duplicate an output nor bring back a spent one.
                    if state.spent_images.contains(&key_image.0)
                        || state.utxos.iter().any(|u| u.key_image == key_image.0)
                    {
                        continue;
                    }
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
                    // Owner-bound only: legacy-form commitments are not resolved.
                    let Some((owner, key_scalar, key_image)) =
                        candidates.iter().find_map(|c| table.match_commitment(c, i as u64, &commit.commit_key))
                    else {
                        continue;
                    };
                    note_owner(owner);
                    if state.spent_images.contains(&key_image)
                        || state.commitments.iter().any(|c| c.key_image == key_image)
                    {
                        continue;
                    }
                    state.commitments.push(CommitmentEntry {
                        amount: output.amount,
                        commit_key: commit.commit_key,
                        key_scalar,
                        key_image,
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
        if highest_subaddress > 0 || highest_subaddress_v2 > 0 {
            let mut table = self.scan_keys.write().unwrap();
            table.extend_subaddresses(highest_subaddress.saturating_add(SUBADDRESS_LOOKAHEAD));
            table.extend_subaddresses_v2(highest_subaddress_v2.saturating_add(SUBADDRESS_LOOKAHEAD));
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
        let highest_of = |pick: fn(&OutputOwner) -> Option<u32>| state.owners.values().filter_map(pick).max().unwrap_or(0);
        let highest = highest_of(|o| match o {
            OutputOwner::Subaddress(n) => Some(*n),
            _ => None,
        });
        let highest_v2 = highest_of(|o| match o {
            OutputOwner::SubaddressV2(n) => Some(*n),
            _ => None,
        });
        drop(state);
        let mut table = self.scan_keys.write().unwrap();
        table.extend_subaddresses(highest.saturating_add(SUBADDRESS_LOOKAHEAD));
        table.extend_subaddresses_v2(highest_v2.saturating_add(SUBADDRESS_LOOKAHEAD));
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
        janus_base: bool,
        rng: &mut impl rand::RngCore,
    ) -> Result<BuiltTransaction> {
        self.build_with_selection_ext(selected, destinations, fee, mixin, decoys, 0, &[], janus_base, rng)
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
        janus_base: bool,
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
            let parsed = fuego_crypto::parse_any_address(&addr.0)
                .ok_or_else(|| SdkError::Crypto(format!("invalid destination address: {}", addr.0)))?;
            dests.push(BuildDestination {
                amount: *amount,
                spend_pub: parsed.spend_public,
                view_pub: parsed.view_public,
                is_subaddress: parsed.is_subaddress,
            });
        }
        for chunk in change_chunks {
            dests.push(BuildDestination {
                amount: chunk,
                spend_pub: change_spend,
                view_pub: change_view,
                is_subaddress: false,
            });
        }
        if dust > 0 {
            dests.push(BuildDestination {
                amount: dust,
                spend_pub: change_spend,
                view_pub: change_view,
                is_subaddress: false,
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
            &crate::transaction_builder::TxSender::new(&keys, janus_base),
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

    /// An owner-bound commitment output must be discovered and spendable. Before
    /// this the scanner only tried the legacy ECDH-only derivation, so any such
    /// output was silently skipped.
    #[test]
    fn finds_owner_bound_commitment_output() {
        let s = scanner();
        let keys = s.wallet_keys();

        let r = fuego_crypto::Keypair::from_secret([0x21u8; 32]);
        let d = fuego_crypto::generate_key_derivation(
            &fuego_crypto::PublicKey(keys.view_public),
            &r.secret,
        )
        .unwrap();
        let commit_key = fuego_crypto::ring::derive_owner_bound_commit_key(
            &d,
            0,
            &keys.spend_public,
        )
        .expect("owner-bound commit key");

        let mut extra = vec![0x01];
        extra.extend_from_slice(&r.public);
        let prefix = TransactionPrefix {
            version: 1,
            unlock_time: 0,
            inputs: Vec::new(),
            outputs: vec![TxOutput {
                amount: 640,
                target: OutputTarget::Commitment(crate::serialization::CommitmentOutputTarget {
                    commit_key,
                    term: crate::serialization::HEAT_TERM,
                    amount_commitment: [0u8; 32],
                    amount_proof: [0u8; crate::serialization::AMOUNT_PROOF_LEN],
                }),
            }],
            extra,
        };

        s.scan_tx_prefix(&[9; 32], &prefix, 100).unwrap();

        let found = s.commitments();
        assert_eq!(found.len(), 1, "owner-bound commitment output must be discovered");
        assert_eq!(found[0].amount, 640);
        assert_eq!(found[0].commit_key, commit_key);
        // The recovered scalar must actually spend this output.
        assert_eq!(
            fuego_crypto::ring::secret_key_to_public_key(&found[0].key_scalar),
            commit_key,
            "scanner must recover the real spend scalar, not a placeholder"
        );
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
    fn rescanning_a_tx_is_idempotent() {
        let s = scanner();
        let keys = s.wallet_keys();
        let tx = pay(&keys.spend_public, &keys.view_public, 7, 100);
        s.scan_tx_prefix(&[1; 32], &tx, 10).unwrap();
        assert_eq!(s.scan_tx_prefix(&[1; 32], &tx, 10).unwrap().0, 0);
        assert_eq!(s.utxos().len(), 1);
        assert_eq!(s.balance().confirmed, 100);
        assert_eq!(s.snapshot().history.len(), 1);

        // Once spent, replaying the receiving block must not resurrect it.
        let image = s.utxos()[0].key_image;
        let spend = TransactionPrefix {
            version: 1,
            unlock_time: 0,
            inputs: vec![TxInput::Key(crate::serialization::KeyInput {
                amount: 100,
                offsets: vec![1],
                key_image: image,
            })],
            outputs: Vec::new(),
            extra: Vec::new(),
        };
        s.scan_tx_prefix(&[2; 32], &spend, 11).unwrap();
        s.scan_tx_prefix(&[1; 32], &tx, 10).unwrap();
        assert!(s.utxos().is_empty());
        assert_eq!(s.balance().confirmed, 0);
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

#[cfg(test)]
mod funsa_v2_scan_tests {
    use super::*;
    use crate::serialization::{add_subaddress_tx_keys, parse_prefix_at, SubaddressTxKeys, TxOutput};
    use serde_json::Value;

    fn vectors() -> Value {
        serde_json::from_str(include_str!("../../../test-vectors/funsa_v2_vectors.json")).unwrap()
    }

    fn key(v: &Value) -> [u8; 32] {
        hex::decode(v.as_str().unwrap()).unwrap().try_into().unwrap()
    }

    fn vector_keys() -> WalletKeys {
        let v = vectors();
        WalletKeys {
            spend_secret: key(&v["recipient"]["spend_secret"]),
            spend_public: key(&v["recipient"]["spend_public"]),
            view_secret: key(&v["recipient"]["view_secret"]),
            view_public: key(&v["recipient"]["view_public"]),
        }
    }

    /// A scanner holding the vector recipient's keys (a = 0x11.., b = 0x22..).
    fn recipient_scanner() -> UtxoScanner {
        let scanner = UtxoScanner::new(WalletVault::from_seed([0x5au8; 32]));
        *scanner.scan_keys.write().unwrap() = ScanKeys::new(&vector_keys());
        scanner
    }

    fn suite_prefix(name: &str) -> TransactionPrefix {
        let blob = hex::decode(vectors()[name]["blob"].as_str().unwrap()).unwrap();
        let mut pos = 0usize;
        parse_prefix_at(&blob, &mut pos).unwrap()
    }

    fn assert_spendable(s: &UtxoScanner) {
        for u in s.utxos() {
            assert_eq!(fuego_crypto::ring::secret_key_to_public_key(&u.secret_key), u.output_key);
        }
    }

    fn v2_keys(minor: u32) -> fuego_crypto::SubaddressV2Keys {
        let k = vector_keys();
        fuego_crypto::derive_subaddress_v2_keys(&k.view_secret, &k.spend_public, Some(&k.spend_secret), 0, minor).unwrap()
    }

    #[test]
    fn credits_a_single_key_payment_built_by_fuego_suite() {
        let s = recipient_scanner();
        s.scan_tx_prefix(&[1; 32], &suite_prefix("single_key_tx"), 10).unwrap();
        assert_eq!(s.balance_by_owner().get(&OutputOwner::SubaddressV2(1)), Some(&700000));
        assert_spendable(&s);
    }

    #[test]
    fn credits_a_per_output_payment_built_by_fuego_suite() {
        let s = recipient_scanner();
        s.scan_tx_prefix(&[2; 32], &suite_prefix("per_output_tx"), 10).unwrap();
        let by_owner = s.balance_by_owner();
        assert_eq!(by_owner.get(&OutputOwner::SubaddressV2(2)), Some(&300000));
        assert_eq!(by_owner.get(&OutputOwner::Primary), Some(&200000));
        assert_spendable(&s);
    }

    #[test]
    fn credits_a_standard_payment_carrying_the_filler() {
        let s = recipient_scanner();
        s.scan_tx_prefix(&[3; 32], &suite_prefix("standard_tx"), 10).unwrap();
        assert_eq!(s.balance_by_owner().get(&OutputOwner::Primary), Some(&400000));
        assert_spendable(&s);
    }

    /// A sender who knows the primary view key A pays D = B + mG with the standard
    /// derivation rA: the output underives to D, which would link the sub-address
    /// to the wallet. Without a Janus base, or with a forged one, it is not credited.
    fn linking_probe(janus: Option<[u8; 32]>) -> TransactionPrefix {
        let keys = vector_keys();
        let sub = v2_keys(1);
        let r = fuego_crypto::Keypair::from_secret([0x61u8; 32]);
        let d = fuego_crypto::generate_key_derivation(&fuego_crypto::PublicKey(keys.view_public), &r.secret).unwrap();
        let p = fuego_crypto::derive_public_key(&d, 0, &sub.spend_public).unwrap();
        let mut extra = vec![0x01];
        extra.extend_from_slice(&r.public);
        if let Some(j) = janus {
            add_subaddress_tx_keys(&mut extra, &SubaddressTxKeys { additional_pub_keys: vec![], janus_bases: vec![j] }).unwrap();
        }
        TransactionPrefix { version: 1, unlock_time: 0, inputs: Vec::new(), outputs: vec![TxOutput { amount: 5, target: OutputTarget::Key(p.0) }], extra }
    }

    #[test]
    fn linking_probes_are_not_credited() {
        let r = fuego_crypto::Keypair::from_secret([0x61u8; 32]);
        for janus in [None, Some(r.public), Some(fuego_crypto::janus_filler(&r.secret))] {
            let s = recipient_scanner();
            s.scan_tx_prefix(&[4; 32], &linking_probe(janus), 10).unwrap();
            assert!(s.utxos().is_empty(), "probe with janus {janus:?} was credited");
        }
    }

    /// A per-output tx whose 0x09 list does not cover every output cannot prove
    /// the sub-address output.
    #[test]
    fn per_output_payment_without_its_janus_base_is_not_credited() {
        let mut prefix = suite_prefix("per_output_tx");
        let mut keys = crate::serialization::parse_subaddress_tx_keys(&prefix.extra);
        keys.janus_bases.swap(0, 1);
        let pubkey_end = 33;
        prefix.extra.truncate(pubkey_end);
        add_subaddress_tx_keys(&mut prefix.extra, &keys).unwrap();
        let s = recipient_scanner();
        s.scan_tx_prefix(&[5; 32], &prefix, 10).unwrap();
        assert_eq!(s.balance_by_owner().get(&OutputOwner::SubaddressV2(2)), None);
    }

    #[test]
    fn lookahead_follows_v2_use_and_survives_restore() {
        let s = recipient_scanner();
        let sub = v2_keys(45);
        let r = fuego_crypto::Keypair::from_secret([0x71u8; 32]);
        let tx_key = fuego_crypto::subaddress_tx_pub_key(&r.secret, &sub.spend_public).unwrap();
        let d = fuego_crypto::generate_key_derivation(&fuego_crypto::PublicKey(sub.view_public), &r.secret).unwrap();
        let p = fuego_crypto::derive_public_key(&d, 0, &sub.spend_public).unwrap();
        let mut extra = vec![0x01];
        extra.extend_from_slice(&tx_key);
        add_subaddress_tx_keys(&mut extra, &SubaddressTxKeys { additional_pub_keys: vec![], janus_bases: vec![r.public] }).unwrap();
        let prefix = TransactionPrefix { version: 1, unlock_time: 0, inputs: Vec::new(), outputs: vec![TxOutput { amount: 9, target: OutputTarget::Key(p.0) }], extra };
        s.scan_tx_prefix(&[6; 32], &prefix, 10).unwrap();
        assert_eq!(s.balance_by_owner().get(&OutputOwner::SubaddressV2(45)), Some(&9));
        assert!(s.scan_keys.read().unwrap().subaddress_v2_top >= 45 + SUBADDRESS_LOOKAHEAD);

        let restored = recipient_scanner();
        restored.restore(&s.snapshot());
        assert!(restored.scan_keys.read().unwrap().subaddress_v2_top >= 45 + SUBADDRESS_LOOKAHEAD);
        assert_eq!(restored.balance_by_owner().get(&OutputOwner::SubaddressV2(45)), Some(&9));
    }

    // ── Transactions built by this SDK for the vector recipient ──────────
    // Pinned in test-vectors/valise_built_txs.json, which fuego-suite's
    // ValiseInterop test feeds through its consensus check and scanner.

    use crate::transaction_builder::{build_transaction, BuildDestination, BuiltTransaction, SpendableOutput, TxSender};
    use rand::SeedableRng;

    fn keys_from_secrets(spend_secret: [u8; 32], view_secret: [u8; 32]) -> WalletKeys {
        WalletKeys {
            spend_public: fuego_crypto::ring::secret_key_to_public_key(&spend_secret),
            view_public: fuego_crypto::ring::secret_key_to_public_key(&view_secret),
            spend_secret,
            view_secret,
        }
    }

    fn sender_keys() -> WalletKeys {
        let v = vectors();
        keys_from_secrets(key(&v["sender"]["spend_secret"]), key(&v["sender"]["view_secret"]))
    }

    fn sender_scanner() -> UtxoScanner {
        let scanner = UtxoScanner::new(WalletVault::from_seed([0x6bu8; 32]));
        *scanner.scan_keys.write().unwrap() = ScanKeys::new(&sender_keys());
        scanner
    }

    fn sender_input(amount: u64, seed: u8) -> SpendableOutput {
        let mut secret_key = [seed; 32];
        fuego_crypto::ref10::sc_reduce32(&mut secret_key);
        let output_key = fuego_crypto::ring::secret_key_to_public_key(&secret_key);
        SpendableOutput {
            amount,
            output_key,
            secret_key,
            key_image: fuego_crypto::ring::generate_key_image(&output_key, &secret_key),
            global_index: 10 + seed as u32,
            tx_hash: [seed; 32],
            output_position: 0,
        }
    }

    fn destination(amount: u64, keys: ([u8; 32], [u8; 32]), is_subaddress: bool) -> BuildDestination {
        BuildDestination { amount, spend_pub: keys.0, view_pub: keys.1, is_subaddress }
    }

    fn recipient_subaddress(minor: u32) -> ([u8; 32], [u8; 32]) {
        let sub = v2_keys(minor);
        (sub.spend_public, sub.view_public)
    }

    fn recipient_primary() -> ([u8; 32], [u8; 32]) {
        let k = vector_keys();
        (k.spend_public, k.view_public)
    }

    fn sender_change() -> ([u8; 32], [u8; 32]) {
        let k = sender_keys();
        (k.spend_public, k.view_public)
    }

    const FEE: u64 = 10000;

    fn build(dests: &[BuildDestination], janus_base: bool, seed: u8) -> BuiltTransaction {
        let total: u64 = dests.iter().map(|d| d.amount).sum::<u64>() + FEE;
        let mut rng = rand::rngs::StdRng::seed_from_u64(seed as u64);
        build_transaction(&[sender_input(total, seed)], dests, &TxSender::new(&sender_keys(), janus_base), FEE, 0, &[vec![]], 0, &[], &mut rng)
            .unwrap()
    }

    fn single_key_payment() -> BuiltTransaction {
        build(&[destination(700000, recipient_subaddress(1), true), destination(290000, sender_change(), false)], true, 0x31)
    }

    fn per_output_payment() -> BuiltTransaction {
        build(
            &[
                destination(300000, recipient_subaddress(2), true),
                destination(200000, recipient_primary(), false),
                destination(90000, sender_change(), false),
            ],
            true,
            0x32,
        )
    }

    fn standard_payment_with_filler() -> BuiltTransaction {
        build(&[destination(400000, recipient_primary(), false), destination(80000, sender_change(), false)], true, 0x33)
    }

    fn credited(scanner: &UtxoScanner, built: &BuiltTransaction) -> HashMap<OutputOwner, u64> {
        scanner.scan_tx_prefix(&built.tx_hash, &built.tx.prefix, 10).unwrap();
        assert_spendable(scanner);
        scanner.balance_by_owner()
    }

    #[test]
    fn single_key_payment_built_here_is_credited_by_both_sides() {
        let built = single_key_payment();
        let keys = crate::serialization::parse_subaddress_tx_keys(&built.tx.prefix.extra);
        assert!(keys.additional_pub_keys.is_empty());
        assert_eq!(keys.janus_bases.len(), 1);
        assert_eq!(credited(&recipient_scanner(), &built).get(&OutputOwner::SubaddressV2(1)), Some(&700000));
        assert_eq!(credited(&sender_scanner(), &built).get(&OutputOwner::Primary), Some(&290000));
    }

    #[test]
    fn per_output_payment_built_here_is_credited_by_both_sides() {
        let built = per_output_payment();
        let keys = crate::serialization::parse_subaddress_tx_keys(&built.tx.prefix.extra);
        assert_eq!(keys.additional_pub_keys.len(), 3);
        assert_eq!(keys.janus_bases.len(), 3);
        let received = credited(&recipient_scanner(), &built);
        assert_eq!(received.get(&OutputOwner::SubaddressV2(2)), Some(&300000));
        assert_eq!(received.get(&OutputOwner::Primary), Some(&200000));
        assert_eq!(credited(&sender_scanner(), &built).get(&OutputOwner::Primary), Some(&90000));
    }

    #[test]
    fn standard_payment_carries_the_filler_only_when_the_tip_is_v11() {
        let with_filler = standard_payment_with_filler();
        let r = crate::transaction_builder::recover_tx_secret(&with_filler.tx.prefix, &sender_keys()).unwrap();
        assert_eq!(crate::serialization::parse_subaddress_tx_keys(&with_filler.tx.prefix.extra).janus_bases, vec![fuego_crypto::janus_filler(&r)]);
        assert_eq!(credited(&recipient_scanner(), &with_filler).get(&OutputOwner::Primary), Some(&400000));

        let before_v11 = build(&[destination(400000, recipient_primary(), false), destination(80000, sender_change(), false)], false, 0x33);
        assert_eq!(crate::serialization::parse_subaddress_tx_keys(&before_v11.tx.prefix.extra), Default::default());
    }

    /// The tx key is seeded with the view secret: from the sender's public
    /// address alone nobody can recompute r and spot the sender's transactions.
    #[test]
    fn tx_key_is_not_derivable_from_the_public_view_key() {
        let built = standard_payment_with_filler();
        let keys = sender_keys();
        let tx_pub = crate::serialization::parse_extra_pubkey(&built.tx.prefix.extra).unwrap();
        let inputs_hash = fuego_crypto::cn_fast_hash(&crate::serialization::serialize_inputs(&built.tx.prefix.inputs));
        let seeded_with = |view_key: &[u8; 32]| {
            let mut seed = view_key.to_vec();
            seed.extend_from_slice(&inputs_hash);
            fuego_crypto::ring::secret_key_to_public_key(&fuego_crypto::ring::hash_to_scalar(&seed))
        };
        assert_eq!(seeded_with(&keys.view_secret), tx_pub);
        assert_ne!(seeded_with(&keys.view_public), tx_pub);
    }

    #[test]
    fn built_transactions_match_the_pinned_vectors() {
        let built = serde_json::json!({
            "single_key_tx": hex::encode(&single_key_payment().serialized),
            "per_output_tx": hex::encode(&per_output_payment().serialized),
            "standard_tx": hex::encode(&standard_payment_with_filler().serialized),
        });
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../test-vectors/valise_built_txs.json");
        if std::env::var_os("FUNSA_WRITE_VECTORS").is_some() {
            std::fs::write(path, serde_json::to_string_pretty(&built).unwrap() + "\n").unwrap();
        }
        let pinned: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        assert_eq!(built, pinned, "builder output changed; rerun with FUNSA_WRITE_VECTORS=1 and update fuego-suite's ValiseInterop test");
    }
}
