//! CryptoNote transaction construction, ported from
//! `src/WalletLegacy/WalletTransactionSender.cpp` +
//! `src/CryptoNoteCore/CryptoNoteFormatUtils.cpp` in the daemon:
//! bucket coin selection (`selectTransfersToSend`), decimal digit change
//! decomposition (`decompose_amount_into_digits`), deterministic tx secret
//! key (`generateDeterministicTransactionKeys`), decoy ring assembly
//! (`prepareKeyInputs`) and MLSAG signing.
//!
//! This module is pure (no I/O): the caller supplies spendable outputs,
//! decoys, destinations and an RNG.
//!
//! HEAT, Hearth and CD transactions follow the v11 rules
//! (Blockchain::validateSettlement): HEAT and LP shares balance exactly, the
//! fee is the XFG surplus, every transaction declares at most one settlement
//! tag, and commitment outputs are owner-bound. [`build_v11_transaction`] and
//! the `layout_*` functions mirror the C++ wallet's v11 builders
//! (WalletTransactionSender::make*Request / v11Build).

use crate::error::{Result, SdkError};
use crate::serialization::{
    add_amm_swap_auth_extra, add_cd_bonus_claim_extra, add_heat_mint_auth_extra,
    add_heat_send_auth_extra, add_limit_deposit_extra, add_limit_withdraw_extra,
    add_lp_add_auth_extra, add_lp_remove_auth_extra, add_treasury_fund_extra,
    build_extra_with_pubkey, limit_withdraw_auth_hash, limit_withdraw_output_hash,
    serialize_inputs, serialize_tx, tx_prefix_hash, CommitmentOutputTarget, CommitmentSpendInput,
    KeyInput, OutputTarget, Transaction, TransactionPrefix, TxInput, TxOutput, AMOUNT_PROOF_LEN,
    HEAT_TERM,
};
use fuego_crypto::ring::{
    check_ring_signature, derive_commitment_output_key, derive_public_key,
    derive_secret_key, generate_key_derivation, generate_key_image, generate_ring_signature,
    hash_to_scalar,
};
use fuego_crypto::ref10::{ge_p3_tobytes, ge_scalarmult_base, GeP3};
use rand::RngCore;
use std::collections::BTreeMap;

/// Flat fee for block major version >= 10 (CryptoNoteConfig.h MINIMUM_FEE_8KH).
pub const MINIMUM_FEE: u64 = 8000;
/// Outputs below this are dust (CryptoNoteConfig.h DEFAULT_DUST_THRESHOLD).
pub const DEFAULT_DUST_THRESHOLD: u64 = 1000;
/// CryptoNoteConfig.h MAX_TX_MIXIN_SIZE.
pub const MAX_MIXIN: usize = 32;

/// A spendable output owned by this wallet.
#[derive(Debug, Clone)]
pub struct SpendableOutput {
    pub amount: u64,
    /// The one-time output key P.
    pub output_key: [u8; 32],
    /// The one-time secret key x such that x*G == P (receiver derivation).
    pub secret_key: [u8; 32],
    /// The key image I = x * H_p(P).
    pub key_image: [u8; 32],
    /// Global output index (from /get_o_indexes.bin).
    pub global_index: u32,
    /// Hash of the funding transaction.
    pub tx_hash: [u8; 32],
    /// Position of this output within its transaction (needed to attach
    /// global indices fetched per-tx).
    pub output_position: u32,
}

/// A decoy output entry from /getrandom_outs.bin.
#[derive(Debug, Clone)]
pub struct DecoyEntry {
    pub global_index: u32,
    pub out_key: [u8; 32],
}

/// One destination: an address and amount.
#[derive(Debug, Clone)]
pub struct BuildDestination {
    pub amount: u64,
    pub spend_pub: [u8; 32],
    pub view_pub: [u8; 32],
}

/// Deterministic tx secret key recovery: r = Hs(viewSecret || inputsHash),
/// the inverse of deterministic_tx_key — used to produce tx proofs for
/// previously sent transactions.
pub fn recover_tx_secret(inputs: &[TxInput], view_secret: &[u8; 32]) -> [u8; 32] {
    let (r, _r_pub) = deterministic_tx_key(view_secret, inputs);
    r
}

/// HEAT_BILL_DENOMINATIONS (CryptoNoteConfig.h), largest first.
pub const HEAT_BILL_DENOMINATIONS: [u64; 8] = [
    5_000_000_000,
    1_000_000_000,
    500_000_000,
    100_000_000,
    50_000_000,
    10_000_000,
    5_000_000,
    1_000_000,
];

/// decomposeHeatIntoBills (WalletTransactionSender.cpp:1750): greedy
/// largest-first; remainder folded into the first bill.
pub fn decompose_heat_into_bills(amount: u64) -> Vec<u64> {
    let mut bills = Vec::new();
    let mut rem = amount;
    for bill in HEAT_BILL_DENOMINATIONS {
        while rem >= bill {
            bills.push(bill);
            rem -= bill;
        }
    }
    if rem > 0 && !bills.is_empty() {
        bills[0] += rem;
    } else if bills.is_empty() {
        bills.push(amount);
    }
    bills
}

