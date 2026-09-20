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

use crate::error::{Result, SdkError};
use crate::serialization::{
    add_amm_swap_auth_extra, add_heat_mint_auth_extra, add_limit_deposit_extra,
    add_lp_add_auth_extra, add_lp_remove_auth_extra, build_extra_with_pubkey, serialize_inputs,
    serialize_tx, tx_prefix_hash, CommitmentOutputTarget, CommitmentSpendInput, KeyInput,
    OutputTarget, Transaction, TransactionPrefix, TxInput, TxOutput, HEAT_TERM, AMOUNT_PROOF_LEN,
};
use fuego_crypto::ring::{
    check_ring_signature, derive_commitment_keys, derive_deposit_secret, derive_public_key,
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

/// A commitment destination: minted HEAT or a term-locked CD. The commit
/// key is derived by the builder from the tx secret key and the given view
/// key (depositSecret = Hs(D || outputIndex), D = 8*(r*V)). `view_pub`
/// defaults to the wallet's own view key (mint/CD); HEAT transfers pass the
/// recipient's view key so only the recipient can spend the output.
#[derive(Debug, Clone)]
pub struct BuildCommitmentDestination {
    pub amount: u64,
    pub term: u32,
    pub view_pub: Option<[u8; 32]>,
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
/// * `view_pub`: this wallet's view public key (the tx-key derivation
///   source, generateDeterministicTransactionKeys).
/// * `decoys`: per-input decoy lists (each must be exactly `mixin` entries).
/// * `fee`: flat fee (>= MINIMUM_FEE).
/// * `unlock_time`: transaction-level timestamp lock (0 = none).
/// * `extra_extra`: bytes appended to the extra after the tx pubkey tag
///   (auth tags, treasury fund tags, etc.).
pub fn build_transaction(
    inputs: &[SpendableOutput],
    destinations: &[BuildDestination],
    view_pub: &[u8; 32],
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
    let (txkey, txkey_pub) = deterministic_tx_key(view_pub, &wire_inputs); // the key pair is used for output derivation below

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

/// Build and sign a transaction with KeyInputs and a mix of key outputs
/// and commitment outputs. Commitment outputs are serialized FIRST (matching
/// the daemon wallet's addOutput order), so their deposit secrets derive from
/// their position: depositSecret = Hs(D || outputIndex), D = 8*(r*V).
#[allow(clippy::too_many_arguments)]
pub fn build_mixed_output_transaction(
    inputs: &[SpendableOutput],
    decoys: &[Vec<DecoyEntry>],
    mixin: usize,
    commitment_destinations: &[BuildCommitmentDestination],
    key_destinations: &[BuildDestination],
    view_pub: &[u8; 32],
    fee: u64,
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
    for (i, group) in decoys.iter().enumerate() {
        if group.len() != mixin {
            return Err(SdkError::Serialization(format!(
                "input {} has {} decoys, expected {}",
                i,
                group.len(),
                mixin
            )));
        }
    }

    // Assemble rings (KeyInput style) for the deterministic tx key.
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

    let mut wire_inputs = Vec::with_capacity(inputs.len());
    for (i, input) in inputs.iter().enumerate() {
        wire_inputs.push(TxInput::Key(KeyInput {
            amount: input.amount,
            offsets: ring_indices[i].clone(),
            key_image: input.key_image,
        }));
    }

    let (txkey, txkey_pub) = deterministic_tx_key(view_pub, &wire_inputs);
    let tx_derivation = generate_key_derivation(view_pub, &txkey)
        .ok_or_else(|| SdkError::Crypto("tx key derivation failed".into()))?;

    // Commitment outputs first (daemon wallet order), then key outputs.
    let mut outputs = Vec::with_capacity(commitment_destinations.len() + key_destinations.len());
    let mut out_index = 0usize;
    for cdest in commitment_destinations {
        let dest_view = cdest.view_pub.as_ref().unwrap_or(view_pub);
        let dest_derivation = if dest_view == view_pub {
            tx_derivation
        } else {
            generate_key_derivation(dest_view, &txkey)
                .ok_or_else(|| SdkError::Crypto("dest tx key derivation failed".into()))?
        };
        let deposit_secret = derive_deposit_secret(&dest_derivation, out_index as u32);
        let ck = derive_commitment_keys(&deposit_secret);
        out_index += 1;
        outputs.push(TxOutput {
            amount: cdest.amount,
            target: OutputTarget::Commitment(CommitmentOutputTarget {
                commit_key: ck.commit_key,
                term: cdest.term,
                amount_commitment: [0u8; 32],
                amount_proof: [0u8; AMOUNT_PROOF_LEN],
            }),
        });
    }

    let mut key_dests: Vec<BuildDestination> = key_destinations.to_vec();
    key_dests.sort_by_key(|d| d.amount);
    for dst in &key_dests {
        let d = generate_key_derivation(&dst.view_pub, &txkey)
            .ok_or_else(|| SdkError::Crypto("key derivation failed".into()))?;
        let key = derive_public_key(&d, out_index as u64, &dst.spend_pub)
            .ok_or_else(|| SdkError::Crypto("output key derivation failed".into()))?;
        out_index += 1;
        outputs.push(TxOutput {
            amount: dst.amount,
            target: OutputTarget::Key(key),
        });
    }

    let mut extra = build_extra_with_pubkey(&txkey_pub);
    extra.extend_from_slice(extra_extra);

    let has_commitment_outputs = !commitment_destinations.is_empty();
    let prefix = TransactionPrefix {
        version: if has_commitment_outputs {
            crate::serialization::TX_VERSION_2
        } else {
            crate::serialization::TX_VERSION_1
        },
        unlock_time: 0,
        inputs: wire_inputs,
        outputs,
        extra,
    };
    let prefix_hash = tx_prefix_hash(&prefix);

    let mut signatures = Vec::with_capacity(inputs.len());
    for (i, input) in inputs.iter().enumerate() {
        let ring = &rings[i];
        let pubs: Vec<[u8; 32]> = ring.iter().map(|(_, k)| *k).collect();
        let sec_index = ring
            .iter()
            .position(|(idx, _)| *idx == input.global_index)
            .ok_or_else(|| SdkError::Crypto("real output index not found in ring".into()))?;
        let sig = generate_ring_signature(
            &prefix_hash,
            &input.key_image,
            &pubs,
            &input.secret_key,
            sec_index,
            rng,
        )
        .ok_or_else(|| SdkError::Crypto("ring signature generation failed".into()))?;
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

/// Build and sign a HEAT mint transaction (doSendHeatMintV10Transaction):
/// XFG KeyInputs in, HEAT commitment outputs (term = HEAT_TERM, bill
/// denominations) + XFG change out, 0xF5 auth extra.
#[allow(clippy::too_many_arguments)]
pub fn build_mint_transaction(
    inputs: &[SpendableOutput],
    decoys: &[Vec<DecoyEntry>],
    mixin: usize,
    xfg_burned: u64,
    heat_minted: u64,
    price_height: u32,
    change: u64,
    view_pub: &[u8; 32],
    change_keys: (&[u8; 32], &[u8; 32]),
    fee: u64,
    rng: &mut impl RngCore,
) -> Result<BuiltTransaction> {
    let (change_spend, change_view) = change_keys;

    let bills = decompose_heat_into_bills(heat_minted);
    let commitment_dests: Vec<BuildCommitmentDestination> = bills
        .iter()
        .map(|b| BuildCommitmentDestination {
            amount: *b,
            term: crate::serialization::HEAT_TERM,
            view_pub: None,
        })
        .collect();

    let (change_chunks, dust) = decompose_change(change, DEFAULT_DUST_THRESHOLD);
    let mut key_dests: Vec<BuildDestination> = Vec::with_capacity(change_chunks.len() + 1);
    for chunk in change_chunks {
        key_dests.push(BuildDestination {
            amount: chunk,
            spend_pub: *change_spend,
            view_pub: *change_view,
        });
    }
    if dust > 0 {
        key_dests.push(BuildDestination {
            amount: dust,
            spend_pub: *change_spend,
            view_pub: *change_view,
        });
    }

    let mut extra = Vec::new();
    add_heat_mint_auth_extra(&mut extra, xfg_burned, heat_minted, price_height);

    build_mixed_output_transaction(
        inputs,
        decoys,
        mixin,
        &commitment_dests,
        &key_dests,
        view_pub,
        fee,
        &extra,
        rng,
    )
}

/// Build and sign a commitment-spend transaction (CD claim / heat_cd /
/// HEAT transfer): CommitmentSpendInput rings over global commitment
/// indices, using the same MLSAG ring signature.
#[allow(clippy::too_many_arguments)]
pub fn build_commitment_spend_transaction(
    deposits: &[CommitmentDeposit],
    decoys: &[Vec<(u32, [u8; 32])>],
    ring_size: usize,
    key_destinations: &[BuildDestination],
    commitment_destinations: &[BuildCommitmentDestination],
    view_pub: &[u8; 32],
    fee: u64,
    extra_extra: &[u8],
    rng: &mut impl RngCore,
) -> Result<BuiltTransaction> {
    if deposits.is_empty() {
        return Err(SdkError::InsufficientFunds { need: fee, have: 0 });
    }
    if decoys.len() != deposits.len() {
        return Err(SdkError::Serialization(format!(
            "decoys per input mismatch: {} deposits, {} decoy groups",
            deposits.len(),
            decoys.len()
        )));
    }

    // Rings: decoys + real sorted by global commitment index.
    let mut rings: Vec<Vec<(u32, [u8; 32])>> = Vec::with_capacity(deposits.len());
    let mut ring_indices: Vec<Vec<u32>> = Vec::with_capacity(deposits.len());
    for (i, deposit) in deposits.iter().enumerate() {
        let mut ring = decoys[i].clone();
        ring.push((deposit.global_index, deposit.commit_key));
        ring.sort_by_key(|(idx, _)| *idx);
        ring_indices.push(ring.iter().map(|(idx, _)| *idx).collect());
        rings.push(ring);
    }

    let mut wire_inputs = Vec::with_capacity(deposits.len());
    for (i, deposit) in deposits.iter().enumerate() {
        wire_inputs.push(TxInput::CommitmentSpend(CommitmentSpendInput {
            amount: deposit.amount,
            offsets: ring_indices[i].clone(),
            key_image: deposit.key_image,
            claimed_interest: deposit.claimed_interest,
        }));
    }

    let (txkey, txkey_pub) = deterministic_tx_key(view_pub, &wire_inputs);

    // Key outputs (payouts + change), sorted by amount.
    let mut key_dests: Vec<BuildDestination> = key_destinations.to_vec();
    key_dests.sort_by_key(|d| d.amount);
    let mut outputs = Vec::with_capacity(key_dests.len() + commitment_destinations.len());
    let mut out_index = 0usize;
    for dst in &key_dests {
        let d = generate_key_derivation(&dst.view_pub, &txkey)
            .ok_or_else(|| SdkError::Crypto("payout derivation failed".into()))?;
        let key = derive_public_key(&d, out_index as u64, &dst.spend_pub)
            .ok_or_else(|| SdkError::Crypto("payout key derivation failed".into()))?;
        outputs.push(TxOutput {
            amount: dst.amount,
            target: OutputTarget::Key(key),
        });
        out_index += 1;
    }
    let tx_derivation = generate_key_derivation(view_pub, &txkey)
        .ok_or_else(|| SdkError::Crypto("commitment derivation failed".into()))?;
    for cdest in commitment_destinations {
        let dest_view = cdest.view_pub.as_ref().unwrap_or(view_pub);
        let dest_derivation = if dest_view == view_pub {
            tx_derivation
        } else {
            generate_key_derivation(dest_view, &txkey)
                .ok_or_else(|| SdkError::Crypto("dest tx key derivation failed".into()))?
        };
        let deposit_secret = derive_deposit_secret(&dest_derivation, out_index as u32);
        let ck = derive_commitment_keys(&deposit_secret);
        out_index += 1;
        outputs.push(TxOutput {
            amount: cdest.amount,
            target: OutputTarget::Commitment(CommitmentOutputTarget {
                commit_key: ck.commit_key,
                term: cdest.term,
                amount_commitment: [0u8; 32],
                amount_proof: [0u8; AMOUNT_PROOF_LEN],
            }),
        });
    }

    let mut extra = build_extra_with_pubkey(&txkey_pub);
    extra.extend_from_slice(extra_extra);

    let has_commitment_outputs = !commitment_destinations.is_empty();
    let prefix = TransactionPrefix {
        version: if has_commitment_outputs {
            crate::serialization::TX_VERSION_2
        } else {
            crate::serialization::TX_VERSION_1
        },
        unlock_time: 0,
        inputs: wire_inputs,
        outputs,
        extra,
    };
    let prefix_hash = tx_prefix_hash(&prefix);

    let mut signatures = Vec::with_capacity(deposits.len());
    for (i, deposit) in deposits.iter().enumerate() {
        let ring = &rings[i];
        let pubs: Vec<[u8; 32]> = ring.iter().map(|(_, k)| *k).collect();
        let sec_index = ring
            .iter()
            .position(|(idx, _)| *idx == deposit.global_index)
            .ok_or_else(|| SdkError::Crypto("real commitment index not found in ring".into()))?;
        debug_assert!(pubs.len() >= ring_size.min(1));
        let sig = generate_ring_signature(
            &prefix_hash,
            &deposit.key_image,
            &pubs,
            &deposit.key_scalar,
            sec_index,
            rng,
        )
        .ok_or_else(|| SdkError::Crypto("commitment ring signature failed".into()))?;
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

/// A pool-side commitment output with an explicit commit key (the Hearth
/// pool commit key). Used for limit-order deposits; the pool spends it.
#[derive(Debug, Clone)]
pub struct BuildPoolCommitmentDestination {
    pub amount: u64,
    pub commit_key: [u8; 32],
    pub term: u32,
}

/// Assemble outputs and sign a transaction from pre-built wire inputs and
/// per-input ring signers (public keys, real index, key image, secret scalar).
#[allow(clippy::too_many_arguments)]
fn assemble_outputs_and_sign(
    wire_inputs: &[TxInput],
    signers: &[(Vec<[u8; 32]>, usize, [u8; 32], [u8; 32])],
    commitment_destinations: &[BuildCommitmentDestination],
    key_destinations: &[BuildDestination],
    pool_destinations: &[BuildPoolCommitmentDestination],
    view_pub: &[u8; 32],
    extra_extra: &[u8],
    rng: &mut impl RngCore,
) -> Result<BuiltTransaction> {
    let (txkey, txkey_pub) = deterministic_tx_key(view_pub, wire_inputs);
    let tx_derivation = generate_key_derivation(view_pub, &txkey)
        .ok_or_else(|| SdkError::Crypto("tx key derivation failed".into()))?;

    // Commitment outputs first (daemon wallet order), then key outputs.
    let mut outputs = Vec::with_capacity(
        commitment_destinations.len() + key_destinations.len() + pool_destinations.len(),
    );
    let mut out_index = 0usize;
    for cdest in commitment_destinations {
        let dest_view = cdest.view_pub.as_ref().unwrap_or(view_pub);
        let dest_derivation = if dest_view == view_pub {
            tx_derivation
        } else {
            generate_key_derivation(dest_view, &txkey)
                .ok_or_else(|| SdkError::Crypto("dest tx key derivation failed".into()))?
        };
        let deposit_secret = derive_deposit_secret(&dest_derivation, out_index as u32);
        let ck = derive_commitment_keys(&deposit_secret);
        out_index += 1;
        outputs.push(TxOutput {
            amount: cdest.amount,
            target: OutputTarget::Commitment(CommitmentOutputTarget {
                commit_key: ck.commit_key,
                term: cdest.term,
                amount_commitment: [0u8; 32],
                amount_proof: [0u8; AMOUNT_PROOF_LEN],
            }),
        });
    }
    for pdest in pool_destinations {
        outputs.push(TxOutput {
            amount: pdest.amount,
            target: OutputTarget::Commitment(CommitmentOutputTarget {
                commit_key: pdest.commit_key,
                term: pdest.term,
                amount_commitment: [0u8; 32],
                amount_proof: [0u8; AMOUNT_PROOF_LEN],
            }),
        });
        out_index += 1;
    }

    let mut key_dests: Vec<BuildDestination> = key_destinations.to_vec();
    key_dests.sort_by_key(|d| d.amount);
    for dst in &key_dests {
        let d = generate_key_derivation(&dst.view_pub, &txkey)
            .ok_or_else(|| SdkError::Crypto("key derivation failed".into()))?;
        let key = derive_public_key(&d, out_index as u64, &dst.spend_pub)
            .ok_or_else(|| SdkError::Crypto("output key derivation failed".into()))?;
        out_index += 1;
        outputs.push(TxOutput {
            amount: dst.amount,
            target: OutputTarget::Key(key),
        });
    }

    let mut extra = build_extra_with_pubkey(&txkey_pub);
    extra.extend_from_slice(extra_extra);

    let has_commitment_outputs = !commitment_destinations.is_empty() || !pool_destinations.is_empty();
    let prefix = TransactionPrefix {
        version: if has_commitment_outputs {
            crate::serialization::TX_VERSION_2
        } else {
            crate::serialization::TX_VERSION_1
        },
        unlock_time: 0,
        inputs: wire_inputs.to_vec(),
        outputs,
        extra,
    };
    let prefix_hash = tx_prefix_hash(&prefix);

    let mut signatures = Vec::with_capacity(signers.len());
    for (pubs, sec_index, key_image, secret_key) in signers {
        let sig = generate_ring_signature(
            &prefix_hash,
            key_image,
            pubs,
            secret_key,
            *sec_index,
            rng,
        )
        .ok_or_else(|| SdkError::Crypto("ring signature generation failed".into()))?;
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

/// Build and sign an AMM swap XFG→HEAT (direction 0): XFG KeyInputs in,
/// HEAT commitment outputs (HEAT_TERM bills) + XFG change out, 0xF6 auth.
/// The pool gains the input delta and pays the HEAT output at settlement.
#[allow(clippy::too_many_arguments)]
pub fn build_swap_xfg_to_heat_transaction(
    inputs: &[SpendableOutput],
    decoys: &[Vec<DecoyEntry>],
    mixin: usize,
    input_amount: u64,
    heat_received: u64,
    min_output: u64,
    change_keys: (&[u8; 32], &[u8; 32]),
    view_pub: &[u8; 32],
    fee: u64,
    rng: &mut impl RngCore,
) -> Result<BuiltTransaction> {
    let found: u64 = inputs.iter().map(|u| u.amount).sum();
    let change = found - input_amount - fee;

    let bills = decompose_heat_into_bills(heat_received);
    let commitment_dests: Vec<BuildCommitmentDestination> = bills
        .iter()
        .map(|b| BuildCommitmentDestination {
            amount: *b,
            term: HEAT_TERM,
            view_pub: None,
        })
        .collect();

    let (change_spend, change_view) = change_keys;
    let (change_chunks, dust) = decompose_change(change, DEFAULT_DUST_THRESHOLD);
    let mut key_dests: Vec<BuildDestination> = Vec::with_capacity(change_chunks.len() + 1);
    for chunk in change_chunks {
        key_dests.push(BuildDestination {
            amount: chunk,
            spend_pub: *change_spend,
            view_pub: *change_view,
        });
    }
    if dust > 0 {
        key_dests.push(BuildDestination {
            amount: dust,
            spend_pub: *change_spend,
            view_pub: *change_view,
        });
    }

    let mut extra = Vec::new();
    add_amm_swap_auth_extra(&mut extra, 0, input_amount, heat_received, min_output);

    build_mixed_output_transaction(
        inputs,
        decoys,
        mixin,
        &commitment_dests,
        &key_dests,
        view_pub,
        fee,
        &extra,
        rng,
    )
}

/// Build and sign an AMM swap HEAT→XFG (direction 1): HEAT commitment
/// inputs in, XFG key output + HEAT change commitment out, 0xF6 auth.
#[allow(clippy::too_many_arguments)]
pub fn build_swap_heat_to_xfg_transaction(
    deposits: &[CommitmentDeposit],
    decoys: &[Vec<(u32, [u8; 32])>],
    ring_size: usize,
    input_amount: u64,
    xfg_received: u64,
    min_output: u64,
    xfg_dest: (&[u8; 32], &[u8; 32]),
    heat_change: u64,
    view_pub: &[u8; 32],
    fee: u64,
    rng: &mut impl RngCore,
) -> Result<BuiltTransaction> {
    let (spend_pub, view_pub_dest) = xfg_dest;
    let mut key_dests = Vec::new();
    let (chunks, dust) = decompose_change(xfg_received, DEFAULT_DUST_THRESHOLD);
    for chunk in chunks {
        key_dests.push(BuildDestination {
            amount: chunk,
            spend_pub: *spend_pub,
            view_pub: *view_pub_dest,
        });
    }
    if dust > 0 {
        key_dests.push(BuildDestination {
            amount: dust,
            spend_pub: *spend_pub,
            view_pub: *view_pub_dest,
        });
    }

    let mut commitment_dests = Vec::new();
    if heat_change > 0 {
        for bill in decompose_heat_into_bills(heat_change) {
            commitment_dests.push(BuildCommitmentDestination {
                amount: bill,
                term: HEAT_TERM,
                view_pub: None,
            });
        }
    }

    let mut extra = Vec::new();
    add_amm_swap_auth_extra(&mut extra, 1, input_amount, xfg_received, min_output);

    build_commitment_spend_transaction(
        deposits,
        decoys,
        ring_size,
        &key_dests,
        &commitment_dests,
        view_pub,
        fee,
        &extra,
        rng,
    )
}

/// Build and sign an LP add (Hearth liquidity deposit): XFG KeyInputs +
/// HEAT commitment inputs, outputs an LP commitment (DEPOSIT_TERM_LP) plus
/// XFG/HEAT change, 0xF7 auth declaring the deposited amounts and shares.
#[allow(clippy::too_many_arguments)]
pub fn build_lp_add_transaction(
    xfg_inputs: &[SpendableOutput],
    xfg_decoys: &[Vec<DecoyEntry>],
    heat_deposits: &[CommitmentDeposit],
    heat_decoys: &[Vec<(u32, [u8; 32])>],
    _mixin: usize,
    amount_xfg: u64,
    amount_heat: u64,
    lp_shares: u64,
    xfg_change: u64,
    heat_change: u64,
    view_pub: &[u8; 32],
    change_keys: (&[u8; 32], &[u8; 32]),
    fee: u64,
    rng: &mut impl RngCore,
) -> Result<BuiltTransaction> {
    if xfg_inputs.is_empty() && heat_deposits.is_empty() {
        return Err(SdkError::InsufficientFunds { need: fee, have: 0 });
    }
    if xfg_decoys.len() != xfg_inputs.len() {
        return Err(SdkError::Serialization(format!(
            "xfg decoys per input mismatch: {} inputs, {} decoy groups",
            xfg_inputs.len(),
            xfg_decoys.len()
        )));
    }
    if heat_decoys.len() != heat_deposits.len() {
        return Err(SdkError::Serialization(format!(
            "heat decoys per deposit mismatch: {} deposits, {} decoy groups",
            heat_deposits.len(),
            heat_decoys.len()
        )));
    }

    // Key input rings.
    let mut rings: Vec<Vec<(u32, [u8; 32])>> = Vec::with_capacity(xfg_inputs.len());
    let mut ring_indices: Vec<Vec<u32>> = Vec::with_capacity(xfg_inputs.len());
    for (i, input) in xfg_inputs.iter().enumerate() {
        let mut ring: Vec<(u32, [u8; 32])> = xfg_decoys[i]
            .iter()
            .map(|d| (d.global_index, d.out_key))
            .collect();
        ring.push((input.global_index, input.output_key));
        ring.sort_by_key(|(idx, _)| *idx);
        ring_indices.push(ring.iter().map(|(idx, _)| *idx).collect());
        rings.push(ring);
    }

    // Commitment input rings.
    let mut c_rings: Vec<Vec<(u32, [u8; 32])>> = Vec::with_capacity(heat_deposits.len());
    let mut c_ring_indices: Vec<Vec<u32>> = Vec::with_capacity(heat_deposits.len());
    for (i, deposit) in heat_deposits.iter().enumerate() {
        let mut ring: Vec<(u32, [u8; 32])> = heat_decoys[i].clone();
        ring.push((deposit.global_index, deposit.commit_key));
        ring.sort_by_key(|(idx, _)| *idx);
        c_ring_indices.push(ring.iter().map(|(idx, _)| *idx).collect());
        c_rings.push(ring);
    }

    // Wire inputs: key inputs first, then commitment spends.
    let mut wire_inputs: Vec<TxInput> = Vec::with_capacity(xfg_inputs.len() + heat_deposits.len());
    for (i, input) in xfg_inputs.iter().enumerate() {
        wire_inputs.push(TxInput::Key(KeyInput {
            amount: input.amount,
            offsets: ring_indices[i].clone(),
            key_image: input.key_image,
        }));
    }
    for (i, deposit) in heat_deposits.iter().enumerate() {
        wire_inputs.push(TxInput::CommitmentSpend(CommitmentSpendInput {
            amount: deposit.amount,
            offsets: c_ring_indices[i].clone(),
            key_image: deposit.key_image,
            claimed_interest: deposit.claimed_interest,
        }));
    }

    // Signers: key inputs then commitment spends.
    let mut signers: Vec<(Vec<[u8; 32]>, usize, [u8; 32], [u8; 32])> =
        Vec::with_capacity(xfg_inputs.len() + heat_deposits.len());
    for (i, input) in xfg_inputs.iter().enumerate() {
        let pubs: Vec<[u8; 32]> = rings[i].iter().map(|(_, k)| *k).collect();
        let sec_index = rings[i]
            .iter()
            .position(|(idx, _)| *idx == input.global_index)
            .ok_or_else(|| SdkError::Crypto("real output index not found in ring".into()))?;
        signers.push((pubs, sec_index, input.key_image, input.secret_key));
    }
    for (i, deposit) in heat_deposits.iter().enumerate() {
        let pubs: Vec<[u8; 32]> = c_rings[i].iter().map(|(_, k)| *k).collect();
        let sec_index = c_rings[i]
            .iter()
            .position(|(idx, _)| *idx == deposit.global_index)
            .ok_or_else(|| SdkError::Crypto("real commitment index not found in ring".into()))?;
        signers.push((pubs, sec_index, deposit.key_image, deposit.key_scalar));
    }

    // Outputs: LP commitment first, then HEAT change commitment, then key change.
    let commitment_dests = vec![BuildCommitmentDestination {
        amount: lp_shares,
        term: crate::serialization::DEPOSIT_TERM_LP,
        view_pub: None,
    }];
    let mut commitment_dests = commitment_dests;
    if heat_change > 0 {
        for bill in decompose_heat_into_bills(heat_change) {
            commitment_dests.push(BuildCommitmentDestination {
                amount: bill,
                term: HEAT_TERM,
                view_pub: None,
            });
        }
    }

    let (change_spend, change_view) = change_keys;
    let (change_chunks, dust) = decompose_change(xfg_change, DEFAULT_DUST_THRESHOLD);
    let mut key_dests: Vec<BuildDestination> = Vec::with_capacity(change_chunks.len() + 1);
    for chunk in change_chunks {
        key_dests.push(BuildDestination {
            amount: chunk,
            spend_pub: *change_spend,
            view_pub: *change_view,
        });
    }
    if dust > 0 {
        key_dests.push(BuildDestination {
            amount: dust,
            spend_pub: *change_spend,
            view_pub: *change_view,
        });
    }

    let mut extra = Vec::new();
    add_lp_add_auth_extra(&mut extra, amount_xfg, amount_heat, lp_shares);

    assemble_outputs_and_sign(
        &wire_inputs,
        &signers,
        &commitment_dests,
        &key_dests,
        &[],
        view_pub,
        &extra,
        rng,
    )
}

/// Build and sign an LP remove: LP commitment inputs burned, outputs XFG
/// key change + HEAT commitments, 0xF8 auth declaring shares and minimums.
#[allow(clippy::too_many_arguments)]
pub fn build_lp_remove_transaction(
    deposits: &[CommitmentDeposit],
    decoys: &[Vec<(u32, [u8; 32])>],
    ring_size: usize,
    lp_shares_burned: u64,
    min_xfg: u64,
    min_heat: u64,
    xfg_out: u64,
    heat_out: u64,
    view_pub: &[u8; 32],
    change_keys: (&[u8; 32], &[u8; 32]),
    fee: u64,
    rng: &mut impl RngCore,
) -> Result<BuiltTransaction> {
    let (spend_pub, view_pub_dest) = change_keys;
    let (chunks, dust) = decompose_change(xfg_out, DEFAULT_DUST_THRESHOLD);
    let mut key_dests: Vec<BuildDestination> = Vec::with_capacity(chunks.len() + 1);
    for chunk in chunks {
        key_dests.push(BuildDestination {
            amount: chunk,
            spend_pub: *spend_pub,
            view_pub: *view_pub_dest,
        });
    }
    if dust > 0 {
        key_dests.push(BuildDestination {
            amount: dust,
            spend_pub: *spend_pub,
            view_pub: *view_pub_dest,
        });
    }

    let mut commitment_dests = Vec::new();
    for bill in decompose_heat_into_bills(heat_out) {
        commitment_dests.push(BuildCommitmentDestination {
            amount: bill,
            term: HEAT_TERM,
            view_pub: None,
        });
    }

    let mut extra = Vec::new();
    add_lp_remove_auth_extra(&mut extra, lp_shares_burned, min_xfg, min_heat);

    build_commitment_spend_transaction(
        deposits,
        decoys,
        ring_size,
        &key_dests,
        &commitment_dests,
        view_pub,
        fee,
        &extra,
        rng,
    )
}

/// Build and sign a limit-order deposit (place_order): XFG KeyInputs in,
/// one pool-commitment output (pool commit key, POOL term) + XFG change,
/// 0xFB limit-deposit extra with orderId/addressHash.
#[allow(clippy::too_many_arguments)]
pub fn build_place_order_transaction(
    inputs: &[SpendableOutput],
    decoys: &[Vec<DecoyEntry>],
    _mixin: usize,
    side: u8,
    amount: u64,
    target_price: u64,
    expiration: u32,
    order_id: &[u8; 32],
    address_hash: &[u8; 32],
    pool_key: &[u8; 32],
    change_keys: (&[u8; 32], &[u8; 32]),
    view_pub: &[u8; 32],
    fee: u64,
    rng: &mut impl RngCore,
) -> Result<BuiltTransaction> {
    let found: u64 = inputs.iter().map(|u| u.amount).sum();
    let change = found - amount - fee;

    let (change_spend, change_view) = change_keys;
    let (change_chunks, dust) = decompose_change(change, DEFAULT_DUST_THRESHOLD);
    let mut key_dests: Vec<BuildDestination> = Vec::with_capacity(change_chunks.len() + 1);
    for chunk in change_chunks {
        key_dests.push(BuildDestination {
            amount: chunk,
            spend_pub: *change_spend,
            view_pub: *change_view,
        });
    }
    if dust > 0 {
        key_dests.push(BuildDestination {
            amount: dust,
            spend_pub: *change_spend,
            view_pub: *change_view,
        });
    }

    // side 1 (SELL XFG) deposits XFG into the pool; side 0 (BUY XFG)
    // deposits HEAT.
    let pool_term = if side == 1 {
        crate::serialization::DEPOSIT_TERM_POOL_XFG
    } else {
        crate::serialization::DEPOSIT_TERM_POOL_HEAT
    };
    let pool_dests = vec![BuildPoolCommitmentDestination {
        amount,
        commit_key: *pool_key,
        term: pool_term,
    }];

    let mut extra = Vec::new();
    add_limit_deposit_extra(
        &mut extra,
        side,
        amount,
        target_price,
        expiration,
        order_id,
        address_hash,
    );

    // Assemble rings like build_mixed_output_transaction (key inputs only).
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

    let wire_inputs: Vec<TxInput> = inputs
        .iter()
        .enumerate()
        .map(|(i, input)| {
            TxInput::Key(KeyInput {
                amount: input.amount,
                offsets: ring_indices[i].clone(),
                key_image: input.key_image,
            })
        })
        .collect();

    let mut signers: Vec<(Vec<[u8; 32]>, usize, [u8; 32], [u8; 32])> =
        Vec::with_capacity(inputs.len());
    for (i, input) in inputs.iter().enumerate() {
        let pubs: Vec<[u8; 32]> = rings[i].iter().map(|(_, k)| *k).collect();
        let sec_index = rings[i]
            .iter()
            .position(|(idx, _)| *idx == input.global_index)
            .ok_or_else(|| SdkError::Crypto("real output index not found in ring".into()))?;
        signers.push((pubs, sec_index, input.key_image, input.secret_key));
    }

    assemble_outputs_and_sign(
        &wire_inputs,
        &signers,
        &[],
        &key_dests,
        &pool_dests,
        view_pub,
        &extra,
        rng,
    )
}
