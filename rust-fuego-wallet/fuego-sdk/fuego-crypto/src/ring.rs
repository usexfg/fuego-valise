//! CryptoNote ring signatures and key derivation, ported from the Fuego
//! daemon (`src/crypto/crypto.cpp`): `generate_ring_signature`,
//! `check_ring_signature`, `hash_to_ec`, `generate_key_image`,
//! `generate_key_derivation`, `derive_public_key`, `derive_secret_key`.

use crate::ref10::{
    ge_add, ge_double_scalarmult_base_vartime, ge_double_scalarmult_precomp_vartime,
    ge_p3_to_p2,
    ge_dsm_precomp, ge_frombytes_vartime, ge_fromfe_frombytes_vartime, ge_mul8, ge_p1p1_to_p2,
    ge_p1p1_to_p3, ge_p3_to_cached, ge_p3_tobytes, ge_scalarmult, ge_scalarmult_base, ge_sub,
    ge_tobytes, random_scalar, sc_add, sc_check, sc_isnonzero, sc_mulsub, sc_reduce32, sc_sub,
    GeCached, GeP1P1, GeP2, GeP3,
};
use sha3::{Digest, Keccak256};

/// `cn_fast_hash` == single Keccak-f[1600] with standard multi-rate padding,
/// first 32 bytes of state (verified byte-identical to daemon keccak.c).
pub fn cn_fast_hash(data: &[u8]) -> [u8; 32] {
    let hash = Keccak256::digest(data);
    let mut out = [0u8; 32];
    out.copy_from_slice(&hash);
    out
}

/// `hash_to_scalar`: cn_fast_hash then reduce mod l.
pub fn hash_to_scalar(data: &[u8]) -> [u8; 32] {
    let mut h = cn_fast_hash(data);
    sc_reduce32(&mut h);
    h
}

/// `secret_key_to_public_key`: pub = scalar * G.
pub fn secret_key_to_public_key(sec: &[u8; 32]) -> [u8; 32] {
    let mut pub_p3 = GeP3::default();
    ge_scalarmult_base(&mut pub_p3, sec);
    let mut pub_key = [0u8; 32];
    ge_p3_tobytes(&mut pub_key, &pub_p3);
    pub_key
}

/// CryptoNote LEB128 varint (Common/Varint.h write_varint).
pub fn write_varint(mut value: u64, out: &mut Vec<u8>) {
    while value >= 0x80 {
        out.push(((value & 0x7F) | 0x80) as u8);
        value >>= 7;
    }
    out.push(value as u8);
}

/// `H_p(key)`: keccak → Montgomery map → *8. Always succeeds (C++ has no
/// failure path here).
pub fn hash_to_ec(key: &[u8; 32]) -> GeP3 {
    let h = cn_fast_hash(key);
    let mut point = GeP2::default();
    ge_fromfe_frombytes_vartime(&mut point, &h);
    let mut point2 = GeP1P1::default();
    ge_mul8(&mut point2, &point);
    let mut res = GeP3::default();
    ge_p1p1_to_p3(&mut res, &point2);
    res
}

/// `generate_key_image`: I = x * H_p(P).
pub fn generate_key_image(pubkey: &[u8; 32], sec: &[u8; 32]) -> [u8; 32] {
    debug_assert!(sc_check(sec)); // valid scalar required
    let point = hash_to_ec(pubkey);
    let mut point2 = GeP2::default();
    ge_scalarmult(&mut point2, sec, &point);
    let mut image = [0u8; 32];
    ge_tobytes(&mut image, &point2);
    image
}

/// Derivation scalar: Hs(derivation || varint(output_index)).
fn derivation_to_scalar(derivation: &[u8; 32], output_index: u64) -> [u8; 32] {
    let mut buf = Vec::with_capacity(32 + 10);
    buf.extend_from_slice(derivation);
    write_varint(output_index, &mut buf);
    hash_to_scalar(&buf)
}

/// `generate_key_derivation`: D = 8 * (key1 * key2), key2 reduced mod l.
pub fn generate_key_derivation(key1: &[u8; 32], key2: &[u8; 32]) -> Option<[u8; 32]> {
    if !sc_check(key2) {
        return None;
    }
    let mut point = GeP3::default();
    if !ge_frombytes_vartime(&mut point, key1) {
        return None;
    }
    let mut point2 = GeP2::default();
    ge_scalarmult(&mut point2, key2, &point);
    let mut point3 = GeP1P1::default();
    ge_mul8(&mut point3, &point2);
    ge_p1p1_to_p2(&mut point2, &point3);
    let mut derivation = [0u8; 32];
    ge_tobytes(&mut derivation, &point2);
    Some(derivation)
}