/// A signed, serializable transaction.
#[derive(Debug, Clone)]
pub struct BuiltTransaction {
    pub tx: Transaction,
    /// Hash of the serialized transaction (getObjectHash of the full tx).
    pub tx_hash: [u8; 32],
    /// Prefix hash — what the ring signatures actually sign.
    pub prefix_hash: [u8; 32],
    pub serialized: Vec<u8>,
}

/// Coin selection: port of WalletTransactionSender::selectTransfersToSend.
/// Shuffles the available outputs, buckets them by decimal digit count
/// (base10 buckets), and takes one from each bucket per round until the
/// needed amount is reached. Outputs at or below `dust` are never selected.
pub fn select_inputs(
    available: &[SpendableOutput],
    needed_money: u64,
    dust: u64,
    rng: &mut impl RngCore,
) -> (Vec<SpendableOutput>, u64) {
    use rand::seq::SliceRandom;

    let mut outputs: Vec<&SpendableOutput> =
        available.iter().filter(|o| o.amount > dust).collect();
    outputs.shuffle(rng);

    // BTreeMap instead of the C++ unordered_map: the bucket iteration order
    // is otherwise randomized per process (HashMap RandomState), which would
    // make coin selection nondeterministic. Privacy comes from the shuffle
    // above; bucket order itself does not need to be secret.
    let mut buckets: BTreeMap<usize, Vec<&SpendableOutput>> = BTreeMap::new();
    for output in outputs {
        let digits = digits_of(output.amount);
        buckets.entry(digits).or_default().push(output);
    }

    let mut selected: Vec<SpendableOutput> = Vec::new();
    let mut found_money = 0u64;

    while found_money < needed_money && !buckets.is_empty() {
        let keys: Vec<usize> = buckets.keys().copied().collect();
        for key in keys {
            let bucket = buckets.get_mut(&key).unwrap();
            if bucket.is_empty() {
                buckets.remove(&key);
                continue;
            }
            if found_money < needed_money {
                let out = bucket.pop().unwrap();
                found_money += out.amount;
                selected.push(out.clone());
            }
        }
    }

    (selected, found_money)
}

fn digits_of(mut amount: u64) -> usize {
    let mut d = 1;
    while amount >= 10 {
        amount /= 10;
        d += 1;
    }
    d
}

/// Port of decompose_amount_into_digits:
/// 62387455827 -> chunks [7000000, 80000000, 300000000, 2000000000,
/// 60000000000] with dust 455827 (<= dust_threshold).
/// Returns the non-dust chunks and the dust remainder (0 if none).
pub fn decompose_amount(amount: u64, dust_threshold: u64) -> (Vec<u64>, u64) {
    let mut chunks = Vec::new();
    let mut dust = 0u64;
    let mut dust_emitted = false;
    let mut dust_out = 0u64;
    let mut order: u64 = 1;
    let mut remaining = amount;

    while remaining != 0 {
        let chunk = (remaining % 10) * order;
        remaining /= 10;
        order *= 10;

        if dust + chunk <= dust_threshold {
            dust += chunk;
        } else {
            if !dust_emitted && dust != 0 {
                dust_out = dust;
                dust_emitted = true;
            }
            if chunk != 0 {
                chunks.push(chunk);
            }
        }
    }
    if !dust_emitted && dust != 0 {
        dust_out = dust;
    }
    (chunks, dust_out)
}

/// The dust portion is emitted as an extra output by the daemon wallet
/// (TxDustPolicy addToFee is never set in WalletTransactionSender).
pub fn decompose_change(amount: u64, dust_threshold: u64) -> (Vec<u64>, u64) {
    let (chunks, dust) = decompose_amount(amount, dust_threshold);
    (chunks, dust)
}

/// Serialize just the inputs vector (used for the deterministic tx key:
/// `r = Hs(viewSecret || getObjectHash(tx.inputs))`), matching
/// CryptoNoteFormatUtils.cpp generateDeterministicTransactionKeys.
fn inputs_hash(inputs: &[TxInput]) -> [u8; 32] {
    let bytes = serialize_inputs(inputs);
    fuego_crypto::cn_fast_hash(&bytes)
}

/// Generate the deterministic transaction key pair from the inputs hash and
/// the sender's view secret key: r = Hs(viewSecret || inputsHash), R = r*G.
fn deterministic_tx_key(view_secret: &[u8; 32], inputs: &[TxInput]) -> ([u8; 32], [u8; 32]) {
    let ih = inputs_hash(inputs);
    let mut buf = Vec::with_capacity(64);
    buf.extend_from_slice(view_secret);
    buf.extend_from_slice(&ih);
    let r = hash_to_scalar(&buf);
    let mut point = GeP3::default();
    ge_scalarmult_base(&mut point, &r);
    let mut r_pub = [0u8; 32];
    ge_p3_tobytes(&mut r_pub, &point);
    (r, r_pub)
}

