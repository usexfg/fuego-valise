use crate::error::{Result, SdkError};
use crate::serialization::{
    parse_extra_payment_id, parse_extra_pubkey, CommitmentSpendInput, OutputTarget,
    TransactionPrefix, TxInput, DEPOSIT_TERM_LP, DEPOSIT_TERM_POOL_HEAT, DEPOSIT_TERM_POOL_XFG,
    DEPOSIT_TERM_SWAP_RECEIVE_XFG, HEAT_TERM,
};
use crate::suite;
use crate::transaction_builder::{
    build_transaction as build_signed_transaction, compute_change, select_inputs,
    BuildDestination, BuiltTransaction, DecoyEntry, SpendableOutput, DEFAULT_DUST_THRESHOLD,
};
use crate::types::{Address, Balance};
use crate::vault::WalletVault;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
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
    /// Funding transaction's unlock_time (block index or unix time).
    pub unlock_time: u64,
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
    pub unlock_time: u64,
}

impl CommitmentEntry {
    /// Finite-term CD (not HEAT, LP share, pool reserve or swap receipt).
    pub fn is_finite_cd(&self) -> bool {
        self.term > 0
            && !matches!(
                self.term,
                HEAT_TERM
                    | DEPOSIT_TERM_LP
                    | DEPOSIT_TERM_POOL_XFG
                    | DEPOSIT_TERM_POOL_HEAT
                    | DEPOSIT_TERM_SWAP_RECEIVE_XFG
                    | suite::DIGM_TERM
            )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HistoryDirection {
    Incoming,
    Outgoing,
}

/// One confirmed transaction touching this wallet (walletd TransactionRpcInfo).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub tx_hash: [u8; 32],
    pub block_height: u64,
    pub timestamp: u64,
    /// Sign of the XFG delta (HEAT delta when no XFG moved).
    pub direction: HistoryDirection,
    /// |XFG received - XFG spent| in atomic units, fee included for sends.
    pub amount: u64,
    /// Transaction fee; 0 when this wallet spent nothing.
    pub fee: u64,
    /// HEAT received - HEAT spent.
    pub heat_delta: i64,
    pub unlock_time: u64,
    pub payment_id: Option<[u8; 32]>,
}

impl HistoryEntry {
    /// Signed XFG delta (walletd `amount`).
    pub fn signed_amount(&self) -> i64 {
        match self.direction {
            HistoryDirection::Incoming => self.amount as i64,
            HistoryDirection::Outgoing => -(self.amount as i64),
        }
    }
}

/// walletd GetBalance semantics: "unlocked" means spendable now.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct BalanceBreakdown {
    pub unlocked_xfg: u64,
    pub locked_xfg: u64,
    pub unlocked_heat: u64,
    pub locked_heat: u64,
    pub unlocked_deposits: u64,
    pub locked_deposits: u64,
}

/// CryptoNote is_tx_spendtime_unlocked, evaluated at chain tip `height`
/// (last block index).
pub fn is_unlock_time_reached(unlock_time: u64, height: u64, now_secs: u64) -> bool {
    if unlock_time < suite::CRYPTONOTE_MAX_BLOCK_NUMBER {
        height + suite::CRYPTONOTE_LOCKED_TX_ALLOWED_DELTA_BLOCKS >= unlock_time
    } else {
        now_secs + suite::CRYPTONOTE_LOCKED_TX_ALLOWED_DELTA_SECONDS >= unlock_time
    }
}

