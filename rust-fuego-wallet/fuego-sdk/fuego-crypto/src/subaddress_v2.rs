//! funsa V2 sub-addresses and their transaction keys, ported from fuego-suite
//! `src/crypto/subaddress.cpp` (deriveSubAddressKeysV2 and the helpers next to it).
//!
//! With master keys a (view) and b (spend), B = bG:
//!   m  = Hs("FuegoSubAddrV2" || a || major_le32 || minor_le32)
//!   D  = B + mG                 sub-address spend public key
//!   C  = a*D (no cofactor)      sub-address view public key
//!   b' = b + m                  sub-address spend secret
//! A sender paying (D, C) uses R = r*D (single-key tx) or R_n = r_n*D per output,
//! with r_n = Hs("FuegoAddlTxKey" || r || n_le64), and publishes the Janus base
//! J = r*G (0x09) so the receiver can check b'*J == R.

use crate::ref10::{
    ge_add, ge_frombytes_vartime, ge_p1p1_to_p3, ge_p3_to_cached, ge_p3_tobytes, ge_scalarmult,
    ge_scalarmult_base, ge_tobytes, sc_add, sc_check, GeCached, GeP1P1, GeP2, GeP3,
};
use crate::ring::{hash_to_scalar, secret_key_to_public_key};
use zeroize::Zeroize;

const SUBADDRESS_DOMAIN: &[u8] = b"FuegoSubAddrV2";
const ADDITIONAL_TX_KEY_DOMAIN: &[u8] = b"FuegoAddlTxKey";
const JANUS_FILLER_DOMAIN: &[u8] = b"FuegoJanusFiller";

#[derive(Clone)]
pub struct SubaddressV2Keys {
    /// D = B + mG
    pub spend_public: [u8; 32],
    /// C = a*D
    pub view_public: [u8; 32],
    /// b + m, when the master spend secret was supplied.
    pub spend_secret: Option<[u8; 32]>,
}

impl Drop for SubaddressV2Keys {
    fn drop(&mut self) {
        if let Some(s) = self.spend_secret.as_mut() {
            s.zeroize();
        }
    }
}

/// s*P without the cofactor multiply (scalarmultKeyNoCofactor). None when s is
/// not a reduced scalar or P is not a point.
pub fn scalarmult_no_cofactor(point: &[u8; 32], scalar: &[u8; 32]) -> Option<[u8; 32]> {
    if !sc_check(scalar) {
        return None;
    }
    let mut p = GeP3::default();
    if !ge_frombytes_vartime(&mut p, point) {
        return None;
    }
    let mut product = GeP2::default();
    ge_scalarmult(&mut product, scalar, &p);
    let mut out = [0u8; 32];
    ge_tobytes(&mut out, &product);
    Some(out)
}

fn index_scalar(view_secret: &[u8; 32], major: u32, minor: u32) -> [u8; 32] {
    let mut pre = Vec::with_capacity(SUBADDRESS_DOMAIN.len() + 40);
    pre.extend_from_slice(SUBADDRESS_DOMAIN);
    pre.extend_from_slice(view_secret);
    pre.extend_from_slice(&major.to_le_bytes());
    pre.extend_from_slice(&minor.to_le_bytes());
    let m = hash_to_scalar(&pre);
    pre.zeroize();
    m
}

fn add_scalar_base(point: &[u8; 32], scalar: &[u8; 32]) -> Option<[u8; 32]> {
    let mut p = GeP3::default();
    if !ge_frombytes_vartime(&mut p, point) {
        return None;
    }
    let mut s_g = GeP3::default();
    ge_scalarmult_base(&mut s_g, scalar);
    let mut s_g_cached = GeCached::default();
    ge_p3_to_cached(&mut s_g_cached, &s_g);
    let mut sum = GeP1P1::default();
    ge_add(&mut sum, &p, &s_g_cached);
    let mut sum_p3 = GeP3::default();
    ge_p1p1_to_p3(&mut sum_p3, &sum);
    let mut out = [0u8; 32];
    ge_p3_tobytes(&mut out, &sum_p3);
    Some(out)
}