/// Assemble a signed transaction.
///
/// * `inputs`: selected spendable outputs (must be sorted by amount
///   ascending before calling — see [`prepare_inputs`]).
/// * `destinations`: outputs to build (recipient amounts + change chunks +
///   dust remainder, in any order; they are sorted by amount here, matching
///   constructTransaction).
/// * `view_secret`: this wallet's view SECRET key, the tx-key source
///   (generateDeterministicTransactionKeys: r = Hs(viewSecret || H(inputs))).
///   Anything public here would let anyone holding the sender's address
///   recompute r, and with it who sent the transaction and to whom.
/// * `decoys`: per-input decoy lists (each must be exactly `mixin` entries).
/// * `fee`: flat fee (>= MINIMUM_FEE).
/// * `unlock_time`: transaction-level timestamp lock (0 = none).
/// * `extra_extra`: bytes appended to the extra after the tx pubkey tag
///   (auth tags, treasury fund tags, etc.).
#[allow(clippy::too_many_arguments)]
pub fn build_transaction(
    inputs: &[SpendableOutput],
    destinations: &[BuildDestination],
    view_secret: &[u8; 32],
    fee: u64,
    mixin: usize,
    decoys: &[Vec<DecoyEntry>],
    unlock_time: u64,
    extra_extra: &[u8],
    rng: &mut impl RngCore,
) -> Result<BuiltTransaction> {
    if inputs.is_empty() {
        return Err(SdkError::InsufficientFunds { need: fee, have: 0 });
    }
    if decoys.len() != inputs.len() {
        return Err(SdkError::Serialization(format!(
            "decoys per input mismatch: {} inputs, {} decoy groups",
            inputs.len(),
            decoys.len()
        )));
    }
    if mixin > MAX_MIXIN {
        return Err(SdkError::Serialization(format!("mixin {} > {}", mixin, MAX_MIXIN)));
    }

    // Assemble the rings first: decoys + real, sorted by global index
    // (prepareKeyInputs). The offsets field carries the absolute global
    // indices of EVERY ring member — its length IS the ring size, which the
    // deserializer uses to count signatures.
    let mut rings: Vec<Vec<(u32, [u8; 32])>> = Vec::with_capacity(inputs.len());
    let mut ring_indices: Vec<Vec<u32>> = Vec::with_capacity(inputs.len());
    for (i, input) in inputs.iter().enumerate() {
        let mut ring: Vec<(u32, [u8; 32])> = decoys[i]
            .iter()
            .map(|d| (d.global_index, d.out_key))
            .collect();
        ring.push((input.global_index, input.output_key));
        ring.sort_by_key(|(idx, _)| *idx);
        ring_indices.push(ring.iter().map(|(idx, _)| *idx).collect());
        rings.push(ring);
    }

    // Build KeyInputs. Global indices are stored absolute and sorted
    // ascending per input; serialization converts to relative differences.
    let mut wire_inputs = Vec::with_capacity(inputs.len());
    for (i, input) in inputs.iter().enumerate() {
        wire_inputs.push(TxInput::Key(KeyInput {
            amount: input.amount,
            offsets: ring_indices[i].clone(),
            key_image: input.key_image,
        }));
    }

    // Deterministic tx key (CryptoNoteFormatUtils.cpp:156).
    let (txkey, txkey_pub) = deterministic_tx_key(view_secret, &wire_inputs);

    // Outputs, sorted by amount (constructTransaction sorts destinations).
    let mut dests: Vec<BuildDestination> = destinations.to_vec();
    dests.sort_by_key(|d| d.amount);

    let mut outputs = Vec::with_capacity(dests.len());
    for (i, dst) in dests.iter().enumerate() {
        let derivation = generate_key_derivation(&dst.view_pub, &txkey)
            .ok_or_else(|| SdkError::Crypto("key derivation failed".into()))?;
        let key = derive_public_key(&derivation, i as u64, &dst.spend_pub)
            .ok_or_else(|| SdkError::Crypto("output key derivation failed".into()))?;
        outputs.push(TxOutput {
            amount: dst.amount,
            target: OutputTarget::Key(key),
        });
    }

    let mut extra = build_extra_with_pubkey(&txkey_pub);
    extra.extend_from_slice(extra_extra);

    let prefix = TransactionPrefix {
        version: 1,
        unlock_time,
        inputs: wire_inputs,
        outputs,
        extra,
    };
    let prefix_hash = tx_prefix_hash(&prefix);

    // Sign each pre-assembled ring.
    let mut signatures = Vec::with_capacity(inputs.len());
    for (i, input) in inputs.iter().enumerate() {
        let ring = &rings[i];
        let pubs: Vec<[u8; 32]> = ring.iter().map(|(_, k)| *k).collect();
        let sec_index = ring
            .iter()
            .position(|(idx, _)| *idx == input.global_index)
            .ok_or_else(|| SdkError::Crypto("real output index not found in ring".into()))?;

        // Sanity: the secret key must correspond to the real pubkey.
        debug_assert_eq!(
            generate_key_image(&input.output_key, &input.secret_key),
            input.key_image
        );

        let sig = generate_ring_signature(
            &prefix_hash,
            &input.key_image,
            &pubs,
            &input.secret_key,
            sec_index,
            rng,
        )
        .ok_or_else(|| SdkError::Crypto("ring signature generation failed".into()))?;

        #[cfg(debug_assertions)]
        {
            debug_assert!(check_ring_signature(
                &prefix_hash,
                &input.key_image,
                &pubs,
                &sig
            ));
        }
        signatures.push(sig);
    }

    let tx = Transaction {
        prefix,
        signatures,
    };
    let serialized = serialize_tx(&tx);
    let tx_hash = fuego_crypto::cn_fast_hash(&serialized);

    Ok(BuiltTransaction {
        tx,
        tx_hash,
        prefix_hash,
        serialized,
    })
}