/// Wallet spendability: indexed, CRYPTONOTE_DEFAULT_TX_SPENDABLE_AGE deep,
/// and past its unlock_time (WalletLegacy transactionSpendableAge policy).
fn is_spendable(global_index: u32, block_height: u64, unlock_time: u64, height: u64, now: u64) -> bool {
    global_index != 0
        && height >= block_height + suite::CRYPTONOTE_DEFAULT_TX_SPENDABLE_AGE
        && is_unlock_time_reached(unlock_time, height, now)
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScannerStateSnapshot {
    pub height: u64,
    pub utxos: Vec<UtxoEntry>,
    pub commitments: Vec<CommitmentEntry>,
    pub spent_images: Vec<[u8; 32]>,
    pub history: Vec<HistoryEntry>,
}

pub struct UtxoScanner {
    vault: WalletVault,
    state: Arc<RwLock<ScannerState>>,
}

struct ScannerState {
    height: u64,
    utxos: Vec<UtxoEntry>,
    commitments: Vec<CommitmentEntry>,
    spent_images: HashSet<[u8; 32]>,
    history: Vec<HistoryEntry>,
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
        Self {
            vault,
            state: Arc::new(RwLock::new(ScannerState {
                height: 0,
                utxos: Vec::new(),
                commitments: Vec::new(),
                spent_images: HashSet::new(),
                history: Vec::new(),
            })),
        }
    }

    pub fn vault(&self) -> &WalletVault {
        &self.vault
    }

    pub fn vault_mut(&mut self) -> &mut WalletVault {
        &mut self.vault
    }

    /// Primary wallet keys: keypair(0) = spend, keypair(1) = view.
    ///
    /// Vault secrets are raw keccak output; CryptoNote operations
    /// (generate_key_derivation's sc_check, key images, ring signatures)
    /// require the scalar reduced mod l. The public keys are already derived
    /// from the reduced scalar, so reducing here changes no address.
    pub fn wallet_keys(&self) -> WalletKeys {
        let spend = self.vault.derive_keypair(0);
        let view = self.vault.derive_keypair(1);
        let reduce = |mut s: [u8; 32]| {
            fuego_crypto::ref10::sc_reduce32(&mut s);
            s
        };
        WalletKeys {
            spend_secret: reduce(spend.secret),
            spend_public: spend.public,
            view_secret: reduce(view.secret),
            view_public: view.public,
        }
    }

    pub fn height(&self) -> u64 {
        self.state.read().unwrap().height
    }

    pub fn set_height(&self, height: u64) {
        self.state.write().unwrap().height = height;
    }

    /// confirmed = spendable XFG, pending = owned XFG not yet spendable.
    pub fn balance(&self) -> Balance {
        let b = self.balance_breakdown_at(now_secs());
        Balance {
            confirmed: b.unlocked_xfg,
            pending: b.locked_xfg,
            immature: 0,
        }
    }

    pub fn balance_breakdown(&self) -> BalanceBreakdown {
        self.balance_breakdown_at(now_secs())
    }

    pub fn balance_breakdown_at(&self, now: u64) -> BalanceBreakdown {
        let state = self.state.read().unwrap();
        let h = state.height;
        let mut b = BalanceBreakdown::default();
        for u in state.utxos.iter().filter(|u| !state.spent_images.contains(&u.key_image)) {
            if is_spendable(u.global_index, u.block_height, u.unlock_time, h, now) {
                b.unlocked_xfg += u.amount;
            } else {
                b.locked_xfg += u.amount;
            }
        }
        for c in state.commitments.iter().filter(|c| !state.spent_images.contains(&c.key_image)) {
            if c.term == HEAT_TERM {
                if is_spendable(c.global_index, c.block_height, c.unlock_time, h, now) {
                    b.unlocked_heat += c.amount;
                } else {
                    b.locked_heat += c.amount;
                }
            } else if c.is_finite_cd() {
                if c.global_index != 0 && c.block_height + c.term as u64 <= h {
                    b.unlocked_deposits += c.amount;
                } else {
                    b.locked_deposits += c.amount;
                }
            } else if c.term == DEPOSIT_TERM_SWAP_RECEIVE_XFG {
                // Swap receipts are XFG with no spend path in this SDK.
                b.locked_xfg += c.amount;
            }
        }
        b
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

    /// HEAT the wallet can spend now (indexed, aged, unlocked, not reserved).
    pub fn spendable_heat_outputs(&self) -> Vec<CommitmentEntry> {
        let now = now_secs();
        let state = self.state.read().unwrap();
        let h = state.height;
        state
            .commitments
            .iter()
            .filter(|c| {
                c.term == HEAT_TERM
                    && !state.spent_images.contains(&c.key_image)
                    && is_spendable(c.global_index, c.block_height, c.unlock_time, h, now)
            })
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
    /// with D = a·R. Returns (received, spent) over all asset classes.
    pub fn scan_tx_prefix(
        &self,
        tx_hash: &[u8; 32],
        prefix: &TransactionPrefix,
        block_height: u64,
    ) -> Result<(u64, u64)> {
        self.scan_tx_prefix_at(tx_hash, prefix, block_height, 0)
    }

    pub fn scan_tx_prefix_at(
        &self,
        tx_hash: &[u8; 32],
        prefix: &TransactionPrefix,
        block_height: u64,
        block_timestamp: u64,
    ) -> Result<(u64, u64)> {
        let keys = self.wallet_keys();
        let mut state = self.state.write().unwrap();

        let mut received = 0u64;
        let mut spent = 0u64;
        let mut xfg_in = 0u64;
        let mut xfg_out = 0u64;
        let mut heat_in = 0u64;
        let mut heat_out = 0u64;

        for input in &prefix.inputs {
            let image = match input {
                TxInput::Key(k) => &k.key_image,
                TxInput::CommitmentSpend(c) => &c.key_image,
            };
            if let Some(idx) = state.utxos.iter().position(|u| u.key_image == *image) {
                let entry = state.utxos.remove(idx);
                state.spent_images.insert(entry.key_image);
                spent += entry.amount;
                xfg_out += entry.amount;
                continue;
            }
            if let Some(idx) = state.commitments.iter().position(|c| c.key_image == *image) {
                let entry = state.commitments.remove(idx);
                state.spent_images.insert(entry.key_image);
                spent += entry.amount;
                if entry.term == HEAT_TERM {
                    heat_out += entry.amount;
                }
            }
        }

        if let Some(r) = parse_extra_pubkey(&prefix.extra) {
            if let Some(derivation) =
                fuego_crypto::generate_key_derivation(&fuego_crypto::PublicKey(r), &keys.view_secret)
            {
                for (i, output) in prefix.outputs.iter().enumerate() {
                    match &output.target {
                        OutputTarget::Key(output_key) => {
                            let expected = match fuego_crypto::derive_public_key(
                                &derivation,
                                i as u64,
                                &keys.spend_public,
                            ) {
                                Some(p) => p,
                                None => continue,
                            };
                            if expected.0 != *output_key {
                                continue;
                            }
                            let secret = match fuego_crypto::derive_secret_key(
                                &derivation,
                                i as u64,
                                &keys.spend_secret,
                            ) {
                                Some(s) => s,
                                None => continue,
                            };
                            let key_image = fuego_crypto::generate_key_image(
                                &fuego_crypto::PublicKey(*output_key),
                                &secret,
                            );
                            state.utxos.push(UtxoEntry {
                                amount: output.amount,
                                output_key: *output_key,
                                secret_key: secret,
                                key_image: key_image.0,
                                global_index: 0,
                                tx_hash: *tx_hash,
                                output_position: i as u32,
                                block_height,
                                unlock_time: prefix.unlock_time,
                            });
                            received += output.amount;
                            xfg_in += output.amount;
                        }
                        OutputTarget::Commitment(commit) => {
                            // v2 (spend-key bound) first, then legacy v1
                            // (view-key ECDH only, spendable by the sender).
                            let v2 = fuego_crypto::ring::derive_commitment_public_key_v2(
                                &derivation,
                                i as u32,
                                &keys.spend_public,
                            );
                            let key_scalar = if v2 == Some(commit.commit_key) {
                                match fuego_crypto::ring::derive_commitment_secret_key_v2(
                                    &derivation,
                                    i as u32,
                                    &keys.spend_secret,
                                ) {
                                    Some(x) => x,
                                    None => continue,
                                }
                            } else {
                                let deposit_secret =
                                    fuego_crypto::ring::derive_deposit_secret(&derivation, i as u32);
                                let ck = fuego_crypto::ring::derive_commitment_keys(&deposit_secret);
                                if ck.commit_key != commit.commit_key {
                                    continue;
                                }
                                ck.key_scalar
                            };
                            let key_image = fuego_crypto::generate_key_image(
                                &fuego_crypto::PublicKey(commit.commit_key),
                                &key_scalar,
                            )
                            .0;
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
                                unlock_time: prefix.unlock_time,
                            });
                            received += output.amount;
                            if commit.term == HEAT_TERM {
                                heat_in += output.amount;
                            }
                        }
                    }
                }
            }
        }

        if received > 0 || spent > 0 {
            let xfg_delta = xfg_in as i128 - xfg_out as i128;
            let heat_delta = heat_in as i128 - heat_out as i128;
            let incoming = if xfg_delta != 0 { xfg_delta > 0 } else { heat_delta >= 0 };
            state.history.push(HistoryEntry {
                tx_hash: *tx_hash,
                block_height,
                timestamp: block_timestamp,
                direction: if incoming {
                    HistoryDirection::Incoming
                } else {
                    HistoryDirection::Outgoing
                },
                amount: xfg_delta.unsigned_abs().min(u64::MAX as u128) as u64,
                fee: if spent > 0 { prefix_inputs_amount_delta(prefix) } else { 0 },
                heat_delta: heat_delta.clamp(i64::MIN as i128, i64::MAX as i128) as i64,
                unlock_time: prefix.unlock_time,
                payment_id: parse_extra_payment_id(&prefix.extra),
            });
        }

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
        }
    }

    pub fn restore(&self, snapshot: &ScannerStateSnapshot) {
        let mut state = self.state.write().unwrap();
        state.height = snapshot.height;
        state.utxos = snapshot.utxos.clone();
        state.commitments = snapshot.commitments.clone();
        state.spent_images = snapshot.spent_images.iter().copied().collect();
        state.history = snapshot.history.clone();
    }

    /// Phase 1 of sending: select inputs for `amount + fee` using the bucket
    /// algorithm. Returns the selected outputs.
    pub fn select_for_send(
        &self,
        total_needed: u64,
        rng: &mut impl rand::RngCore,
    ) -> Result<Vec<UtxoEntry>> {
        let now = now_secs();
        let state = self.state.read().unwrap();
        let h = state.height;
        // Spendable: indexed (index 0 is the genesis miner output, never
        // ours), aged, unlocked, and not reserved by a pending send.
        let spendable: Vec<SpendableOutput> = state
            .utxos
            .iter()
            .filter(|u| {
                !state.spent_images.contains(&u.key_image)
                    && is_spendable(u.global_index, u.block_height, u.unlock_time, h, now)
            })
            .map(|u| u.into())
            .collect();
        let available: u64 = spendable.iter().map(|u| u.amount).sum();
        if available < total_needed {
            return Err(SdkError::InsufficientFunds {
                need: total_needed,
                have: available,
            });
        }
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