/// `derive_public_key`: P_out = Hs(D || varint(i)) * G + base.
pub fn derive_public_key(
    derivation: &[u8; 32],
    output_index: u64,
    base: &[u8; 32],
) -> Option<[u8; 32]> {
    let mut point1 = GeP3::default();
    if !ge_frombytes_vartime(&mut point1, base) {
        return None;
    }
    let scalar = derivation_to_scalar(derivation, output_index);
    let mut point2 = GeP3::default();
    ge_scalarmult_base(&mut point2, &scalar);
    let mut point3 = GeCached::default();
    ge_p3_to_cached(&mut point3, &point2);
    let mut point4 = GeP1P1::default();
    ge_add(&mut point4, &point1, &point3);
    let mut point5 = GeP2::default();
    ge_p1p1_to_p2(&mut point5, &point4);
    let mut derived = [0u8; 32];
    ge_tobytes(&mut derived, &point5);
    Some(derived)
}

/// `underive_public_key`: base = P_out - Hs(D || varint(i)) * G.
pub fn underive_public_key(
    derivation: &[u8; 32],
    output_index: u64,
    derived_key: &[u8; 32],
) -> Option<[u8; 32]> {
    let mut point1 = GeP3::default();
    if !ge_frombytes_vartime(&mut point1, derived_key) {
        return None;
    }
    let scalar = derivation_to_scalar(derivation, output_index);
    let mut point2 = GeP3::default();
    ge_scalarmult_base(&mut point2, &scalar);
    let mut point3 = GeCached::default();
    ge_p3_to_cached(&mut point3, &point2);
    let mut point4 = GeP1P1::default();
    ge_sub(&mut point4, &point1, &point3);
    let mut point5 = GeP2::default();
    ge_p1p1_to_p2(&mut point5, &point4);
    let mut base = [0u8; 32];
    ge_tobytes(&mut base, &point5);
    Some(base)
}

/// `derive_secret_key`: b_out = b + Hs(D || varint(i)) (mod l).
pub fn derive_secret_key(
    derivation: &[u8; 32],
    output_index: u64,
    base: &[u8; 32],
) -> Option<[u8; 32]> {
    if !sc_check(base) {
        return None;
    }
    let scalar = derivation_to_scalar(derivation, output_index);
    let mut derived = [0u8; 32];
    sc_add(&mut derived, base, &scalar);
    Some(derived)
}

/// `generate_ring_signature` (crypto.cpp:510). One signature per ring member,
/// each 64 bytes: c_i (32) || r_i (32), in ring order.
///
/// Returns `None` if the key image fails to decompress or any decoy public
/// key is invalid (mirrors the C++ silent-return behavior).
pub fn generate_ring_signature(
    prefix_hash: &[u8; 32],
    image: &[u8; 32],
    pubs: &[[u8; 32]],
    sec: &[u8; 32],
    sec_index: usize,
    rng: &mut impl rand::RngCore,
) -> Option<Vec<[u8; 64]>> {
    debug_assert!(sec_index < pubs.len());
    let image_unp = {
        let mut p = GeP3::default();
        if !ge_frombytes_vartime(&mut p, image) {
            return None;
        }
        p
    };
    let mut image_pre = [GeCached::default(); 8];
    ge_dsm_precomp(&mut image_pre, &image_unp);

    let mut sum = [0u8; 32];
    let mut buf = Vec::with_capacity(32 + 64 * pubs.len());
    buf.extend_from_slice(prefix_hash);
    let mut lr = Vec::with_capacity(64 * pubs.len());
    let mut sig = vec![[0u8; 64]; pubs.len()];
    let mut k = [0u8; 32];

    for (i, pub_i) in pubs.iter().enumerate() {
        if i == sec_index {
            k = random_scalar(rng);
            let mut tmp3 = GeP3::default();
            ge_scalarmult_base(&mut tmp3, &k);
            let mut a = [0u8; 32];
            ge_p3_tobytes(&mut a, &tmp3);
            let hp = hash_to_ec(pub_i);
            let mut tmp2 = GeP2::default();
            ge_scalarmult(&mut tmp2, &k, &hp);
            let mut b = [0u8; 32];
            ge_tobytes(&mut b, &tmp2);
            lr.extend_from_slice(&a);
            lr.extend_from_slice(&b);
        } else {
            let c_i = random_scalar(rng);
            let r_i = random_scalar(rng);
            sig[i][..32].copy_from_slice(&c_i);
            sig[i][32..].copy_from_slice(&r_i);
            let tmp3 = {
                let mut p = GeP3::default();
                if !ge_frombytes_vartime(&mut p, pub_i) {
                    return None;
                }
                p
            };
            let mut tmp2 = GeP2::default();
            ge_double_scalarmult_base_vartime(&mut tmp2, &c_i, &tmp3, &r_i);
            let mut a = [0u8; 32];
            ge_tobytes(&mut a, &tmp2);
            let hp = hash_to_ec(pub_i);
            ge_double_scalarmult_precomp_vartime(&mut tmp2, &r_i, &hp, &c_i, &image_pre);
            let mut b = [0u8; 32];
            ge_tobytes(&mut b, &tmp2);
            let s0 = sum; sc_add(&mut sum, &s0, &c_i);
            lr.extend_from_slice(&a);
            lr.extend_from_slice(&b);
        }
    }

    buf.extend_from_slice(&lr);
    let mut h = hash_to_scalar(&buf);
    let h0 = h; sc_sub(&mut h, &h0, &sum); // c_real = h - sum(decoy c_i)
    sig[sec_index][..32].copy_from_slice(&h);
    let mut r = [0u8; 32];
    sc_mulsub(&mut r, &h, sec, &k); // r_real = k - c_real * sec
    sig[sec_index][32..].copy_from_slice(&r);
    Some(sig)
}