/// Prepare inputs the way the daemon wallet does: sort by amount ascending.
pub fn prepare_inputs(mut inputs: Vec<SpendableOutput>) -> Vec<SpendableOutput> {
    inputs.sort_by_key(|i| i.amount);
    inputs
}

/// Compute the change amount and its output decomposition.
pub fn compute_change(
    found_money: u64,
    destinations_amount: u64,
    fee: u64,
    dust_threshold: u64,
) -> Result<(Vec<u64>, u64)> {
    if found_money < destinations_amount + fee {
        return Err(SdkError::InsufficientFunds {
            need: destinations_amount + fee,
            have: found_money,
        });
    }
    let change = found_money - destinations_amount - fee;
    if change == 0 {
        return Ok((Vec::new(), 0));
    }
    let (chunks, dust) = decompose_change(change, dust_threshold);
    Ok((chunks, dust))
}

/// Derive the one-time secret key for a change output chunk at the given
/// output index (receiver-side derivation, self-spendable).
pub fn change_output_secret(
    view_secret: &[u8; 32],
    txkey_pub: &[u8; 32],
    output_index: u64,
    change_spend_secret: &[u8; 32],
) -> Result<[u8; 32]> {
    let derivation = generate_key_derivation(txkey_pub, view_secret)
        .ok_or_else(|| SdkError::Crypto("change key derivation failed".into()))?;
    derive_secret_key(&derivation, output_index, change_spend_secret)
        .ok_or_else(|| SdkError::Crypto("change secret derivation failed".into()))
}

/// A commitment output being spent (HEAT or CD).
#[derive(Debug, Clone)]
pub struct CommitmentDeposit {
    pub amount: u64,
    pub commit_key: [u8; 32],
    pub key_scalar: [u8; 32],
    pub key_image: [u8; 32],
    pub global_index: u32,
    pub claimed_interest: u64,
}

// ---------------------------------------------------------------- v11

/// An address's public keys: spend key B, view key A.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AddressKeys {
    pub spend_public: [u8; 32],
    pub view_public: [u8; 32],
}

/// One output of a v11 transaction. An output's position is its derivation
/// index; the layouts below keep the C++ wallet's order
/// (WalletTransactionSender v11Build), so both build the same shapes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V11Output {
    /// XFG to an address: P = Hs(rA, i)·G + B.
    Xfg { amount: u64, to: AddressKeys },
    /// HEAT, a CD or LP shares, owner-bound to an address: P = B + Hs(rA, i)·G,
    /// spendable only with that address's spend secret
    /// (TransactionExtra.cpp deriveCommitmentOutputKey).
    Commitment { amount: u64, term: u32, to: AddressKeys },
    /// Value the pool takes, locked to the pool key (computePoolCommitKey). No
    /// ring may spend it; consensus holds it to the declared pool deposit.
    PoolMarker { amount: u64, term: u32 },
}

/// The settlement tag a v11 transaction declares — at most one
/// (Blockchain::validateSettlement). A CD withdrawal carries none.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V11Tag {
    None,
    HeatMint { xfg_burned: u64, heat_minted: u64 },
    HeatSend { amount: u64 },
    AmmSwap { direction: u8, input: u64, output: u64, min_output: u64 },
    LpAdd { amount_xfg: u64, amount_heat: u64, lp_shares: u64 },
    /// `pay_xfg` / `pay_heat` are the exact payouts (at most the shares'
    /// pro-rata claim); the wire fields carry their old "min" names.
    LpRemove { lp_shares_burned: u64, pay_xfg: u64, pay_heat: u64 },
    LimitDeposit {
        side: u8,
        amount: u64,
        target_price: u64,
        expiration: u32,
        order_id: [u8; 32],
        address_hash: [u8; 32],
    },
    /// The ownership proof signs the finished outputs with the owner's spend
    /// key, so the builder writes the tag once every output is in place.
    LimitWithdraw {
        order_id: [u8; 32],
        owner: AddressKeys,
        owner_spend_secret: [u8; 32],
    },
    TreasuryFund { asset: u8, amount: u64 },
}

