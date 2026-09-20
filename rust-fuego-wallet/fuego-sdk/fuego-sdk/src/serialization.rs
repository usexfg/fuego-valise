//! CryptoNote wire serialization, byte-compatible with
//! `src/CryptoNoteCore/CryptoNoteSerialization.cpp` + `src/Common/Varint.h`
//! and `src/Serialization/BinaryOutputStreamSerializer.cpp` in the daemon.
//! Verified by golden vectors generated from the C++ production serializer.

use std::collections::BTreeMap;
use std::fmt;

use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SerializationError(pub String);

impl fmt::Display for SerializationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "serialization error: {}", self.0)
    }
}

impl std::error::Error for SerializationError {}

// ---------------------------------------------------------------- varints

/// LEB128, CryptoNote style (Common/Varint.h write_varint).
pub fn write_varint(mut value: u64, out: &mut Vec<u8>) {
    while value >= 0x80 {
        out.push(((value & 0x7F) | 0x80) as u8);
        value >>= 7;
    }
    out.push(value as u8);
}

pub fn varint_len(value: u64) -> usize {
    let mut n = 1;
    let mut v = value;
    while v >= 0x80 {
        n += 1;
        v >>= 7;
    }
    n
}

/// Read a canonical LEB128 varint from `data` at `pos`.
pub fn read_varint(data: &[u8], pos: &mut usize) -> Result<u64, SerializationError> {
    let mut result: u64 = 0;
    let mut shift = 0u32;
    loop {
        if *pos >= data.len() {
            return Err(SerializationError("varint: unexpected end of data".into()));
        }
        let byte = data[*pos];
        *pos += 1;
        if shift >= 64 {
            return Err(SerializationError("varint: too long".into()));
        }
        result |= ((byte & 0x7F) as u64) << shift;
        if byte & 0x80 == 0 {
            return Ok(result);
        }
        shift += 7;
    }
}

// ---------------------------------------------------------------- tx types

pub const TX_INPUT_TAG_KEY: u8 = 0x02;
pub const TX_INPUT_TAG_COMMITMENT_SPEND: u8 = 0x04;
pub const TX_OUTPUT_TAG_KEY: u8 = 0x02;
pub const TX_OUTPUT_TAG_COMMITMENT: u8 = 0x04;
pub const TX_EXTRA_TAG_PADDING: u8 = 0x00;
pub const TX_EXTRA_TAG_PUBKEY: u8 = 0x01;
pub const TX_EXTRA_TAG_NONCE: u8 = 0x02;
pub const TX_EXTRA_HEAT_MINT_AUTH: u8 = 0xF5;
pub const TX_EXTRA_AMM_SWAP_AUTH: u8 = 0xF6;
pub const TX_EXTRA_AMM_LP_ADD_AUTH: u8 = 0xF7;
pub const TX_EXTRA_AMM_LP_REM_AUTH: u8 = 0xF8;
pub const TX_EXTRA_HEAT_SEND_AUTH: u8 = 0xF9;
pub const TX_EXTRA_LIMIT_DEPOSIT: u8 = 0xFB;
pub const TX_EXTRA_TREASURY_FUND: u8 = 0xFF;

pub const TX_VERSION_1: u8 = 1;
pub const TX_VERSION_2: u8 = 2;

/// HEAT_TERM (CryptoNoteConfig.h): outputs with this term are HEAT.
pub const HEAT_TERM: u32 = 0xFFFF_FFFF;

/// DEPOSIT_TERM_LP (CryptoNoteConfig.h): LP share marker term for Hearth
/// liquidity positions.
pub const DEPOSIT_TERM_LP: u32 = 0xFFFF_FFFD;

/// DEPOSIT_TERM_POOL_XFG (CryptoNoteConfig.h): 'POLX' — pool receives XFG.
pub const DEPOSIT_TERM_POOL_XFG: u32 = 0x504F_4C58;

/// DEPOSIT_TERM_POOL_HEAT (CryptoNoteConfig.h): 'POLH' — pool receives HEAT.
pub const DEPOSIT_TERM_POOL_HEAT: u32 = 0x504F_4C48;