/// V2 sub-address (major, minor) of the wallet (a, B). (0, 0) is refused: wallets
/// never publish it, so a request for it is a caller error.
pub fn derive_subaddress_v2_keys(
    view_secret: &[u8; 32],
    spend_public: &[u8; 32],
    spend_secret: Option<&[u8; 32]>,
    major: u32,
    minor: u32,
) -> Option<SubaddressV2Keys> {
    if (major, minor) == (0, 0) || !sc_check(view_secret) {
        return None;
    }
    let mut m = index_scalar(view_secret, major, minor);
    let derived = add_scalar_base(spend_public, &m).and_then(|d| {
        let c = scalarmult_no_cofactor(&d, view_secret)?;
        let secret = spend_secret.map(|b| {
            let mut out = [0u8; 32];
            sc_add(&mut out, b, &m);
            out
        });
        Some(SubaddressV2Keys { spend_public: d, view_public: c, spend_secret: secret })
    });
    m.zeroize();
    derived
}

/// r_n = Hs("FuegoAddlTxKey" || r || n_le64), the tx secret of output n in a
/// per-output transaction.
pub fn additional_tx_secret(tx_secret: &[u8; 32], output_index: u64) -> [u8; 32] {
    let mut pre = Vec::with_capacity(ADDITIONAL_TX_KEY_DOMAIN.len() + 40);
    pre.extend_from_slice(ADDITIONAL_TX_KEY_DOMAIN);
    pre.extend_from_slice(tx_secret);
    pre.extend_from_slice(&output_index.to_le_bytes());
    let secret = hash_to_scalar(&pre);
    pre.zeroize();
    secret
}

/// R = r*D: the tx public key that pays sub-address spend key D.
pub fn subaddress_tx_pub_key(tx_secret: &[u8; 32], subaddress_spend_public: &[u8; 32]) -> Option<[u8; 32]> {
    scalarmult_no_cofactor(subaddress_spend_public, tx_secret)
}

/// The receiver's check that the tx key was built for its sub-address:
/// (b + m)*J == R.
pub fn janus_check(tx_pub_key: &[u8; 32], janus_base: &[u8; 32], subaddress_spend_secret: &[u8; 32]) -> bool {
    scalarmult_no_cofactor(janus_base, subaddress_spend_secret).map_or(false, |expected| expected == *tx_pub_key)
}