/// What a v11 transaction spends: XFG key outputs, then commitment outputs
/// (HEAT, CDs, LP shares), each with its decoys. Key inputs come first on the
/// wire, as in WalletTransactionSender::addAndSignInputs.
#[derive(Debug, Clone, Default)]
pub struct V11Spend {
    pub key_inputs: Vec<SpendableOutput>,
    pub key_decoys: Vec<Vec<DecoyEntry>>,
    pub commitment_inputs: Vec<CommitmentDeposit>,
    pub commitment_decoys: Vec<Vec<(u32, [u8; 32])>>,
}

/// TransactionExtra.cpp computePoolCommitKey: Hs(cn_fast_hash(seed))·G.
pub fn pool_commit_key() -> [u8; 32] {
    let seed = fuego_crypto::cn_fast_hash(b"fuego.hearth.pool.commit.key.v1");
    fuego_crypto::ring::secret_key_to_public_key(&hash_to_scalar(&seed))
}

/// cn_fast_hash(spendPublicKey || viewPublicKey): the owner a limit order
/// records, and what its withdrawal must prove.
pub fn address_hash(owner: &AddressKeys) -> [u8; 32] {
    let mut data = [0u8; 64];
    data[..32].copy_from_slice(&owner.spend_public);
    data[32..].copy_from_slice(&owner.view_public);
    fuego_crypto::cn_fast_hash(&data)
}

/// WalletTransactionSender splitAmount: decompose_amount_into_digits in its
/// emission order — the dust (if any) first, then the digit chunks.
pub fn split_amount(amount: u64, dust_threshold: u64) -> Vec<u64> {
    let (chunks, dust) = decompose_amount(amount, dust_threshold);
    let mut out = Vec::with_capacity(chunks.len() + 1);
    if dust > 0 {
        out.push(dust);
    }
    out.extend(chunks);
    out
}

/// A ring of distinct members, the real one among them, sorted by global
/// index: (sorted members, position of the real one). A repeated member is
/// refused by consensus, so decoys equal to the real output or to each other
/// are dropped.
fn assemble_ring(
    real: (u32, [u8; 32]),
    decoys: impl Iterator<Item = (u32, [u8; 32])>,
) -> (Vec<(u32, [u8; 32])>, usize) {
    let mut seen = std::collections::BTreeSet::new();
    seen.insert(real.0);
    let mut ring = vec![real];
    for d in decoys {
        if seen.insert(d.0) {
            ring.push(d);
        }
    }
    ring.sort_by_key(|(idx, _)| *idx);
    let pos = ring.iter().position(|(idx, _)| *idx == real.0).unwrap_or(0);
    (ring, pos)
}