/// `check_ring_signature` (crypto.cpp:572).
pub fn check_ring_signature(
    prefix_hash: &[u8; 32],
    image: &[u8; 32],
    pubs: &[[u8; 32]],
    sig: &[[u8; 64]],
) -> bool {
    if sig.len() != pubs.len() || pubs.is_empty() {
        return false;
    }
    let image_unp = {
        let mut p = GeP3::default();
        if !ge_frombytes_vartime(&mut p, image) {
            return false;
        }
        p
    };
    let mut image_pre = [GeCached::default(); 8];
    ge_dsm_precomp(&mut image_pre, &image_unp);

    let mut sum = [0u8; 32];
    let mut buf = Vec::with_capacity(32 + 64 * pubs.len());
    buf.extend_from_slice(prefix_hash);
    let mut lr = Vec::with_capacity(64 * pubs.len());

    for (i, pub_i) in pubs.iter().enumerate() {
        let c_i = &sig[i][..32];
        let r_i = &sig[i][32..];
        if !sc_check(c_i.try_into().unwrap()) || !sc_check(r_i.try_into().unwrap()) {
            return false;
        }
        let tmp3 = {
            let mut p = GeP3::default();
            if !ge_frombytes_vartime(&mut p, pub_i) {
                return false;
            }
            p
        };
        let mut tmp2 = GeP2::default();
        ge_double_scalarmult_base_vartime(&mut tmp2, c_i.try_into().unwrap(), &tmp3, r_i.try_into().unwrap());
        let mut a = [0u8; 32];
        ge_tobytes(&mut a, &tmp2);
        let hp = hash_to_ec(pub_i);
        ge_double_scalarmult_precomp_vartime(
            &mut tmp2,
            r_i.try_into().unwrap(),
            &hp,
            c_i.try_into().unwrap(),
            &image_pre,
        );
        let mut b = [0u8; 32];
        ge_tobytes(&mut b, &tmp2);
        let s0 = sum; sc_add(&mut sum, &s0, c_i.try_into().unwrap());
        lr.extend_from_slice(&a);
        lr.extend_from_slice(&b);
    }

    buf.extend_from_slice(&lr);
    let mut h = hash_to_scalar(&buf);
    let h0 = h; sc_sub(&mut h, &h0, &sum);
    !sc_isnonzero(&h)
}

// ---------------------------------------------------------------- adaptors
// Port of src/crypto/adaptor.cpp: AFK lock pre-signatures (Ed25519 adaptor
// signatures over the Schnorr-like scheme: c = Hs(prefix || P || R'),
// r_hat = k - c*x, full sig r = r_hat + t with T = t*G).

/// Reject identity and small-order points (adaptor.cpp point_is_valid).
pub fn point_is_valid(bytes: &[u8; 32]) -> bool {
    if bytes.iter().all(|b| *b == 0) {
        return false;
    }
    let mut p3 = GeP3::default();
    if !ge_frombytes_vartime(&mut p3, bytes) {
        return false;
    }
    let mut p2 = GeP2::default();
    ge_p3_to_p2(&mut p2, &p3);
    let mut p11 = GeP1P1::default();
    ge_mul8(&mut p11, &p2);
    let mut p2r = GeP2::default();
    ge_p1p1_to_p2(&mut p2r, &p11);
    let mut out = [0u8; 32];
    ge_tobytes(&mut out, &p2r);
    !out.iter().all(|b| *b == 0)
}