/// J = Hs("FuegoJanusFiller" || r)*G: the 0x09 key of a tx with no sub-address
/// destination (F8). Without r it cannot be told apart from a real r*G.
pub fn janus_filler(tx_secret: &[u8; 32]) -> [u8; 32] {
    let mut pre = Vec::with_capacity(JANUS_FILLER_DOMAIN.len() + 32);
    pre.extend_from_slice(JANUS_FILLER_DOMAIN);
    pre.extend_from_slice(tx_secret);
    let mut scalar = hash_to_scalar(&pre);
    let filler = secret_key_to_public_key(&scalar);
    pre.zeroize();
    scalar.zeroize();
    filler
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn vectors() -> Value {
        serde_json::from_str(include_str!("../../../test-vectors/funsa_v2_vectors.json")).unwrap()
    }

    fn key(v: &Value) -> [u8; 32] {
        hex::decode(v.as_str().unwrap()).unwrap().try_into().unwrap()
    }

    #[test]
    fn derivation_matches_fuego_suite() {
        let v = vectors();
        let a = key(&v["recipient"]["view_secret"]);
        let b = key(&v["recipient"]["spend_secret"]);
        let big_b = key(&v["recipient"]["spend_public"]);
        for sub in v["subaddresses"].as_array().unwrap() {
            let (major, minor) = (sub["major"].as_u64().unwrap() as u32, sub["minor"].as_u64().unwrap() as u32);
            let keys = derive_subaddress_v2_keys(&a, &big_b, Some(&b), major, minor).unwrap();
            assert_eq!(keys.spend_public, key(&sub["spend_public"]), "D at ({major},{minor})");
            assert_eq!(keys.view_public, key(&sub["view_public"]), "C at ({major},{minor})");
            assert_eq!(keys.spend_secret.clone().unwrap(), key(&sub["spend_secret"]), "b+m at ({major},{minor})");
            assert_eq!(secret_key_to_public_key(&keys.spend_secret.clone().unwrap()), keys.spend_public);
        }
    }

    #[test]
    fn tx_keys_match_fuego_suite() {
        let v = vectors();
        let r = key(&v["tx_secret"]);
        for (n, expected) in v["additional_tx_secrets"].as_array().unwrap().iter().enumerate() {
            assert_eq!(additional_tx_secret(&r, n as u64), key(expected), "r_{n}");
        }
        let a = key(&v["recipient"]["view_secret"]);
        let big_b = key(&v["recipient"]["spend_public"]);
        let d = derive_subaddress_v2_keys(&a, &big_b, None, 0, 1).unwrap().spend_public;
        assert_eq!(subaddress_tx_pub_key(&r, &d).unwrap(), key(&v["subaddress_tx_pub_key_0_1"]));
        assert_eq!(janus_filler(&r), key(&v["janus_filler"]));
    }

    #[test]
    fn janus_check_accepts_only_the_sub_address_tx_key() {
        let v = vectors();
        let a = key(&v["recipient"]["view_secret"]);
        let b = key(&v["recipient"]["spend_secret"]);
        let big_b = key(&v["recipient"]["spend_public"]);
        let r = key(&v["tx_secret"]);
        let sub = derive_subaddress_v2_keys(&a, &big_b, Some(&b), 0, 1).unwrap();
        let tx_key = subaddress_tx_pub_key(&r, &sub.spend_public).unwrap();
        let j = secret_key_to_public_key(&r);
        assert!(janus_check(&tx_key, &j, &sub.spend_secret.clone().unwrap()));
        // A sender who paid D with R = r*G (the linking probe) fails the check.
        assert!(!janus_check(&j, &j, &sub.spend_secret.clone().unwrap()));
        assert!(!janus_check(&tx_key, &janus_filler(&r), &sub.spend_secret.clone().unwrap()));
    }

    #[test]
    fn addresses_match_fuego_suite_and_parse_with_their_kind() {
        let v = vectors();
        for sub in v["subaddresses"].as_array().unwrap() {
            let (d, c) = (key(&sub["spend_public"]), key(&sub["view_public"]));
            for (testnet, field) in [(false, "address"), (true, "testnet_address")] {
                let text = sub[field].as_str().unwrap();
                assert_eq!(crate::make_subaddress(&d, &c, testnet).0, text);
                let parsed = crate::parse_any_address(text).unwrap();
                assert_eq!((parsed.spend_public, parsed.view_public), (d, c));
                assert!(parsed.is_subaddress);
                assert_eq!(parsed.testnet, testnet);
                assert!(crate::parse_address(text).is_none(), "standard-only parse must refuse {text}");
                assert!(!crate::is_valid_address(text));
            }
        }
        let standard = v["recipient"]["address"].as_str().unwrap();
        let parsed = crate::parse_any_address(standard).unwrap();
        assert!(!parsed.is_subaddress && !parsed.testnet);
        assert_eq!(parsed.spend_public, key(&v["recipient"]["spend_public"]));
        assert_eq!(crate::parse_address(standard), Some((parsed.spend_public, parsed.view_public)));
    }

    #[test]
    fn corrupted_addresses_are_refused() {
        let v = vectors();
        let funsa = v["subaddresses"][0]["address"].as_str().unwrap();
        let mut tampered: Vec<char> = funsa.chars().collect();
        let last = tampered.len() - 1;
        tampered[last] = if tampered[last] == '1' { '2' } else { '1' };
        let tampered: String = tampered.into_iter().collect();
        assert!(crate::parse_any_address(&tampered).is_none());
        assert!(crate::parse_any_address(&funsa[..funsa.len() - 1]).is_none());
        assert!(crate::parse_any_address("").is_none());
    }

    #[test]
    fn primary_index_and_bad_keys_are_refused() {
        let v = vectors();
        let a = key(&v["recipient"]["view_secret"]);
        let big_b = key(&v["recipient"]["spend_public"]);
        assert!(derive_subaddress_v2_keys(&a, &big_b, None, 0, 0).is_none());
        assert!(derive_subaddress_v2_keys(&[0xff; 32], &big_b, None, 0, 1).is_none());
        assert!(scalarmult_no_cofactor(&big_b, &[0xff; 32]).is_none());
    }
}