/// Build and sign a v11 transaction: WalletTransactionSender's
/// doSendV11Transaction. Outputs keep the given order; the tx key is
/// r = Hs(viewSecret || H(inputs)) (generateDeterministicTransactionKeys);
/// commitment outputs are owner-bound; the extra is R, the settlement tag,
/// then the CD bonus claims (input index, bonus).
pub fn build_v11_transaction(
    spend: &V11Spend,
    outputs: &[V11Output],
    tag: &V11Tag,
    bonus_claims: &[(u8, u64)],
    view_secret: &[u8; 32],
    rng: &mut impl RngCore,
) -> Result<BuiltTransaction> {
    if spend.key_inputs.is_empty() && spend.commitment_inputs.is_empty() {
        return Err(SdkError::InsufficientFunds { need: 0, have: 0 });
    }
    if spend.key_decoys.len() != spend.key_inputs.len()
        || spend.commitment_decoys.len() != spend.commitment_inputs.len()
    {
        return Err(SdkError::Serialization("one decoy group per input".into()));
    }

    // Rings and wire inputs: key inputs, then commitment spends.
    let mut wire_inputs = Vec::with_capacity(spend.key_inputs.len() + spend.commitment_inputs.len());
    // (ring keys, real position, key image, secret)
    let mut signers: Vec<(Vec<[u8; 32]>, usize, [u8; 32], [u8; 32])> = Vec::new();
    for (input, decoys) in spend.key_inputs.iter().zip(&spend.key_decoys) {
        if decoys.len() > MAX_MIXIN {
            return Err(SdkError::Serialization(format!("mixin {} > {}", decoys.len(), MAX_MIXIN)));
        }
        let (ring, pos) = assemble_ring(
            (input.global_index, input.output_key),
            decoys.iter().map(|d| (d.global_index, d.out_key)),
        );
        wire_inputs.push(TxInput::Key(KeyInput {
            amount: input.amount,
            offsets: ring.iter().map(|(i, _)| *i).collect(),
            key_image: input.key_image,
        }));
        signers.push((ring.into_iter().map(|(_, k)| k).collect(), pos, input.key_image, input.secret_key));
    }
    for (deposit, decoys) in spend.commitment_inputs.iter().zip(&spend.commitment_decoys) {
        let (ring, pos) = assemble_ring((deposit.global_index, deposit.commit_key), decoys.iter().copied());
        wire_inputs.push(TxInput::CommitmentSpend(CommitmentSpendInput {
            amount: deposit.amount,
            offsets: ring.iter().map(|(i, _)| *i).collect(),
            key_image: deposit.key_image,
            claimed_interest: deposit.claimed_interest,
        }));
        signers.push((ring.into_iter().map(|(_, k)| k).collect(), pos, deposit.key_image, deposit.key_scalar));
    }

    let (txkey, txkey_pub) = deterministic_tx_key(view_secret, &wire_inputs);

    let mut wire_outputs = Vec::with_capacity(outputs.len());
    for (i, output) in outputs.iter().enumerate() {
        let index = i as u64;
        let (amount, target) = match output {
            V11Output::Xfg { amount, to } => {
                let d = generate_key_derivation(&to.view_public, &txkey)
                    .ok_or_else(|| SdkError::Crypto("output key derivation failed".into()))?;
                let key = derive_public_key(&d, index, &to.spend_public)
                    .ok_or_else(|| SdkError::Crypto("output key derivation failed".into()))?;
                (*amount, OutputTarget::Key(key))
            }
            V11Output::Commitment { amount, term, to } => {
                let d = generate_key_derivation(&to.view_public, &txkey)
                    .ok_or_else(|| SdkError::Crypto("commitment key derivation failed".into()))?;
                let commit_key = derive_commitment_output_key(&d, index, Some(&to.spend_public))
                    .ok_or_else(|| SdkError::Crypto("owner-bound commitment key derivation failed".into()))?;
                (*amount, commitment_target(commit_key, *term))
            }
            V11Output::PoolMarker { amount, term } => (*amount, commitment_target(pool_commit_key(), *term)),
        };
        if amount == 0 {
            return Err(SdkError::Serialization(format!("output {i} has no amount")));
        }
        wire_outputs.push(TxOutput { amount, target });
    }

    let mut extra = build_extra_with_pubkey(&txkey_pub);
    write_tag(&mut extra, tag, &wire_outputs, rng)?;
    for (input_index, bonus) in bonus_claims {
        add_cd_bonus_claim_extra(&mut extra, *input_index, *bonus);
    }

    let has_commitments = !spend.commitment_inputs.is_empty()
        || wire_outputs.iter().any(|o| matches!(o.target, OutputTarget::Commitment(_)));
    let prefix = TransactionPrefix {
        version: if has_commitments {
            crate::serialization::TX_VERSION_2
        } else {
            crate::serialization::TX_VERSION_1
        },
        unlock_time: 0,
        inputs: wire_inputs,
        outputs: wire_outputs,
        extra,
    };
    let prefix_hash = tx_prefix_hash(&prefix);

    let mut signatures = Vec::with_capacity(signers.len());
    for (ring, pos, key_image, secret) in &signers {
        let sig = generate_ring_signature(&prefix_hash, key_image, ring, secret, *pos, rng)
            .ok_or_else(|| SdkError::Crypto("ring signature generation failed".into()))?;
        debug_assert!(check_ring_signature(&prefix_hash, key_image, ring, &sig));
        signatures.push(sig);
    }

    let tx = Transaction { prefix, signatures };
    let serialized = serialize_tx(&tx);
    let tx_hash = fuego_crypto::cn_fast_hash(&serialized);
    Ok(BuiltTransaction { tx, tx_hash, prefix_hash, serialized })
}

fn commitment_target(commit_key: [u8; 32], term: u32) -> OutputTarget {
    OutputTarget::Commitment(CommitmentOutputTarget {
        commit_key,
        term,
        amount_commitment: [0u8; 32],
        amount_proof: [0u8; AMOUNT_PROOF_LEN],
    })
}

fn write_tag(
    extra: &mut Vec<u8>,
    tag: &V11Tag,
    outputs: &[TxOutput],
    rng: &mut impl RngCore,
) -> Result<()> {
    match tag {
        V11Tag::None => {}
        V11Tag::HeatMint { xfg_burned, heat_minted } => {
            add_heat_mint_auth_extra(extra, *xfg_burned, *heat_minted)
        }
        V11Tag::HeatSend { amount } => add_heat_send_auth_extra(extra, *amount),
        V11Tag::AmmSwap { direction, input, output, min_output } => {
            add_amm_swap_auth_extra(extra, *direction, *input, *output, *min_output)
        }
        V11Tag::LpAdd { amount_xfg, amount_heat, lp_shares } => {
            add_lp_add_auth_extra(extra, *amount_xfg, *amount_heat, *lp_shares)
        }
        V11Tag::LpRemove { lp_shares_burned, pay_xfg, pay_heat } => {
            add_lp_remove_auth_extra(extra, *lp_shares_burned, *pay_xfg, *pay_heat)
        }
        V11Tag::LimitDeposit { side, amount, target_price, expiration, order_id, address_hash } => {
            add_limit_deposit_extra(extra, *side, *amount, *target_price, *expiration, order_id, address_hash)
        }
        V11Tag::LimitWithdraw { order_id, owner, owner_spend_secret } => {
            let outputs_hash = limit_withdraw_output_hash(outputs);
            let auth = limit_withdraw_auth_hash(order_id, &address_hash(owner), &outputs_hash);
            let proof = fuego_crypto::ring::generate_signature(&auth, &owner.spend_public, owner_spend_secret, rng)
                .ok_or_else(|| SdkError::Crypto("limit withdraw proof failed".into()))?;
            add_limit_withdraw_extra(extra, order_id, &owner.spend_public, &owner.view_public, &outputs_hash, &proof);
        }
        V11Tag::TreasuryFund { asset, amount } => add_treasury_fund_extra(extra, *asset, *amount),
    }
    Ok(())
}