/// adaptor.cpp generate_adaptor_signature.
pub fn generate_adaptor_signature(
    prefix_hash: &[u8; 32],
    pub_key: &[u8; 32],
    sec: &[u8; 32],
    adaptor_point: &[u8; 32],
    rng: &mut impl rand::RngCore,
) -> Option<[u8; 64]> {
    if !point_is_valid(adaptor_point) {
        return None;
    }
    let mut t_p3 = GeP3::default();
    ge_frombytes_vartime(&mut t_p3, adaptor_point);

    let k = random_scalar(rng);
    let mut r_p3 = GeP3::default();
    ge_scalarmult_base(&mut r_p3, &k);

    // R' = R + T
    let mut t_cached = GeCached::default();
    ge_p3_to_cached(&mut t_cached, &t_p3);
    let mut rp_p11 = GeP1P1::default();
    ge_add(&mut rp_p11, &r_p3, &t_cached);
    let mut rp_p3 = GeP3::default();
    ge_p1p1_to_p3(&mut rp_p3, &rp_p11);

    // c = Hs(prefix || pub || R')
    let mut buf = Vec::with_capacity(96);
    buf.extend_from_slice(prefix_hash);
    buf.extend_from_slice(pub_key);
    let mut comm = [0u8; 32];
    ge_p3_tobytes(&mut comm, &rp_p3);
    buf.extend_from_slice(&comm);
    let c = hash_to_scalar(&buf);

    // r_hat = k - c*sec
    let mut r_hat = [0u8; 32];
    sc_mulsub(&mut r_hat, &c, sec, &k);

    let mut pre_sig = [0u8; 64];
    pre_sig[..32].copy_from_slice(&c);
    pre_sig[32..].copy_from_slice(&r_hat);
    Some(pre_sig)
}

/// adaptor.cpp check_adaptor_signature.
pub fn check_adaptor_signature(
    prefix_hash: &[u8; 32],
    pub_key: &[u8; 32],
    adaptor_point: &[u8; 32],
    pre_sig: &[u8; 64],
) -> bool {
    if !point_is_valid(adaptor_point) {
        return false;
    }
    let mut p3 = GeP3::default();
    if !ge_frombytes_vartime(&mut p3, pub_key) {
        return false;
    }
    let c: [u8; 32] = pre_sig[..32].try_into().unwrap();
    let r_hat: [u8; 32] = pre_sig[32..].try_into().unwrap();
    if !sc_check(&c) || !sc_check(&r_hat) {
        return false;
    }

    // R = r_hat*G + c*P
    let mut r_p2 = GeP2::default();
    ge_double_scalarmult_base_vartime(&mut r_p2, &c, &p3, &r_hat);
    let mut r_bytes = [0u8; 32];
    ge_tobytes(&mut r_bytes, &r_p2);
    let mut r_p3 = GeP3::default();
    if !ge_frombytes_vartime(&mut r_p3, &r_bytes) {
        return false;
    }

    // R' = R + T
    let mut t_p3 = GeP3::default();
    ge_frombytes_vartime(&mut t_p3, adaptor_point);
    let mut t_cached = GeCached::default();
    ge_p3_to_cached(&mut t_cached, &t_p3);
    let mut rp_p11 = GeP1P1::default();
    ge_add(&mut rp_p11, &r_p3, &t_cached);
    let mut rp_p3 = GeP3::default();
    ge_p1p1_to_p3(&mut rp_p3, &rp_p11);

    let mut buf = Vec::with_capacity(96);
    buf.extend_from_slice(prefix_hash);
    buf.extend_from_slice(pub_key);
    let mut comm = [0u8; 32];
    ge_p3_tobytes(&mut comm, &rp_p3);
    buf.extend_from_slice(&comm);
    let c_prime = hash_to_scalar(&buf);

    let mut diff = [0u8; 32];
    sc_sub(&mut diff, &c_prime, &c);
    !sc_isnonzero(&diff)
}

/// adaptor.cpp adapt_signature: r = r_hat + t.
pub fn adapt_signature(pre_sig: &[u8; 64], adaptor_secret: &[u8; 32]) -> [u8; 64] {
    let mut sig = [0u8; 64];
    sig[..32].copy_from_slice(&pre_sig[..32]);
    let mut r = [0u8; 32];
    sc_add(&mut r, &pre_sig[32..].try_into().unwrap(), adaptor_secret);
    sig[32..].copy_from_slice(&r);
    sig
}