/// MembershipProof size: FUEGO_MEMBERSHIP_N(4) * 2 scalars * 32 bytes.
pub const AMOUNT_PROOF_LEN: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyInput {
    pub amount: u64,
    /// Absolute global output indices of EVERY ring member, sorted ascending;
    /// serialized as cumulative-difference varints.
    pub offsets: Vec<u32>,
    pub key_image: [u8; 32],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitmentSpendInput {
    pub amount: u64,
    /// Absolute global commitment output indices of every ring member,
    /// sorted ascending.
    pub offsets: Vec<u32>,
    pub key_image: [u8; 32],
    pub claimed_interest: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TxInput {
    Key(KeyInput),
    CommitmentSpend(CommitmentSpendInput),
}

impl TxInput {
    pub fn amount(&self) -> u64 {
        match self {
            TxInput::Key(k) => k.amount,
            TxInput::CommitmentSpend(c) => c.amount,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitmentOutputTarget {
    pub commit_key: [u8; 32],
    pub term: u32,
    /// Pedersen C = amount*H + mask*G. The current wallet scheme leaves this
    /// zero (the daemon does not validate it); zero-filled deterministically.
    pub amount_commitment: [u8; 32],
    /// MembershipProof pod (256 bytes), zero-filled by the wallet.
    pub amount_proof: [u8; AMOUNT_PROOF_LEN],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OutputTarget {
    Key([u8; 32]),
    Commitment(CommitmentOutputTarget),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TxOutput {
    pub amount: u64,
    pub target: OutputTarget,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransactionPrefix {
    pub version: u8,
    pub unlock_time: u64,
    pub inputs: Vec<TxInput>,
    pub outputs: Vec<TxOutput>,
    pub extra: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transaction {
    pub prefix: TransactionPrefix,
    /// One 64-byte signature (c || r) per ring member, in ring order, per
    /// input. Serialized raw without a count prefix; the count is implied by
    /// each input's offsets length.
    pub signatures: Vec<Vec<[u8; 64]>>,
}

fn write_u32_varint(v: u32, out: &mut Vec<u8>) {
    write_varint(v as u64, out)
}

fn read_u32_varint(data: &[u8], pos: &mut usize) -> Result<u32, SerializationError> {
    let v = read_varint(data, pos)?;
    if v > u32::MAX as u64 {
        return Err(SerializationError("varint: u32 overflow".into()));
    }
    Ok(v as u32)
}

/// Absolute → relative (cumulative difference) offset conversion, matching
/// CryptoNoteFormatUtils.cpp absolute_output_offsets_to_relative. Inputs must
/// be sorted ascending.
pub fn absolute_offsets_to_relative(abs: &[u32]) -> Vec<u32> {
    let mut rel = Vec::with_capacity(abs.len());
    for (i, &v) in abs.iter().enumerate() {
        if i == 0 {
            rel.push(v);
        } else {
            rel.push(v - abs[i - 1]);
        }
    }
    rel
}

/// Relative → absolute, matching relative_output_offsets_to_absolute.
pub fn relative_offsets_to_absolute(rel: &[u32]) -> Result<Vec<u32>, SerializationError> {
    let mut abs = Vec::with_capacity(rel.len());
    let mut acc: u32 = 0;
    for &v in rel {
        acc = acc
            .checked_add(v)
            .ok_or_else(|| SerializationError("offsets: overflow".into()))?;
        abs.push(acc);
    }
    Ok(abs)
}

/// Serialize the transaction prefix exactly as the daemon's
/// BinaryOutputStreamSerializer does.
pub fn serialize_prefix(prefix: &TransactionPrefix) -> Vec<u8> {
    let mut out = Vec::new();
    write_varint(prefix.version as u64, &mut out);
    write_varint(prefix.unlock_time, &mut out);
    serialize_inputs_into(&prefix.inputs, &mut out);
    serialize_outputs_into(&prefix.outputs, &mut out);
    write_varint(prefix.extra.len() as u64, &mut out);
    out.extend_from_slice(&prefix.extra);
    out
}

/// Serialize just the inputs vector (count + entries), as it appears inside
/// the prefix. Used for the deterministic tx key
/// (generateDeterministicTransactionKeys hashes getObjectHash(tx.inputs)).
pub fn serialize_inputs(inputs: &[TxInput]) -> Vec<u8> {
    let mut out = Vec::new();
    serialize_inputs_into(inputs, &mut out);
    out
}

fn serialize_inputs_into(inputs: &[TxInput], out: &mut Vec<u8>) {
    write_varint(inputs.len() as u64, out);
    for input in inputs {
        match input {
            TxInput::Key(k) => {
                out.push(TX_INPUT_TAG_KEY);
                write_varint(k.amount, out);
                let rel = absolute_offsets_to_relative(&k.offsets);
                write_varint(rel.len() as u64, out);
                for o in rel {
                    write_u32_varint(o, out);
                }
                out.extend_from_slice(&k.key_image);
            }
            TxInput::CommitmentSpend(c) => {
                out.push(TX_INPUT_TAG_COMMITMENT_SPEND);
                write_varint(c.amount, out);
                let rel = absolute_offsets_to_relative(&c.offsets);
                write_varint(rel.len() as u64, out);
                for o in rel {
                    write_u32_varint(o, out);
                }
                out.extend_from_slice(&c.key_image);
                write_varint(c.claimed_interest, out);
            }
        }
    }
}

fn serialize_outputs_into(outputs: &[TxOutput], out: &mut Vec<u8>) {
    write_varint(outputs.len() as u64, out);
    for output in outputs {
        write_varint(output.amount, out);
        match &output.target {
            OutputTarget::Key(key) => {
                out.push(TX_OUTPUT_TAG_KEY);
                out.extend_from_slice(key);
            }
            OutputTarget::Commitment(c) => {
                out.push(TX_OUTPUT_TAG_COMMITMENT);
                out.extend_from_slice(&c.commit_key);
                write_varint(c.term as u64, out);
                out.extend_from_slice(&c.amount_commitment);
                out.extend_from_slice(&c.amount_proof);
            }
        }
    }
}

/// Serialize the full transaction (prefix + raw signatures).
pub fn serialize_tx(tx: &Transaction) -> Vec<u8> {
    let mut out = serialize_prefix(&tx.prefix);
    for sigs in &tx.signatures {
        for sig in sigs {
            out.extend_from_slice(sig);
        }
    }
    out
}

/// `getObjectHash(TransactionPrefix)`: keccak over the serialized prefix.
pub fn tx_prefix_hash(prefix: &TransactionPrefix) -> [u8; 32] {
    let bytes = serialize_prefix(prefix);
    fuego_crypto::cn_fast_hash(&bytes)
}

fn read_bytes<'a>(data: &'a [u8], pos: &mut usize, n: usize) -> Result<&'a [u8], SerializationError> {
    if *pos + n > data.len() {
        return Err(SerializationError("unexpected end of data".into()));
    }
    let slice = &data[*pos..*pos + n];
    *pos += n;
    Ok(slice)
}

fn read_key(data: &[u8], pos: &mut usize) -> Result<[u8; 32], SerializationError> {
    let slice = read_bytes(data, pos, 32)?;
    let mut k = [0u8; 32];
    k.copy_from_slice(slice);
    Ok(k)
}

fn read_input_at(data: &[u8], pos: &mut usize) -> Result<TxInput, SerializationError> {
    let tag = read_bytes(data, pos, 1)?[0];
    match tag {
        TX_INPUT_TAG_KEY => {
            let amount = read_varint(data, pos)?;
            let offs_count = read_varint(data, pos)?;
            let mut rel = Vec::with_capacity(offs_count as usize);
            for _ in 0..offs_count {
                rel.push(read_u32_varint(data, pos)?);
            }
            let key_image = read_key(data, pos)?;
            Ok(TxInput::Key(KeyInput {
                amount,
                offsets: relative_offsets_to_absolute(&rel)?,
                key_image,
            }))
        }
        TX_INPUT_TAG_COMMITMENT_SPEND => {
            let amount = read_varint(data, pos)?;
            let offs_count = read_varint(data, pos)?;
            let mut rel = Vec::with_capacity(offs_count as usize);
            for _ in 0..offs_count {
                rel.push(read_u32_varint(data, pos)?);
            }
            let key_image = read_key(data, pos)?;
            let claimed_interest = read_varint(data, pos)?;
            Ok(TxInput::CommitmentSpend(CommitmentSpendInput {
                amount,
                offsets: relative_offsets_to_absolute(&rel)?,
                key_image,
                claimed_interest,
            }))
        }
        other => Err(SerializationError(format!(
            "unsupported input tag 0x{:02x}",
            other
        ))),
    }
}

fn read_output_at(data: &[u8], pos: &mut usize) -> Result<TxOutput, SerializationError> {
    let amount = read_varint(data, pos)?;
    let tag = read_bytes(data, pos, 1)?[0];
    match tag {
        TX_OUTPUT_TAG_KEY => Ok(TxOutput {
            amount,
            target: OutputTarget::Key(read_key(data, pos)?),
        }),
        TX_OUTPUT_TAG_COMMITMENT => {
            let commit_key = read_key(data, pos)?;
            let term = read_u32_varint(data, pos)?;
            let mut amount_commitment = [0u8; 32];
            amount_commitment.copy_from_slice(read_bytes(data, pos, 32)?);
            let mut amount_proof = [0u8; AMOUNT_PROOF_LEN];
            amount_proof.copy_from_slice(read_bytes(data, pos, AMOUNT_PROOF_LEN)?);
            Ok(TxOutput {
                amount,
                target: OutputTarget::Commitment(CommitmentOutputTarget {
                    commit_key,
                    term,
                    amount_commitment,
                    amount_proof,
                }),
            })
        }
        other => Err(SerializationError(format!(
            "unsupported output tag 0x{:02x}",
            other
        ))),
    }
}

/// Parse a transaction prefix from its serialized form. Only Key /
/// CommitmentSpend inputs and Key / Commitment outputs are accepted (the
/// chain carries no other types today); an unknown tag is an error.
pub fn parse_prefix(data: &[u8]) -> Result<TransactionPrefix, SerializationError> {
    let mut pos = 0usize;
    let prefix = parse_prefix_at(data, &mut pos)?;
    if pos != data.len() {
        return Err(SerializationError(format!(
            "prefix parse: {} trailing bytes",
            data.len() - pos
        )));
    }
    Ok(prefix)
}

/// Parse a prefix starting at `pos`, advancing it past the consumed bytes
/// (used when the prefix is embedded in a larger structure, e.g.
/// TransactionPrefixInfo in /queryblockslite.bin).
pub fn parse_prefix_at(
    data: &[u8],
    pos: &mut usize,
) -> Result<TransactionPrefix, SerializationError> {
    let version = read_varint(data, pos)? as u8;
    let unlock_time = read_varint(data, pos)?;

    let inputs_count = read_varint(data, pos)?;
    let mut inputs = Vec::with_capacity(inputs_count as usize);
    for _ in 0..inputs_count {
        inputs.push(read_input_at(data, pos)?);
    }

    let outputs_count = read_varint(data, pos)?;
    let mut outputs = Vec::with_capacity(outputs_count as usize);
    for _ in 0..outputs_count {
        outputs.push(read_output_at(data, pos)?);
    }

    let extra_len = read_varint(data, pos)?;
    let extra = read_bytes(data, pos, extra_len as usize)?.to_vec();

    Ok(TransactionPrefix {
        version,
        unlock_time,
        inputs,
        outputs,
        extra,
    })
}

// ---------------------------------------------------------------- tx extra

/// Parse the tx public key (tag 0x01) out of the extra blob.
pub fn parse_extra_pubkey(extra: &[u8]) -> Option<[u8; 32]> {
    let mut pos = 0usize;
    while pos < extra.len() {
        let tag = match read_varint(extra, &mut pos) {
            Ok(t) => t as u8,
            Err(_) => return None,
        };
        match tag {
            TX_EXTRA_TAG_PADDING => {}
            TX_EXTRA_TAG_PUBKEY => {
                if pos + 32 > extra.len() {
                    return None;
                }
                let mut k = [0u8; 32];
                k.copy_from_slice(&extra[pos..pos + 32]);
                return Some(k);
            }
            TX_EXTRA_TAG_NONCE => {
                if pos >= extra.len() {
                    return None;
                }
                let len = extra[pos] as usize;
                pos += 1;
                if pos + len > extra.len() {
                    return None;
                }
                pos += len;
            }
            _ => {
                // Unknown tag: cannot determine its length; stop parsing.
                return None;
            }
        }
    }
    None
}

/// Build a standard extra: 0x01 || R (32 bytes). Matches
/// addTransactionPublicKeyToExtra.
pub fn build_extra_with_pubkey(r: &[u8; 32]) -> Vec<u8> {
    let mut extra = Vec::with_capacity(33);
    extra.push(TX_EXTRA_TAG_PUBKEY);
    extra.extend_from_slice(r);
    extra
}

/// TransactionExtra.cpp addHeatMintAuthToExtra: 0xF5 || xfgBurned u64 LE ||
/// heatMinted u64 LE || priceHeight u32 LE.
///
/// `price_height` is the height whose mint price `heat_minted` was computed
/// from. Consensus validates the amount against the price it recorded at
/// that height rather than the price at inclusion, so the two agree exactly
/// and there is no tolerance band on either side.
pub fn add_heat_mint_auth_extra(
    extra: &mut Vec<u8>,
    xfg_burned: u64,
    heat_minted: u64,
    price_height: u32,
) {
    extra.push(TX_EXTRA_HEAT_MINT_AUTH);
    extra.extend_from_slice(&xfg_burned.to_le_bytes());
    extra.extend_from_slice(&heat_minted.to_le_bytes());
    extra.extend_from_slice(&price_height.to_le_bytes());
}

/// TransactionExtra.cpp addHeatSendAuthToExtra: 0xF9 || heatAmount u64 LE.
pub fn add_heat_send_auth_extra(extra: &mut Vec<u8>, heat_amount: u64) {
    extra.push(TX_EXTRA_HEAT_SEND_AUTH);
    extra.extend_from_slice(&heat_amount.to_le_bytes());
}

/// TransactionExtra.cpp addTreasuryFundToExtra: 0xFF || asset u8 || amount
/// u64 LE (asset: 0 = XFG, 1 = HEAT).
pub fn add_treasury_fund_extra(extra: &mut Vec<u8>, asset: u8, amount: u64) {
    extra.push(TX_EXTRA_TREASURY_FUND);
    extra.push(asset);
    extra.extend_from_slice(&amount.to_le_bytes());
}

/// TransactionExtra.cpp addAmmSwapAuthToExtra: 0xF6 || direction u8 ||
/// inputAmount u64 LE || outputAmount u64 LE || minOutput u64 LE.
pub fn add_amm_swap_auth_extra(
    extra: &mut Vec<u8>,
    direction: u8,
    input_amount: u64,
    output_amount: u64,
    min_output: u64,
) {
    extra.push(TX_EXTRA_AMM_SWAP_AUTH);
    extra.push(direction);
    extra.extend_from_slice(&input_amount.to_le_bytes());
    extra.extend_from_slice(&output_amount.to_le_bytes());
    extra.extend_from_slice(&min_output.to_le_bytes());
}

/// TransactionExtra.cpp addLpAddAuthToExtra: 0xF7 || amountXfg u64 LE ||
/// amountHeat u64 LE || lpShares u64 LE.
pub fn add_lp_add_auth_extra(
    extra: &mut Vec<u8>,
    amount_xfg: u64,
    amount_heat: u64,
    lp_shares: u64,
) {
    extra.push(TX_EXTRA_AMM_LP_ADD_AUTH);
    extra.extend_from_slice(&amount_xfg.to_le_bytes());
    extra.extend_from_slice(&amount_heat.to_le_bytes());
    extra.extend_from_slice(&lp_shares.to_le_bytes());
}

/// TransactionExtra.cpp addLpRemoveAuthToExtra: 0xF8 || lpSharesBurned u64
/// LE || minXfg u64 LE || minHeat u64 LE.
pub fn add_lp_remove_auth_extra(
    extra: &mut Vec<u8>,
    lp_shares_burned: u64,
    min_xfg: u64,
    min_heat: u64,
) {
    extra.push(TX_EXTRA_AMM_LP_REM_AUTH);
    extra.extend_from_slice(&lp_shares_burned.to_le_bytes());
    extra.extend_from_slice(&min_xfg.to_le_bytes());
    extra.extend_from_slice(&min_heat.to_le_bytes());
}

/// TransactionExtra.cpp addLimitDepositToExtra: 0xFB || side u8 ||
/// amount varint || targetPrice varint || expiration varint ||
/// orderId (32 bytes) || addressHash (32 bytes).
/// The consensus parser reads amount/price/expiration as base-128 varints.
pub fn add_limit_deposit_extra(
    extra: &mut Vec<u8>,
    side: u8,
    amount: u64,
    target_price: u64,
    expiration: u32,
    order_id: &[u8; 32],
    address_hash: &[u8; 32],
) {
    extra.push(TX_EXTRA_LIMIT_DEPOSIT);
    extra.push(side);
    write_varint(amount, extra);
    write_varint(target_price, extra);
    write_varint(expiration as u64, extra);
    extra.extend_from_slice(order_id);
    extra.extend_from_slice(address_hash);
}

// ---------------------------------------------------------------- daemon RPC

/// KVBinary document header: signature pair, version 1, root entry count.
fn kv_document_header(root_entries: usize, out: &mut Vec<u8>) {
    out.extend_from_slice(&KV_SIGNATURE_A.to_le_bytes());
    out.extend_from_slice(&KV_SIGNATURE_B.to_le_bytes());
    out.push(1);
    write_portable_size(root_entries, out);
}

/// COMMAND_RPC_GET_RANDOM_OUTPUTS_FOR_AMOUNTS request (KV binary):
/// amounts = array<uint64>, outs_count = uint64.
pub fn get_random_outs_request(amounts: &[u64], outs_count: u64) -> Vec<u8> {
    let mut out = Vec::new();
    kv_document_header(2, &mut out);

    write_kv_name(b"amounts", &mut out);
    out.push(0x80 | 5); // array of uint64
    write_portable_size(amounts.len(), &mut out);
    for a in amounts {
        out.extend_from_slice(&a.to_le_bytes());
    }

    write_kv_name(b"outs_count", &mut out);
    out.push(5);
    out.extend_from_slice(&outs_count.to_le_bytes());
    out
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RandomOutEntry {
    pub global_amount_index: u64,
    pub out_key: [u8; 32],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RandomOutsForAmount {
    pub amount: u64,
    pub outs: Vec<RandomOutEntry>,
}

/// Parse the binary response of /getrandom_outs.bin:
/// outs = array of {amount u64, outs blob}, status string. The per-amount
/// blob is serializeAsBinary-packed POD records: N*(u64 index + 32 key),
/// 40 bytes each, no element count.
pub fn parse_get_random_outs_response(
    data: &[u8],
) -> Result<Vec<RandomOutsForAmount>, SerializationError> {
    let root = parse_kv_document(data)?;
    let status = String::from_utf8_lossy(&kv_bytes(&root, &["status"])?).to_string();
    if status != "OK" {
        return Err(SerializationError(format!("getrandom_outs status: {status}")));
    }
    let groups = kv_array(&root, &["outs"])?;
    let mut result = Vec::with_capacity(groups.len());
    for group in groups {
        let obj = group
            .as_object()
            .ok_or_else(|| SerializationError("outs_for_amount is not an object".into()))?;
        let amount = kv_u64(obj, &["amount"])?;
        let blob = kv_bytes(obj, &["outs"])?;
        if blob.len() % 40 != 0 {
            return Err(SerializationError(format!(
                "getrandom_outs blob size {} not a multiple of 40",
                blob.len()
            )));
        }
        let count = blob.len() / 40;
        let mut outs = Vec::with_capacity(count);
        for i in 0..count {
            let entry = &blob[i * 40..(i + 1) * 40];
            let mut idx = [0u8; 8];
            idx.copy_from_slice(&entry[..8]);
            let mut key = [0u8; 32];
            key.copy_from_slice(&entry[8..]);
            outs.push(RandomOutEntry {
                global_amount_index: u64::from_le_bytes(idx),
                out_key: key,
            });
        }
        result.push(RandomOutsForAmount { amount, outs });
    }
    Ok(result)
}

/// COMMAND_RPC_GET_RANDOM_COMMITMENT_OUTPUTS request (KV binary):
/// amount uint64, outs_count uint64, max_height uint32.
pub fn get_random_commitment_outs_request(
    amount: u64,
    outs_count: u64,
    max_height: u32,
) -> Vec<u8> {
    let mut out = Vec::new();
    kv_document_header(3, &mut out);

    write_kv_name(b"amount", &mut out);
    out.push(5);
    out.extend_from_slice(&amount.to_le_bytes());

    write_kv_name(b"outs_count", &mut out);
    out.push(5);
    out.extend_from_slice(&outs_count.to_le_bytes());

    write_kv_name(b"max_height", &mut out);
    out.push(6);
    out.extend_from_slice(&max_height.to_le_bytes());
    out
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RandomCommitmentOutEntry {
    pub global_amount_index: u32,
    pub commit_key: [u8; 32],
}

/// Parse the binary response of /getrandom_commitment_outs.bin:
/// outs blob of POD records (u32 LE index + 32B commit key, 36 bytes each,
/// no element count), status string.
pub fn parse_get_random_commitment_outs_response(
    data: &[u8],
) -> Result<Vec<RandomCommitmentOutEntry>, SerializationError> {
    let root = parse_kv_document(data)?;
    let status = String::from_utf8_lossy(&kv_bytes(&root, &["status"])?).to_string();
    if status != "OK" {
        return Err(SerializationError(format!(
            "getrandom_commitment_outs status: {status}"
        )));
    }
    let blob = kv_bytes(&root, &["outs"])?;
    if blob.len() % 36 != 0 {
        return Err(SerializationError(format!(
            "commitment outs blob size {} not a multiple of 36",
            blob.len()
        )));
    }
    let count = blob.len() / 36;
    let mut outs = Vec::with_capacity(count);
    for i in 0..count {
        let entry = &blob[i * 36..(i + 1) * 36];
        let mut idx = [0u8; 4];
        idx.copy_from_slice(&entry[..4]);
        let mut key = [0u8; 32];
        key.copy_from_slice(&entry[4..]);
        outs.push(RandomCommitmentOutEntry {
            global_amount_index: u32::from_le_bytes(idx),
            commit_key: key,
        });
    }
    Ok(outs)
}

/// COMMAND_RPC_QUERY_BLOCKS_LITE request (KV binary).
pub fn query_blocks_lite_request(block_ids: &[[u8; 32]], timestamp: u64) -> Vec<u8> {
    let mut out = Vec::new();
    kv_document_header(2, &mut out);

    // Fuego's serializeAsBinary for POD vectors is a raw memcpy into a
    // STRING field — no inner element count (SerializationOverloads.h).
    let mut blob = Vec::with_capacity(block_ids.len() * 32);
    for id in block_ids {
        blob.extend_from_slice(id);
    }

    write_kv_name(b"block_ids", &mut out);
    out.push(10); // BIN_KV_SERIALIZE_TYPE_STRING
    write_portable_size(blob.len(), &mut out);
    out.extend_from_slice(&blob);

    write_kv_name(b"timestamp", &mut out);
    out.push(5); // BIN_KV_SERIALIZE_TYPE_UINT64
    out.extend_from_slice(&timestamp.to_le_bytes());
    out
}

/// COMMAND_RPC_GET_TX_GLOBAL_OUTPUTS_INDEXES request (KV binary):
/// txid = 32-byte hash stored as a STRING field.
pub fn get_o_indexes_request(tx_hash: &[u8; 32]) -> Vec<u8> {
    let mut out = Vec::new();
    kv_document_header(1, &mut out);

    write_kv_name(b"txid", &mut out);
    out.push(10); // BIN_KV_SERIALIZE_TYPE_STRING
    write_portable_size(tx_hash.len(), &mut out);
    out.extend_from_slice(tx_hash);
    out
}

/// COMMAND_RPC_GET_TX_GLOBAL_OUTPUTS_INDEXES response (KV binary):
/// o_indexes = array<uint64>, status = string.
pub fn parse_get_o_indexes_response(
    data: &[u8],
) -> Result<Vec<u64>, SerializationError> {
    let root = parse_kv_document(data)?;
    let status = String::from_utf8_lossy(&kv_bytes(&root, &["status"])?).to_string();
    if status != "OK" {
        return Err(SerializationError(format!("o_indexes status: {status}")));
    }
    kv_array(&root, &["o_indexes"])?
        .iter()
        .map(|value| match value {
            KvValue::Unsigned(v) => Ok(*v),
            KvValue::Signed(v) if *v >= 0 => u64::try_from(*v as u64)
                .map_err(|_| SerializationError("o_index overflow".into())),
            _ => Err(SerializationError("invalid o_index".into())),
        })
        .collect()
}

fn write_kv_name(name: &[u8], out: &mut Vec<u8>) {
    out.push(name.len() as u8);
    out.extend_from_slice(name);
}

fn write_portable_size(value: usize, out: &mut Vec<u8>) {
    if value <= 63 {
        out.push((value as u8) << 2);
    } else if value <= 16_383 {
        out.extend_from_slice(&(((value as u16) << 2) | 1).to_le_bytes());
    } else if value <= 1_073_741_823 {
        out.extend_from_slice(&(((value as u32) << 2) | 2).to_le_bytes());
    } else {
        out.extend_from_slice(&(((value as u64) << 2) | 3).to_le_bytes());
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TxPrefixInfo {
    pub tx_hash: [u8; 32],
    /// Serialized TransactionPrefix blob.
    pub tx_prefix: Vec<u8>,
    /// Parsed prefix (populated by parse_query_blocks_lite_response).
    pub parsed: TransactionPrefix,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlockShortInfo {
    pub block_id: [u8; 32],
    /// Serialized full block (unparsed; only txPrefixes are needed for
    /// wallet scanning).
    pub block: Vec<u8>,
    pub tx_prefixes: Vec<TxPrefixInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueryBlocksLiteResponse {
    pub status: String,
    pub start_height: u64,
    pub current_height: u64,
    pub full_offset: u64,
    pub items: Vec<BlockShortInfo>,
}

/// Parse the binary response of /queryblockslite.bin.
pub fn parse_query_blocks_lite_response(
    data: &[u8],
) -> Result<QueryBlocksLiteResponse, SerializationError> {
    parse_kv_query_blocks_lite_response(data)
}

#[derive(Debug)]
enum KvValue {
    Signed(i64),
    Unsigned(u64),
    Float(f64),
    Bytes(Vec<u8>),
    Bool(bool),
    Object(BTreeMap<String, KvValue>),
    Array(Vec<KvValue>),
}

const KV_SIGNATURE_A: u32 = 0x0101_1101;
const KV_SIGNATURE_B: u32 = 0x0102_0101;

fn read_kv_portable_size(data: &[u8], pos: &mut usize) -> Result<usize, SerializationError> {
    let first = *data
        .get(*pos)
        .ok_or_else(|| SerializationError("kv size: unexpected end".into()))?;
    *pos += 1;
    let width = match first & 0x03 {
        0 => 1,
        1 => 2,
        2 => 4,
        3 => 8,
        _ => unreachable!(),
    };
    let mut raw = first as u64;
    for index in 1..width {
        let byte = *data
            .get(*pos)
            .ok_or_else(|| SerializationError("kv size: truncated".into()))?;
        *pos += 1;
        raw |= (byte as u64) << (index * 8);
    }
    usize::try_from(raw >> 2)
        .map_err(|_| SerializationError("kv size: overflow".into()))
}

fn read_kv_bytes<'a>(
    data: &'a [u8],
    pos: &mut usize,
    len: usize,
) -> Result<&'a [u8], SerializationError> {
    let end = pos
        .checked_add(len)
        .ok_or_else(|| SerializationError("kv bytes: overflow".into()))?;
    let bytes = data
        .get(*pos..end)
        .ok_or_else(|| SerializationError("kv bytes: truncated".into()))?;
    *pos = end;
    Ok(bytes)
}

fn read_kv_u16(data: &[u8], pos: &mut usize) -> Result<u16, SerializationError> {
    let mut value = [0u8; 2];
    value.copy_from_slice(read_kv_bytes(data, pos, 2)?);
    Ok(u16::from_le_bytes(value))
}

fn read_kv_u32(data: &[u8], pos: &mut usize) -> Result<u32, SerializationError> {
    let mut value = [0u8; 4];
    value.copy_from_slice(read_kv_bytes(data, pos, 4)?);
    Ok(u32::from_le_bytes(value))
}

fn read_kv_u64(data: &[u8], pos: &mut usize) -> Result<u64, SerializationError> {
    let mut value = [0u8; 8];
    value.copy_from_slice(read_kv_bytes(data, pos, 8)?);
    Ok(u64::from_le_bytes(value))
}

fn read_kv_name(data: &[u8], pos: &mut usize) -> Result<String, SerializationError> {
    let len = *data
        .get(*pos)
        .ok_or_else(|| SerializationError("kv name: unexpected end".into()))?
        as usize;
    *pos += 1;
    let bytes = read_kv_bytes(data, pos, len)?;
    String::from_utf8(bytes.to_vec())
        .map_err(|_| SerializationError("kv name: invalid utf8".into()))
}

fn parse_kv_value(
    data: &[u8],
    pos: &mut usize,
    type_tag: u8,
) -> Result<KvValue, SerializationError> {
    match type_tag {
        1 => Ok(KvValue::Signed(read_kv_u64(data, pos)? as i64)),
        2 => Ok(KvValue::Signed(read_kv_u32(data, pos)? as i32 as i64)),
        3 => Ok(KvValue::Signed(read_kv_u16(data, pos)? as i16 as i64)),
        4 => Ok(KvValue::Signed(
            (*read_kv_bytes(data, pos, 1)?
                .first()
                .ok_or_else(|| SerializationError("kv int8: missing value".into()))?
                as i8) as i64,
        )),
        5 => Ok(KvValue::Unsigned(read_kv_u64(data, pos)?)),
        6 => Ok(KvValue::Unsigned(read_kv_u32(data, pos)? as u64)),
        7 => Ok(KvValue::Unsigned(read_kv_u16(data, pos)? as u64)),
        8 => Ok(KvValue::Unsigned(
            *read_kv_bytes(data, pos, 1)?
                .first()
                .ok_or_else(|| SerializationError("kv uint8: missing value".into()))?
                as u64,
        )),
        9 => Ok(KvValue::Float(f64::from_le_bytes(
            read_kv_bytes(data, pos, 8)?
                .try_into()
                .map_err(|_| SerializationError("kv double: invalid value".into()))?,
        ))),
        10 => {
            let len = read_kv_portable_size(data, pos)?;
            Ok(KvValue::Bytes(read_kv_bytes(data, pos, len)?.to_vec()))
        }
        11 => Ok(KvValue::Bool(
            *read_kv_bytes(data, pos, 1)?
                .first()
                .ok_or_else(|| SerializationError("kv bool: missing value".into()))?
                != 0,
        )),
        12 => Ok(KvValue::Object(parse_kv_section(data, pos)?)),
        other => Err(SerializationError(format!(
            "kv value: unsupported type {other}"
        ))),
    }
}

fn parse_kv_array(
    data: &[u8],
    pos: &mut usize,
    item_type: u8,
) -> Result<KvValue, SerializationError> {
    let count = read_kv_portable_size(data, pos)?;
    let mut values = Vec::with_capacity(count);
    for _ in 0..count {
        values.push(parse_kv_value(data, pos, item_type)?);
    }
    Ok(KvValue::Array(values))
}

fn parse_kv_section(
    data: &[u8],
    pos: &mut usize,
) -> Result<BTreeMap<String, KvValue>, SerializationError> {
    let count = read_kv_portable_size(data, pos)?;
    let mut object = BTreeMap::new();
    for _ in 0..count {
        let name = read_kv_name(data, pos)?;
        let raw_type = *data
            .get(*pos)
            .ok_or_else(|| SerializationError("kv entry: missing type".into()))?;
        *pos += 1;
        let value = if raw_type & 0x80 != 0 {
            parse_kv_array(data, pos, raw_type & 0x7f)?
        } else {
            parse_kv_value(data, pos, raw_type)?
        };
        object.insert(name, value);
    }
    Ok(object)
}

fn parse_kv_document(data: &[u8]) -> Result<BTreeMap<String, KvValue>, SerializationError> {
    if data.len() < 9 {
        return Err(SerializationError("kv document: truncated header".into()));
    }
    let signature_a = u32::from_le_bytes(
        data[0..4]
            .try_into()
            .map_err(|_| SerializationError("kv document: bad signature".into()))?,
    );
    let signature_b = u32::from_le_bytes(
        data[4..8]
            .try_into()
            .map_err(|_| SerializationError("kv document: bad signature".into()))?,
    );
    if signature_a != KV_SIGNATURE_A || signature_b != KV_SIGNATURE_B || data[8] != 1 {
        return Err(SerializationError("kv document: invalid header".into()));
    }
    let mut pos = 9;
    parse_kv_section(data, &mut pos)
}

fn kv_get<'a>(object: &'a BTreeMap<String, KvValue>, names: &[&str]) -> Option<&'a KvValue> {
    names.iter().find_map(|name| object.get(*name))
}

fn kv_u64(object: &BTreeMap<String, KvValue>, names: &[&str]) -> Result<u64, SerializationError> {
    match kv_get(object, names) {
        Some(KvValue::Unsigned(value)) => Ok(*value),
        Some(KvValue::Signed(value)) if *value >= 0 => Ok(*value as u64),
        _ => Err(SerializationError(format!("missing numeric field {:?}", names))),
    }
}

fn kv_bytes(object: &BTreeMap<String, KvValue>, names: &[&str]) -> Result<Vec<u8>, SerializationError> {
    match kv_get(object, names) {
        Some(KvValue::Bytes(value)) => Ok(value.clone()),
        _ => Err(SerializationError(format!("missing bytes field {:?}", names))),
    }
}

fn kv_object<'a>(
    object: &'a BTreeMap<String, KvValue>,
    names: &[&str],
) -> Result<&'a BTreeMap<String, KvValue>, SerializationError> {
    match kv_get(object, names) {
        Some(KvValue::Object(value)) => Ok(value),
        _ => Err(SerializationError(format!("missing object field {:?}", names))),
    }
}

fn kv_array<'a>(
    object: &'a BTreeMap<String, KvValue>,
    names: &[&str],
) -> Result<&'a Vec<KvValue>, SerializationError> {
    match kv_get(object, names) {
        Some(KvValue::Array(value)) => Ok(value),
        _ => Err(SerializationError(format!("missing array field {:?}", names))),
    }
}

fn kv_fixed_bytes(
    object: &BTreeMap<String, KvValue>,
    names: &[&str],
    len: usize,
) -> Result<Vec<u8>, SerializationError> {
    let value = kv_bytes(object, names)?;
    if value.len() != len {
        return Err(SerializationError(format!(
            "field {:?} expected {len} bytes, got {}",
            names,
            value.len()
        )));
    }
    Ok(value)
}

fn kv_tag(object: &BTreeMap<String, KvValue>, names: &[&str]) -> Result<u8, SerializationError> {
    Ok(*kv_fixed_bytes(object, names, 1)?
        .first()
        .ok_or_else(|| SerializationError("missing variant tag".into()))?)
}

fn kv_offsets(object: &BTreeMap<String, KvValue>) -> Result<Vec<u32>, SerializationError> {
    let values = kv_array(object, &["key_offsets"])?;
    let relative = values
        .iter()
        .map(|value| match value {
            KvValue::Unsigned(value) => u32::try_from(*value)
                .map_err(|_| SerializationError("offset exceeds u32".into())),
            KvValue::Signed(value) if *value >= 0 => u32::try_from(*value as u64)
                .map_err(|_| SerializationError("offset exceeds u32".into())),
            _ => Err(SerializationError("invalid offset".into())),
        })
        .collect::<Result<Vec<_>, _>>()?;
    relative_offsets_to_absolute(&relative)
}

fn parse_kv_input(object: &BTreeMap<String, KvValue>) -> Result<TxInput, SerializationError> {
    let tag = kv_tag(object, &["type"])?;
    let value = kv_object(object, &["value"])?;
    let amount = kv_u64(value, &["amount"]).unwrap_or(0);
    let offsets = kv_offsets(value).unwrap_or_default();
    let key_image = kv_fixed_bytes(value, &["k_image"], 32)
        .unwrap_or_else(|_| vec![0; 32])
        .try_into()
        .map_err(|_| SerializationError("invalid key image".into()))?;
    match tag {
        0x02 => Ok(TxInput::Key(KeyInput {
            amount,
            offsets,
            key_image,
        })),
        _ => Ok(TxInput::CommitmentSpend(CommitmentSpendInput {
            amount,
            offsets,
            key_image,
            claimed_interest: kv_u64(value, &["claimed_interest"]).unwrap_or(0),
        })),
    }
}

fn parse_kv_output(object: &BTreeMap<String, KvValue>) -> Result<TxOutput, SerializationError> {
    let amount = kv_u64(object, &["amount"]).unwrap_or(0);
    let target = kv_object(object, &["target"])?;
    let data = kv_object(target, &["data"])?;
    let tag = kv_tag(target, &["type"])?;
    let target = match tag {
        0x02 => OutputTarget::Key(
            kv_fixed_bytes(data, &["key"], 32)?
                .try_into()
                .map_err(|_| SerializationError("invalid output key".into()))?,
        ),
        0x04 => OutputTarget::Commitment(CommitmentOutputTarget {
            commit_key: kv_fixed_bytes(data, &["key"], 32)?
                .try_into()
                .map_err(|_| SerializationError("invalid commitment key".into()))?,
            term: kv_u64(data, &["term"]).unwrap_or(0) as u32,
            amount_commitment: kv_fixed_bytes(data, &["amount_commitment"], 32)
                .unwrap_or_else(|_| vec![0; 32])
                .try_into()
                .map_err(|_| SerializationError("invalid commitment".into()))?,
            amount_proof: kv_fixed_bytes(data, &["amount_proof"], AMOUNT_PROOF_LEN)
                .unwrap_or_else(|_| vec![0; AMOUNT_PROOF_LEN])
                .try_into()
                .map_err(|_| SerializationError("invalid amount proof".into()))?,
        }),
        // Unified outputs carry the same stealth/commitment material needed by
        // the scanner. Map them to the existing commitment representation.
        0x05 => OutputTarget::Commitment(CommitmentOutputTarget {
            commit_key: kv_fixed_bytes(data, &["key"], 32)?
                .try_into()
                .map_err(|_| SerializationError("invalid unified key".into()))?,
            term: kv_u64(data, &["term"]).unwrap_or(0) as u32,
            amount_commitment: kv_fixed_bytes(data, &["commitment"], 32)
                .unwrap_or_else(|_| vec![0; 32])
                .try_into()
                .map_err(|_| SerializationError("invalid unified commitment".into()))?,
            amount_proof: kv_fixed_bytes(data, &["proof"], AMOUNT_PROOF_LEN)
                .unwrap_or_else(|_| vec![0; AMOUNT_PROOF_LEN])
                .try_into()
                .map_err(|_| SerializationError("invalid unified proof".into()))?,
        }),
        _ => OutputTarget::Key([0; 32]),
    };
    Ok(TxOutput { amount, target })
}

fn parse_kv_transaction_prefix(
    object: &BTreeMap<String, KvValue>,
) -> Result<TransactionPrefix, SerializationError> {
    let empty_inputs = Vec::new();
    let input_values = match kv_get(object, &["vin"]) {
        Some(KvValue::Array(values)) => values,
        None => &empty_inputs,
        _ => return Err(SerializationError("vin is not an array".into())),
    };
    let inputs = input_values
        .iter()
        .filter_map(|value| value.as_object())
        .map(parse_kv_input)
        .collect::<Result<Vec<_>, _>>()?;
    let empty_outputs = Vec::new();
    let output_values = match kv_get(object, &["vout"]) {
        Some(KvValue::Array(values)) => values,
        None => &empty_outputs,
        _ => return Err(SerializationError("vout is not an array".into())),
    };
    let outputs = output_values
        .iter()
        .filter_map(|value| value.as_object())
        .map(parse_kv_output)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(TransactionPrefix {
        version: kv_u64(object, &["version"]).unwrap_or(0) as u8,
        unlock_time: kv_u64(object, &["unlock_time"]).unwrap_or(0),
        inputs,
        outputs,
        extra: kv_bytes(object, &["extra"]).unwrap_or_default(),
    })
}

impl KvValue {
    fn as_object(&self) -> Option<&BTreeMap<String, KvValue>> {
        match self {
            KvValue::Object(value) => Some(value),
            _ => None,
        }
    }
}

fn parse_kv_query_blocks_lite_response(
    data: &[u8],
) -> Result<QueryBlocksLiteResponse, SerializationError> {
    let root = parse_kv_document(data)?;
    let status_bytes = kv_bytes(&root, &["status"])?;
    let status = String::from_utf8_lossy(&status_bytes).to_string();
    if status != "OK" {
        return Err(SerializationError(format!("query blocks status: {status}")));
    }
    let items = kv_array(&root, &["items"])?;
    let mut parsed_items = Vec::with_capacity(items.len());
    for item in items {
        let item = item
            .as_object()
            .ok_or_else(|| SerializationError("query item is not an object".into()))?;
        let empty_tx_values = Vec::new();
        let tx_values = match kv_get(item, &["txPrefixes"]) {
            Some(KvValue::Array(values)) => values,
            None => &empty_tx_values,
            _ => return Err(SerializationError("txPrefixes is not an array".into())),
        };
        let mut tx_prefixes = Vec::with_capacity(tx_values.len());
        for tx_value in tx_values {
            let tx_value = tx_value
                .as_object()
                .ok_or_else(|| SerializationError("tx prefix info is not an object".into()))?;
            let parsed = parse_kv_transaction_prefix(kv_object(tx_value, &["txPrefix"])? )?;
            tx_prefixes.push(TxPrefixInfo {
                tx_hash: kv_fixed_bytes(tx_value, &["txHash"], 32)?
                    .try_into()
                    .map_err(|_| SerializationError("invalid transaction hash".into()))?,
                tx_prefix: serialize_prefix(&parsed),
                parsed,
            });
        }
        parsed_items.push(BlockShortInfo {
            block_id: kv_fixed_bytes(item, &["blockId"], 32)?
                .try_into()
                .map_err(|_| SerializationError("invalid block id".into()))?,
            block: kv_bytes(item, &["block"]).unwrap_or_default(),
            tx_prefixes,
        });
    }
    Ok(QueryBlocksLiteResponse {
        status,
        start_height: kv_u64(&root, &["startHeight", "start_height"] )?,
        current_height: kv_u64(&root, &["currentHeight", "current_height"] )?,
        full_offset: kv_u64(&root, &["fullOffset", "full_offset"] )?,
        items: parsed_items,
    })
}

// Kept for callers that need to inspect a KV response during diagnostics.
#[allow(dead_code)]
fn kv_value_to_json(value: &KvValue) -> Value {
    match value {
        KvValue::Signed(v) => Value::from(*v),
        KvValue::Unsigned(v) => Value::from(*v),
        KvValue::Float(v) => Value::from(*v),
        KvValue::Bytes(v) => Value::Array(v.iter().map(|b| Value::from(*b)).collect()),
        KvValue::Bool(v) => Value::from(*v),
        KvValue::Object(v) => Value::Object(
            v.iter()
                .map(|(key, value)| (key.clone(), kv_value_to_json(value)))
                .collect(),
        ),
        KvValue::Array(v) => Value::Array(v.iter().map(kv_value_to_json).collect()),
    }
}