// ------------------------------------------------- v11 layouts (C++ v11Build)

/// addXfgToSelf: XFG split into digit chunks (nothing for 0).
pub fn xfg_outputs(to: AddressKeys, amount: u64) -> Vec<V11Output> {
    if amount == 0 {
        return Vec::new();
    }
    split_amount(amount, DEFAULT_DUST_THRESHOLD)
        .into_iter()
        .map(|amount| V11Output::Xfg { amount, to })
        .collect()
}

/// addHeatToSelf: HEAT as standard bills (nothing for 0).
pub fn heat_bill_outputs(to: AddressKeys, amount: u64) -> Vec<V11Output> {
    if amount == 0 {
        return Vec::new();
    }
    decompose_heat_into_bills(amount)
        .into_iter()
        .map(|amount| V11Output::Commitment { amount, term: HEAT_TERM, to })
        .collect()
}

fn one_commitment(to: AddressKeys, amount: u64, term: u32) -> Vec<V11Output> {
    if amount == 0 {
        return Vec::new();
    }
    vec![V11Output::Commitment { amount, term, to }]
}

/// makeHeatMintV10Request: HEAT bills for the mint, then XFG change. XFG in
/// = change + burn + fee; consensus holds the HEAT to the burn at the TWAP.
pub fn layout_mint(own: AddressKeys, xfg_burned: u64, heat_minted: u64, xfg_change: u64) -> (Vec<V11Output>, V11Tag) {
    let mut outputs = heat_bill_outputs(own, heat_minted);
    outputs.extend(xfg_outputs(own, xfg_change));
    (outputs, V11Tag::HeatMint { xfg_burned, heat_minted })
}

/// makeAmmSwapV10Request. Direction 0 (XFG in): pool marker, HEAT bills, XFG
/// change. Direction 1 (HEAT in): pool marker, the XFG received less the fee,
/// HEAT change. `change` is XFG change for 0 and HEAT change for 1.
pub fn layout_swap(
    own: AddressKeys,
    direction: u8,
    input: u64,
    output: u64,
    min_output: u64,
    fee: u64,
    change: u64,
) -> Result<(Vec<V11Output>, V11Tag)> {
    let mut outputs = Vec::new();
    if direction == 0 {
        outputs.push(V11Output::PoolMarker { amount: input, term: crate::serialization::DEPOSIT_TERM_POOL_XFG });
        outputs.extend(heat_bill_outputs(own, output));
        outputs.extend(xfg_outputs(own, change));
    } else {
        if output <= fee {
            return Err(SdkError::Serialization("swap output does not cover the fee".into()));
        }
        outputs.push(V11Output::PoolMarker { amount: input, term: crate::serialization::DEPOSIT_TERM_POOL_HEAT });
        outputs.extend(xfg_outputs(own, output - fee));
        outputs.extend(one_commitment(own, change, HEAT_TERM));
    }
    Ok((outputs, V11Tag::AmmSwap { direction, input, output, min_output }))
}

/// makeHeatTransferV10Request: the recipient's HEAT (owner-bound to them),
/// HEAT change, XFG change. HEAT balances exactly; XFG pays the fee.
pub fn layout_heat_send(
    own: AddressKeys,
    recipient: AddressKeys,
    amount: u64,
    heat_change: u64,
    xfg_change: u64,
) -> (Vec<V11Output>, V11Tag) {
    let mut outputs = one_commitment(recipient, amount, HEAT_TERM);
    outputs.extend(one_commitment(own, heat_change, HEAT_TERM));
    outputs.extend(xfg_outputs(own, xfg_change));
    (outputs, V11Tag::HeatSend { amount })
}

/// makeHeatDepositV10Request: the CD, HEAT change, XFG change; the banking
/// fee is HEAT burned to the Treasury LP Manager (TreasuryFund, asset 1).
pub fn layout_cd_create(
    own: AddressKeys,
    amount: u64,
    term_blocks: u32,
    banking_fee: u64,
    heat_change: u64,
    xfg_change: u64,
) -> (Vec<V11Output>, V11Tag) {
    let mut outputs = one_commitment(own, amount, term_blocks);
    outputs.extend(one_commitment(own, heat_change, HEAT_TERM));
    outputs.extend(xfg_outputs(own, xfg_change));
    (outputs, V11Tag::TreasuryFund { asset: 1, amount: banking_fee })
}

