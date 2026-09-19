//! Cross-check the trie against an independent implementation.
//!
//! `tests/mpt_cases.json` was produced by a separate Python implementation
//! written from the spec (Yellow Paper appendices B/C/D), not ported from this
//! code. It covers random key/value sets — including values either side of the
//! 32-byte inline/hash boundary, branch nodes carrying a value, and the dense
//! `rlp(index)` key sets a receipt trie actually uses.
//!
//! The same Python reference reproduces the published `doe/dog/dogglesworth`
//! root, so it is anchored to a known-good value rather than to itself.

use fuego_sdk::chain::mpt::trie_root;
use serde::Deserialize;

#[derive(Deserialize)]
struct Case {
    entries: Vec<Vec<String>>,
    root: String,
}

#[test]
fn matches_independent_reference_on_every_case() {
    let raw = include_str!("mpt_cases.json");
    let cases: Vec<Case> = serde_json::from_str(raw).expect("vectors parse");
    assert!(cases.len() >= 300, "expected a broad corpus, got {}", cases.len());

    for (i, c) in cases.iter().enumerate() {
        let entries: Vec<(Vec<u8>, Vec<u8>)> = c
            .entries
            .iter()
            .map(|kv| {
                (
                    hex::decode(&kv[0]).expect("key hex"),
                    hex::decode(&kv[1]).expect("value hex"),
                )
            })
            .collect();
        let got = trie_root(entries).expect("root");
        assert_eq!(
            hex::encode(got),
            c.root,
            "case {i} ({} entries) diverged from the reference",
            c.entries.len()
        );
    }
}