/// adaptor.cpp extract_adaptor_secret: t = r - r_hat.
pub fn extract_adaptor_secret(pre_sig: &[u8; 64], sig: &[u8; 64]) -> Option<[u8; 32]> {
    if pre_sig[..32] != sig[..32] {
        return None;
    }
    let mut t = [0u8; 32];
    sc_sub(&mut t, &sig[32..].try_into().unwrap(), &pre_sig[32..].try_into().unwrap());
    if sc_isnonzero(&t) {
        Some(t)
    } else {
        None
    }
}

/// adaptor.cpp generate_afk_lock_data: secret s, S = s*G, pre-sig over the
/// given prefix hash.
pub fn generate_afk_lock_data(
    prefix_hash: &[u8; 32],
    pub_key: &[u8; 32],
    sec: &[u8; 32],
    rng: &mut impl rand::RngCore,
) -> Option<([u8; 32], [u8; 32], [u8; 64])> {
    let secret = random_scalar(rng);
    let mut s_p3 = GeP3::default();
    ge_scalarmult_base(&mut s_p3, &secret);
    let mut adaptor_point = [0u8; 32];
    ge_p3_tobytes(&mut adaptor_point, &s_p3);
    let pre_sig = generate_adaptor_signature(prefix_hash, pub_key, sec, &adaptor_point, rng)?;
    Some((secret, adaptor_point, pre_sig))
}

// ---------------------------------------------------------------- deposits

/// TransactionExtra.cpp deriveCommitmentKeys (pre-v11, retained for rescans).
pub struct CommitmentKeys {
    pub key_scalar: [u8; 32],
    pub commit_key: [u8; 32],
    pub key_image: [u8; 32],
    pub amount_mask: [u8; 32],
}

/// TransactionExtra.cpp deriveCommitmentKeys (pre-v11):
/// keyScalar = Hs("fuego_commit_key" || depositSecret), commitKey = keyScalar*G,
/// keyImage = x*Hp(commitKey), amountMask = Hs("fuego_amount_mask" || secret).
///
/// Sender- and view-key-spendable. Never use for new user-owned outputs; see
/// `derive_owner_bound_commit_key`.
pub fn derive_commitment_keys(deposit_secret: &[u8; 32]) -> CommitmentKeys {
    const COMMIT_LABEL: &[u8; 16] = b"fuego_commit_key";
    const AMOUNT_LABEL: &[u8; 17] = b"fuego_amount_mask";

    let mut pre = [0u8; 48];
    pre[..16].copy_from_slice(COMMIT_LABEL);
    pre[16..].copy_from_slice(deposit_secret);
    let key_scalar = hash_to_scalar(&pre);

    let mut p = GeP3::default();
    ge_scalarmult_base(&mut p, &key_scalar);
    let mut commit_key = [0u8; 32];
    ge_p3_tobytes(&mut commit_key, &p);
    let key_image = generate_key_image(&commit_key, &key_scalar);

    let mut am_pre = [0u8; 49];
    am_pre[..17].copy_from_slice(AMOUNT_LABEL);
    am_pre[17..].copy_from_slice(deposit_secret);
    let amount_mask = hash_to_scalar(&am_pre);

    CommitmentKeys {
        key_scalar,
        commit_key,
        key_image,
        amount_mask,
    }
}

/// WalletTransactionSender.cpp deriveCommitmentSecret:
/// depositSecret = cn_fast_hash(D || outputIndex_LE32).
pub fn derive_deposit_secret(derivation: &[u8; 32], output_index: u32) -> [u8; 32] {
    let mut pre = [0u8; 36];
    pre[..32].copy_from_slice(derivation);
    pre[32..].copy_from_slice(&output_index.to_le_bytes());
    cn_fast_hash(&pre)
}

// ------------------------------------------------- owner-bound commitments

/// TransactionExtra.cpp `deriveOwnerBoundCommitKey`.
///
/// `P = derive_public_key(D, i, B)` — spendable only by the holder of the
/// recipient spend secret `b`, via `derive_owner_bound_key_image`. The sender
/// and any holder of the recipient view secret know `D` and therefore `t`, but
/// cannot produce `x = b + t`.
pub fn derive_owner_bound_commit_key(
    derivation: &[u8; 32],
    output_index: u64,
    recipient_spend_public: &[u8; 32],
) -> Option<[u8; 32]> {
    let mut point = GeP3::default();
    if !ge_frombytes_vartime(&mut point, recipient_spend_public) {
        return None;
    }
    derive_public_key(derivation, output_index, recipient_spend_public)
}

