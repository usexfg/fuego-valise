//! Cross-language vectors for owner-bound commitment derivation.
//!
//! `data/ownerbound_vectors.txt` is produced by a C++ harness linked against the
//! production daemon sources (TransactionExtra.cpp / crypto.cpp from
//! /Users/aejt/xfgo). Every value here is compared byte-for-byte, so a
//! divergence between the Rust SDK and the C++ wallet is a test failure rather
//! than funds sent to an output the recipient's wallet cannot find.

use fuego_crypto::ring::{
    derive_commitment_keys, derive_commitment_output_key, derive_deposit_secret,
    derive_owner_bound_commit_key, derive_owner_bound_key_image, match_owner_bound_commit_key,
};

fn hex_to_32(s: &str) -> [u8; 32] {
    let v: Vec<u8> = (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect();
    let mut a = [0u8; 32];
    a.copy_from_slice(&v);
    a
}

/// Every guide index (0, 1, 127, 128, 1000000) across both deterministic key
/// pairs, verified against the C++ output line by line.
#[test]
fn ownerbound_all_indices() {
    let data = include_str!("data/ownerbound_vectors.txt");
    let mut derivation = [0u8; 32];
    let mut spend_pub = [0u8; 32];
    let mut spend_sec = [0u8; 32];
    let mut commit_key = None;
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
            continue;
        }

        let idx: u64 = t[1].parse().unwrap();
        let expected = hex_to_32(t[2]);

        let actual = match t[0] {
            "ob_commit" => {
                let k = derive_owner_bound_commit_key(&derivation, idx, &spend_pub);
                if k.is_some() {
                    commit_key = k;
                }
                k
            }
            // The signing ops take the *commit key*, not the expected output.
            "ob_keyimage" => {
                derive_owner_bound_key_image(&derivation, idx, &commit_key.expect("commit key precedes signing vectors"), &spend_sec)
                    .map(|(_, ki)| ki)
            }
            "ob_spendsecret" => {
                derive_owner_bound_key_image(&derivation, idx, &commit_key.expect("commit key precedes signing vectors"), &spend_sec)
                    .map(|(s, _)| s)
            }
            "ob_match" => match_owner_bound_commit_key(&derivation, idx, &commit_key.expect("commit key precedes match vectors"), &[spend_pub]),
            "ob_proto" => derive_commitment_output_key(&derivation, idx, None),
            "ob_legacy" => {
                let dep = derive_deposit_secret(&derivation, idx as u32);
                Some(derive_commitment_keys(&dep).commit_key)
            }
            "ob_amountmask" => {
                let dep = derive_deposit_secret(&derivation, idx as u32);
                Some(derive_commitment_keys(&dep).amount_mask)
            }
            other => panic!("unknown vector op {}", other),
        }
        .unwrap_or_else(|| panic!("{} index {}: rust returned None", t[0], idx));

        assert_eq!(actual, expected, "{} index {}", t[0], idx);
        checked += 1;
    }
    assert_eq!(checked, 70, "expected 70 per-index vectors");
}

/// The two derivations must be distinguishable, and the protocol-owned path must
/// reproduce the legacy key exactly. Otherwise a scanner could not tell them
/// apart and an owner-bound payment could be misattributed.
#[test]
fn ownerbound_distinct_from_legacy() {
    let data = include_str!("data/ownerbound_vectors.txt");
    let mut derivation = [0u8; 32];
    let mut spend_pub = [0u8; 32];

    for line in data.lines() {
        let t: Vec<&str> = line.split_whitespace().collect();
        if t.is_empty() {
            continue;
        }
        if t[0] == "keys" {
            derivation = hex_to_32(t[1]);
            spend_pub = hex_to_32(t[2]);
            continue;
        }
        if t[0] != "ob_commit" {
            continue;
        }
        let idx: u64 = t[1].parse().unwrap();
        let commit = derive_owner_bound_commit_key(&derivation, idx, &spend_pub).unwrap();
        let dep = derive_deposit_secret(&derivation, idx as u32);
        let legacy = derive_commitment_keys(&dep);
        assert_ne!(
            legacy.commit_key, commit,
            "index {}: owner-bound must differ from legacy or a scanner cannot tell them apart",
            idx
        );
        // The null-recipient (protocol-owned) path must equal legacy exactly.
        assert_eq!(
            derive_commitment_output_key(&derivation, idx, None).unwrap(),
            legacy.commit_key,
            "index {}: protocol-owned path must reproduce the legacy key",
            idx
        );
        // The legacy key must not match as an owner-bound output for this key.
        assert!(match_owner_bound_commit_key(&derivation, idx, &legacy.commit_key, &[spend_pub]).is_none());
    }
}

/// The security property itself: an unrelated spend secret must not produce a
/// key image for an owner-bound output.
#[test]
fn wrong_spend_secret_cannot_sign() {
    let data = include_str!("data/ownerbound_vectors.txt");
    let first = data.lines().find(|l| l.starts_with("keys")).unwrap();
    let t: Vec<&str> = first.split_whitespace().collect();
    let d = hex_to_32(t[1]);
    let spend_pub = hex_to_32(t[2]);

    let commit = derive_owner_bound_commit_key(&d, 0, &spend_pub).unwrap();

    let mut wrong = [0u8; 32];
    wrong[31] &= 0x0F;
    wrong[0] |= 0x40;
    wrong[0] ^= 0x11;
    assert!(derive_owner_bound_key_image(&d, 0, &commit, &wrong).is_none());

    // A non-canonical scalar is rejected rather than panicking.
    let noncanonical = [0xFFu8; 32];
    assert!(derive_owner_bound_key_image(&d, 0, &commit, &noncanonical).is_none());

    // An unregistered key is not claimed by the scanner.
    assert!(match_owner_bound_commit_key(&d, 0, &commit, &[[0xAB; 32]]).is_none());
}
