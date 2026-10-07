//! Cross-branch cross-check: our owner-bound derivation vs the independently
//! generated C++ vector set on `origin/feat/owner-bound-commitment-keys`.
//!
//! That branch added wrappers (`derive_owner_bound_commit_key`,
//! `derive_owner_bound_key_image`, `match_owner_bound_commit_key`) which are
//! NOT on this branch. Its 70 vectors were produced by a C++ harness linked
//! against the production daemon sources, independently of the vectors in
//! `fuego-sdk/tests/commitment_owner_bound_vectors.rs`.
//!
//! This test deliberately calls only the primitives our branch uses --
//! `derive_public_key`, `derive_secret_key`, `generate_key_image` -- so a pass
//! proves the two implementations are byte-identical on the wire and the merge
//! conflict is structural, not cryptographic.

use fuego_crypto::ring::{
    derive_commitment_keys, derive_deposit_secret, derive_public_key, derive_secret_key,
    generate_key_image, secret_key_to_public_key, underive_public_key,
};

fn hex_to_32(s: &str) -> [u8; 32] {
    let mut out = [0u8; 32];
    hex::decode_to_slice(s, &mut out).unwrap();
    out
}

#[test]
fn our_primitives_reproduce_their_cpp_vectors() {
    let data = include_str!("data/crosscheck_ownerbound_vectors.txt");
    let mut derivation = [0u8; 32];
    let mut spend_pub = [0u8; 32];
    let mut spend_sec = [0u8; 32];
    let mut commit_key: Option<[u8; 32]> = None;
    let mut checked = 0usize;

    for line in data.lines() {
        let t: Vec<&str> = line.split_whitespace().collect();
        if t.is_empty() {
            continue;
        }
        if t[0] == "keys" {
            derivation = hex_to_32(t[1]);
            spend_pub = hex_to_32(t[2]);
            spend_sec = hex_to_32(t[3]);
            commit_key = None;
            continue;
        }

        let idx: u64 = t[1].parse().unwrap();
        let expected = hex_to_32(t[2]);

        let actual = match t[0] {
            // Our builder path: transaction_builder::owner_bound_commit_key.
            "ob_commit" => {
                let k = derive_public_key(&derivation, idx, &spend_pub);
                if k.is_some() {
                    commit_key = k;
                }
                k
            }
            "ob_keyimage" => {
                let p = commit_key.expect("commit key precedes signing vectors");
                let x = derive_secret_key(&derivation, idx, &spend_sec).unwrap();
                // The security property their wrapper enforces inline.
                assert_eq!(secret_key_to_public_key(&x), p, "{idx} spend scalar must match P");
                Some(generate_key_image(&p, &x))
            }
            "ob_spendsecret" => {
                commit_key.expect("commit key precedes signing vectors");
                Some(derive_secret_key(&derivation, idx, &spend_sec).unwrap())
            }
            // Our scanner path: underive the recipient spend key, require a
            // registered hit, then re-derive to confirm.
            "ob_match" => {
                let p = commit_key.expect("commit key precedes match vectors");
                underive_and_match(&derivation, idx, &p, &[spend_pub])
            }
            // Their protocol-owned None path must equal the legacy key exactly.
            "ob_proto" | "ob_legacy" => {
                let dep = derive_deposit_secret(&derivation, idx as u32);
                Some(derive_commitment_keys(&dep).commit_key)
            }
            "ob_amountmask" => {
                let dep = derive_deposit_secret(&derivation, idx as u32);
                Some(derive_commitment_keys(&dep).amount_mask)
            }
            other => panic!("unknown vector op {other}"),
        }
        .unwrap_or_else(|| panic!("{} index {}: returned None", t[0], idx));

        assert_eq!(actual, expected, "{} index {}", t[0], idx);
        checked += 1;
    }
    assert_eq!(checked, 70, "expected 70 per-index vectors");
}

/// Reimplementation of the scanner-side match, using only primitives on this
/// branch, so `ob_match` is a real check rather than a tautology.
fn underive_and_match(
    derivation: &[u8; 32],
    idx: u64,
    commit_key: &[u8; 32],
    registered: &[[u8; 32]],
) -> Option<[u8; 32]> {
    let candidate = underive_public_key(derivation, idx, commit_key)?;
    if !registered.iter().any(|k| *k == candidate) {
        return None;
    }
    match derive_public_key(derivation, idx, &candidate) {
        Some(verify) if verify == *commit_key => Some(candidate),
        _ => None,
    }
}