/// TransactionExtra.cpp `matchOwnerBoundCommitKey`: recover the recipient spend
/// key that produced `commit_key`, then check it against the registered set.
///
/// `underive_public_key` solves for the single `B` that produced this output, so
/// it is evaluated once. Returns the matched key on a unique hit, or `None` when
/// there is no match or the recovered key does not re-derive the output.
pub fn match_owner_bound_commit_key(
    derivation: &[u8; 32],
    output_index: u64,
    commit_key: &[u8; 32],
    registered_spend_keys: &[[u8; 32]],
) -> Option<[u8; 32]> {
    let candidate = underive_public_key(derivation, output_index, commit_key)?;
    if !registered_spend_keys.iter().any(|k| *k == candidate) {
        return None;
    }
    // Confirm the recovered key really re-derives the published output rather
    // than trusting the subtraction alone.
    match derive_public_key(derivation, output_index, &candidate) {
        Some(verify) if verify == *commit_key => Some(candidate),
        _ => None,
    }
}

/// TransactionExtra.cpp `deriveOwnerBoundKeyImage`.
///
/// `x = b + t` and `I = x * H_p(P)`. Returns `None` if the secret is
/// non-canonical or if `x*G != P` (i.e. the wrong spend secret), so callers get
/// a rejection rather than an exception.
pub fn derive_owner_bound_key_image(
    derivation: &[u8; 32],
    output_index: u64,
    commit_key: &[u8; 32],
    recipient_spend_secret: &[u8; 32],
) -> Option<([u8; 32], [u8; 32])> {
    let mut commit_point = GeP3::default();
    if !ge_frombytes_vartime(&mut commit_point, commit_key) {
        return None;
    }
    if !sc_check(recipient_spend_secret) {
        return None;
    }
    let spend_secret = derive_secret_key(derivation, output_index, recipient_spend_secret)?;
    let derived_pub = secret_key_to_public_key(&spend_secret);
    if derived_pub != *commit_key {
        return None;
    }
    let key_image = generate_key_image(commit_key, &spend_secret);
    Some((spend_secret, key_image))
}

/// TransactionExtra.cpp `deriveCommitmentOutputKey` — the single creation entry
/// point, mirroring C++.
///
/// With a recipient spend key this returns the owner-bound form. `None` means a
/// hard failure; callers must not fall back to `derive_commitment_keys`, which
/// would silently recreate the sender/view-key-spendable derivation.
pub fn derive_commitment_output_key(
    derivation: &[u8; 32],
    output_index: u64,
    recipient_spend_public: Option<&[u8; 32]>,
) -> Option<[u8; 32]> {
    match recipient_spend_public {
        // Protocol-owned output (pool escrow marker): unspendable by design and
        // excluded from rings by term. Mirrors the C++ null-key escape hatch.
        None => {
            let deposit_secret = derive_deposit_secret(derivation, output_index as u32);
            let legacy = derive_commitment_keys(&deposit_secret);
            Some(legacy.commit_key)
        }
        Some(spend_public) => derive_owner_bound_commit_key(derivation, output_index, spend_public),
    }
}

// ---------------------------------------------------------------- tx proofs
// Port of crypto.cpp generate_tx_proof / check_tx_proof: a signature proving
// knowledge of the tx secret key r with R = r*G and D = r*A (raw, no
// cofactor — matches WalletLegacy::getTxProof via scalarmultKey).

/// crypto.cpp generate_tx_proof. `d` must equal r*A without the cofactor.
pub fn generate_tx_proof(
    prefix_hash: &[u8; 32],
    r: &[u8; 32],
    r_pub: &[u8; 32],
    a: &[u8; 32],
    d: &[u8; 32],
    rng: &mut impl rand::RngCore,
) -> Option<[u8; 64]> {
    let mut r_p3 = GeP3::default();
    let mut a_p3 = GeP3::default();
    let mut d_p3 = GeP3::default();
    if !ge_frombytes_vartime(&mut r_p3, r_pub)
        || !ge_frombytes_vartime(&mut a_p3, a)
        || !ge_frombytes_vartime(&mut d_p3, d)
    {
        return None;
    }
    debug_assert!(sc_check(r));

    // k, X = k*G, Y = k*A
    let k = random_scalar(rng);
    let mut x_p3 = GeP3::default();
    ge_scalarmult_base(&mut x_p3, &k);
    let mut y_p2 = GeP2::default();
    ge_scalarmult(&mut y_p2, &k, &a_p3);

    // c = Hs(prefix || D || X || Y)
    let mut buf = Vec::with_capacity(128);
    buf.extend_from_slice(prefix_hash);
    buf.extend_from_slice(d);
    let mut x_b = [0u8; 32];
    ge_p3_tobytes(&mut x_b, &x_p3);
    let mut y_b = [0u8; 32];
    ge_tobytes(&mut y_b, &y_p2);
    buf.extend_from_slice(&x_b);
    buf.extend_from_slice(&y_b);
    let c = hash_to_scalar(&buf);

    // sig.r = k - c*r
    let mut sig_r = [0u8; 32];
    sc_mulsub(&mut sig_r, &c, r, &k);

    let mut sig = [0u8; 64];
    sig[..32].copy_from_slice(&c);
    sig[32..].copy_from_slice(&sig_r);
    Some(sig)
}