/// makeWithdrawDepositRequest (HEAT CDs): principal and interest come back as
/// HEAT bills, then XFG change; no settlement tag.
pub fn layout_cd_withdraw(own: AddressKeys, payout: u64, xfg_change: u64) -> (Vec<V11Output>, V11Tag) {
    let mut outputs = heat_bill_outputs(own, payout);
    outputs.extend(xfg_outputs(own, xfg_change));
    (outputs, V11Tag::None)
}

/// A matured CD (principal and interest) into a new CD; XFG pays the fee.
/// Not a C++ wallet flow, but it settles the same way: HEAT in (principal +
/// claimed interest) equals HEAT out.
pub fn layout_cd_rollover(own: AddressKeys, rolled: u64, term_blocks: u32, xfg_change: u64) -> (Vec<V11Output>, V11Tag) {
    let mut outputs = one_commitment(own, rolled, term_blocks);
    outputs.extend(xfg_outputs(own, xfg_change));
    (outputs, V11Tag::None)
}

/// doSendLpAddV10Transaction: the LP shares, HEAT change bills, XFG change.
pub fn layout_lp_add(
    own: AddressKeys,
    amount_xfg: u64,
    amount_heat: u64,
    lp_shares: u64,
    heat_change: u64,
    xfg_change: u64,
) -> (Vec<V11Output>, V11Tag) {
    let mut outputs = one_commitment(own, lp_shares, crate::serialization::DEPOSIT_TERM_LP);
    outputs.extend(heat_bill_outputs(own, heat_change));
    outputs.extend(xfg_outputs(own, xfg_change));
    (outputs, V11Tag::LpAdd { amount_xfg, amount_heat, lp_shares })
}

/// doSendLpRemoveV10Transaction: the XFG payout less the fee, the HEAT payout
/// as bills, and the shares kept as a smaller LP position.
pub fn layout_lp_remove(
    own: AddressKeys,
    lp_shares_burned: u64,
    pay_xfg: u64,
    pay_heat: u64,
    fee: u64,
    lp_change: u64,
) -> Result<(Vec<V11Output>, V11Tag)> {
    if pay_xfg <= fee {
        return Err(SdkError::Serialization("LP removal's XFG payout does not cover the fee".into()));
    }
    let mut outputs = xfg_outputs(own, pay_xfg - fee);
    outputs.extend(heat_bill_outputs(own, pay_heat));
    outputs.extend(one_commitment(own, lp_change, crate::serialization::DEPOSIT_TERM_LP));
    Ok((outputs, V11Tag::LpRemove { lp_shares_burned, pay_xfg, pay_heat }))
}

/// makePlaceOrderV13Request: the escrow as a pool marker (XFG for side 1,
/// HEAT for side 0), HEAT change, XFG change. `expiration` is an absolute
/// block height.
#[allow(clippy::too_many_arguments)]
pub fn layout_place_order(
    own: AddressKeys,
    side: u8,
    amount: u64,
    target_price: u64,
    expiration: u32,
    order_id: [u8; 32],
    heat_change: u64,
    xfg_change: u64,
) -> Result<(Vec<V11Output>, V11Tag)> {
    if side > 1 || amount == 0 {
        return Err(SdkError::Serialization("limit order: invalid side or zero amount".into()));
    }
    if target_price == 0 || target_price % crate::amm::ORDER_PRICE_TICK != 0 {
        return Err(SdkError::Serialization("limit order: price must be a multiple of the price tick".into()));
    }
    let term = if side == 1 {
        crate::serialization::DEPOSIT_TERM_POOL_XFG
    } else {
        crate::serialization::DEPOSIT_TERM_POOL_HEAT
    };
    let mut outputs = vec![V11Output::PoolMarker { amount, term }];
    outputs.extend(one_commitment(own, heat_change, HEAT_TERM));
    outputs.extend(xfg_outputs(own, xfg_change));
    let tag = V11Tag::LimitDeposit {
        side,
        amount,
        target_price,
        expiration,
        order_id,
        address_hash: address_hash(&own),
    };
    Ok((outputs, tag))
}

/// makeCancelOrderV13Request: XFG change, the XFG paid out, the HEAT paid
/// out as bills; the tag proves ownership over exactly these outputs.
pub fn layout_cancel_order(
    own: AddressKeys,
    own_spend_secret: [u8; 32],
    order_id: [u8; 32],
    pay_xfg: u64,
    pay_heat: u64,
    xfg_change: u64,
) -> (Vec<V11Output>, V11Tag) {
    let mut outputs = xfg_outputs(own, xfg_change);
    outputs.extend(xfg_outputs(own, pay_xfg));
    outputs.extend(heat_bill_outputs(own, pay_heat));
    (outputs, V11Tag::LimitWithdraw { order_id, owner: own, owner_spend_secret: own_spend_secret })
}