/// crypto.cpp check_tx_proof.
pub fn check_tx_proof(
    prefix_hash: &[u8; 32],
    r_pub: &[u8; 32],
    a: &[u8; 32],
    d: &[u8; 32],
    sig: &[u8; 64],
) -> bool {
    let mut r_p3 = GeP3::default();
    let mut a_p3 = GeP3::default();
    let mut d_p3 = GeP3::default();
    if !ge_frombytes_vartime(&mut r_p3, r_pub)
        || !ge_frombytes_vartime(&mut a_p3, a)
        || !ge_frombytes_vartime(&mut d_p3, d)
    {
        return false;
    }
    let c: [u8; 32] = sig[..32].try_into().unwrap();
    let sr: [u8; 32] = sig[32..].try_into().unwrap();
    if !sc_check(&c) || !sc_check(&sr) {
        return false;
    }

    // X = c*R + sr*G
    let mut cr_p2 = GeP2::default();
    ge_scalarmult(&mut cr_p2, &c, &r_p3);
    let mut sg_p3 = GeP3::default();
    ge_scalarmult_base(&mut sg_p3, &sr);
    let mut cr_b = [0u8; 32];
    ge_tobytes(&mut cr_b, &cr_p2);
    let mut cr_p3 = GeP3::default();
    if !ge_frombytes_vartime(&mut cr_p3, &cr_b) {
        return false;
    }
    let mut sg_cached = GeCached::default();
    ge_p3_to_cached(&mut sg_cached, &sg_p3);
    let mut x_p11 = GeP1P1::default();
    ge_add(&mut x_p11, &cr_p3, &sg_cached);
    let mut x_p2 = GeP2::default();
    ge_p1p1_to_p2(&mut x_p2, &x_p11);

    // Y = c*D + sr*A
    let mut cd_p2 = GeP2::default();
    ge_scalarmult(&mut cd_p2, &c, &d_p3);
    let mut sa_p2 = GeP2::default();
    ge_scalarmult(&mut sa_p2, &sr, &a_p3);
    let mut cd_b = [0u8; 32];
    let mut sa_b = [0u8; 32];
    ge_tobytes(&mut cd_b, &cd_p2);
    ge_tobytes(&mut sa_b, &sa_p2);
    let mut cd_p3 = GeP3::default();
    let mut sa_p3 = GeP3::default();
    if !ge_frombytes_vartime(&mut cd_p3, &cd_b)
        || !ge_frombytes_vartime(&mut sa_p3, &sa_b)
    {
        return false;
    }
    let mut sa_cached = GeCached::default();
    ge_p3_to_cached(&mut sa_cached, &sa_p3);
    let mut y_p11 = GeP1P1::default();
    ge_add(&mut y_p11, &cd_p3, &sa_cached);
    let mut y_p2 = GeP2::default();
    ge_p1p1_to_p2(&mut y_p2, &y_p11);

    // c2 = Hs(prefix || D || X || Y); verify c2 == c.
    let mut buf = Vec::with_capacity(128);
    buf.extend_from_slice(prefix_hash);
    buf.extend_from_slice(d);
    let mut x_b = [0u8; 32];
    ge_tobytes(&mut x_b, &x_p2);
    let mut y_b = [0u8; 32];
    ge_tobytes(&mut y_b, &y_p2);
    buf.extend_from_slice(&x_b);
    buf.extend_from_slice(&y_b);
    let c2 = hash_to_scalar(&buf);

    let mut diff = [0u8; 32];
    sc_sub(&mut diff, &c2, &c);
    !sc_isnonzero(&diff)
}

/// Raw r*A (no cofactor multiply) — the D used by tx proofs
/// (WalletLegacy::getTxProof via scalarmultKey).
pub fn raw_scalarmult_key(a: &[u8; 32], r: &[u8; 32]) -> Option<[u8; 32]> {
    let mut a_p3 = GeP3::default();
    if !ge_frombytes_vartime(&mut a_p3, a) {
        return None;
    }
    let mut p2 = GeP2::default();
    ge_scalarmult(&mut p2, r, &a_p3);
    let mut out = [0u8; 32];
    ge_tobytes(&mut out, &p2);
    Some(out)
}

/// CryptoNote `generate_signature(prefix_hash, pub, sec)` — the Schnorr
/// (c, r) signature used for swap offers and cancellations
/// (`src/crypto/crypto.cpp`). Ported byte-for-byte:
///   buf = prefix_hash ‖ pubkey;  k = random scalar;  comm = (k·G)
///   c   = Hs(buf ‖ comm);        r   = k − c·sec
/// Signature layout: [c (32)] [r (32)].
pub fn generate_signature(
    prefix_hash: &[u8; 32],
    pubkey: &[u8; 32],
    sec: &[u8; 32],
    rng: &mut impl rand::RngCore,
) -> Option<[u8; 64]> {
    if !sc_check(sec) {
        return None;
    }
    let mut buf = [0u8; 96];
    buf[..32].copy_from_slice(prefix_hash);
    buf[32..64].copy_from_slice(pubkey);
    let k = random_scalar(rng);
    let mut tmp3 = GeP3::default();
    ge_scalarmult_base(&mut tmp3, &k);
    let mut comm = [0u8; 32];
    ge_p3_tobytes(&mut comm, &tmp3);
    buf[64..].copy_from_slice(&comm);
    let c = hash_to_scalar(&buf);
    let mut sig = [0u8; 64];
    sig[..32].copy_from_slice(&c);
    let mut r = [0u8; 32];
    sc_mulsub(&mut r, &c, sec, &k); // r = k − c·sec
    sig[32..].copy_from_slice(&r);
    Some(sig)
}

/// CryptoNote `check_signature(prefix_hash, pub, sig)` — verifies the
/// Schnorr (c, r) signature. Ported byte-for-byte:
///   L = r·G + c·pub;  c' = Hs(prefix_hash ‖ pub ‖ L);  accept iff c' == c.
pub fn check_signature(prefix_hash: &[u8; 32], pubkey: &[u8; 32], sig: &[u8; 64]) -> bool {
    let mut p3 = GeP3::default();
    if !ge_frombytes_vartime(&mut p3, pubkey) {
        return false;
    }
    let c: [u8; 32] = match sig[..32].try_into() {
        Ok(v) => v,
        Err(_) => return false,
    };
    let r: [u8; 32] = match sig[32..].try_into() {
        Ok(v) => v,
        Err(_) => return false,
    };
    if !sc_check(&c) || !sc_check(&r) {
        return false;
    }
    let mut buf = [0u8; 96];
    buf[..32].copy_from_slice(prefix_hash);
    buf[32..64].copy_from_slice(pubkey);
    let mut p2 = GeP2::default();
    ge_double_scalarmult_base_vartime(&mut p2, &c, &p3, &r); // L = r·G + c·pub
    let mut comm = [0u8; 32];
    ge_tobytes(&mut comm, &p2);
    buf[64..].copy_from_slice(&comm);
    let c2 = hash_to_scalar(&buf);
    let mut diff = [0u8; 32];
    sc_sub(&mut diff, &c2, &c);
    !sc_isnonzero(&diff)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_check_round_trip() {
        let mut rng = rand::thread_rng();
        let sec = random_scalar(&mut rng);
        let mut pub_p3 = GeP3::default();
        ge_scalarmult_base(&mut pub_p3, &sec);
        let mut pubkey = [0u8; 32];
        ge_p3_tobytes(&mut pubkey, &pub_p3);

        let prefix_hash: [u8; 32] = {
            let mut h = [0u8; 32];
            for (i, b) in h.iter_mut().enumerate() {
                *b = i as u8;
            }
            h
        };

        let sig = generate_signature(&prefix_hash, &pubkey, &sec, &mut rng).unwrap();
        assert!(check_signature(&prefix_hash, &pubkey, &sig));

        // Tampered signature must fail.
        let mut bad = sig;
        bad[0] ^= 0x01;
        assert!(!check_signature(&prefix_hash, &pubkey, &bad));

        // Wrong message must fail.
        let mut other_hash = prefix_hash;
        other_hash[31] ^= 0x80;
        assert!(!check_signature(&other_hash, &pubkey, &sig));

        // Wrong key must fail.
        let sec2 = random_scalar(&mut rng);
        let mut pub_p3_2 = GeP3::default();
        ge_scalarmult_base(&mut pub_p3_2, &sec2);
        let mut pubkey2 = [0u8; 32];
        ge_p3_tobytes(&mut pubkey2, &pub_p3_2);
        assert!(!check_signature(&prefix_hash, &pubkey2, &sig));
    }
}
