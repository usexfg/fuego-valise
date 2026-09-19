//! Minimal RLP + Merkle-Patricia Trie, enough to rebuild an Ethereum receipt
//! trie and compare its root against a block header's `receiptsRoot`.
//!
//! No external crate: an SPV check is the last place to take a dependency on
//! someone else's encoder. Everything here is the Yellow Paper's Appendix B
//! (RLP) and Appendix D (trie), with the EIP-2718 typed-receipt envelope.

use sha3::{Digest, Keccak256};

// ── RLP ────────────────────────────────────────────────────────────

/// RLP-encode a byte string.
pub fn rlp_bytes(b: &[u8]) -> Vec<u8> {
    if b.len() == 1 && b[0] < 0x80 {
        return b.to_vec();
    }
    let mut out = rlp_len_prefix(b.len(), 0x80);
    out.extend_from_slice(b);
    out
}

/// RLP-encode a list whose items are already encoded.
pub fn rlp_list(items: &[Vec<u8>]) -> Vec<u8> {
    let payload_len: usize = items.iter().map(|i| i.len()).sum();
    let mut out = rlp_len_prefix(payload_len, 0xc0);
    for i in items {
        out.extend_from_slice(i);
    }
    out
}

fn rlp_len_prefix(len: usize, offset: u8) -> Vec<u8> {
    if len < 56 {
        vec![offset + len as u8]
    } else {
        let be = len.to_be_bytes();
        let first = be.iter().position(|&b| b != 0).unwrap_or(be.len() - 1);
        let sig = &be[first..];
        let mut out = vec![offset + 55 + sig.len() as u8];
        out.extend_from_slice(sig);
        out
    }
}

/// RLP-encode an integer as a big-endian minimal-width byte string, per the
/// Yellow Paper's scalar rule: zero encodes as the empty string.
pub fn rlp_uint(v: u64) -> Vec<u8> {
    if v == 0 {
        return rlp_bytes(&[]);
    }
    let be = v.to_be_bytes();
    let first = be.iter().position(|&b| b != 0).unwrap();
    rlp_bytes(&be[first..])
}

pub fn keccak(data: &[u8]) -> [u8; 32] {
    let mut h = Keccak256::new();
    h.update(data);
    let out = h.finalize();
    let mut r = [0u8; 32];
    r.copy_from_slice(&out);
    r
}

/// Root of an empty trie: `keccak(rlp(""))`.
pub const EMPTY_TRIE_ROOT: [u8; 32] = [
    0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6, 0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
    0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0, 0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21,
];

// ── Trie ───────────────────────────────────────────────────────────

fn to_nibbles(key: &[u8]) -> Vec<u8> {
    let mut n = Vec::with_capacity(key.len() * 2);
    for b in key {
        n.push(b >> 4);
        n.push(b & 0x0f);
    }
    n
}

/// Hex-prefix encoding (Appendix C). `terminator` marks a leaf.
fn hex_prefix(nibbles: &[u8], terminator: bool) -> Vec<u8> {
    let mut flag = if terminator { 2u8 } else { 0u8 };
    let odd = nibbles.len() % 2 == 1;
    if odd {
        flag += 1;
    }
    let mut out = Vec::with_capacity(nibbles.len() / 2 + 1);
    // First byte carries the flag, plus the leading nibble when the path has
    // an odd length (that is what the odd flag is for).
    let mut i = if odd {
        out.push((flag << 4) | nibbles[0]);
        1
    } else {
        out.push(flag << 4);
        0
    };
    // The remainder is always an even count, so pairs never run off the end.
    while i + 1 < nibbles.len() + 1 && i < nibbles.len() {
        out.push((nibbles[i] << 4) | nibbles[i + 1]);
        i += 2;
    }
    out
}

/// A node's reference: inlined when its encoding is under 32 bytes, else its
/// keccak hash. This is what makes a trie root a commitment.
fn node_ref(encoded: &[u8]) -> Vec<u8> {
    if encoded.len() < 32 {
        encoded.to_vec()
    } else {
        rlp_bytes(&keccak(encoded))
    }
}

/// Build the trie over `entries` and return the encoded root node.
/// `entries` must be sorted by key and free of duplicates.
fn build(entries: &[(Vec<u8>, Vec<u8>)], depth: usize) -> Vec<u8> {
    debug_assert!(!entries.is_empty());

    if entries.len() == 1 {
        let (k, v) = &entries[0];
        let path = &to_nibbles(k)[depth..];
        return rlp_list(&[rlp_bytes(&hex_prefix(path, true)), rlp_bytes(v)]);
    }

    // Longest nibble prefix shared by every remaining key, past `depth`.
    let first = to_nibbles(&entries[0].0);
    let mut shared = first.len() - depth;
    for (k, _) in &entries[1..] {
        let n = to_nibbles(k);
        let mut i = 0;
        while i < shared && depth + i < n.len() && first[depth + i] == n[depth + i] {
            i += 1;
        }
        shared = i;
    }

    if shared > 0 {
        // Extension node over the shared path.
        let path = &first[depth..depth + shared];
        let child = build(entries, depth + shared);
        return rlp_list(&[rlp_bytes(&hex_prefix(path, false)), node_ref(&child)]);
    }

    // Branch: one slot per nibble, plus a value slot for a key that ends here.
    let mut slots: Vec<Vec<u8>> = vec![rlp_bytes(&[]); 17];
    let mut i = 0;
    while i < entries.len() {
        let n = to_nibbles(&entries[i].0);
        if n.len() == depth {
            // Key terminates at this branch — its value takes slot 16.
            slots[16] = rlp_bytes(&entries[i].1);
            i += 1;
            continue;
        }
        let nib = n[depth] as usize;
        let start = i;
        while i < entries.len() {
            let ni = to_nibbles(&entries[i].0);
            if ni.len() == depth || ni[depth] as usize != nib {
                break;
            }
            i += 1;
        }
        let child = build(&entries[start..i], depth + 1);
        slots[nib] = node_ref(&child);
    }
    rlp_list(&slots)
}

/// Root hash of a trie holding `entries`.
///
/// Duplicate keys are a programming error and are rejected rather than
/// silently collapsed — in a receipt trie they would mean a malformed block.
pub fn trie_root(mut entries: Vec<(Vec<u8>, Vec<u8>)>) -> Result<[u8; 32], String> {
    if entries.is_empty() {
        return Ok(EMPTY_TRIE_ROOT);
    }
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    for w in entries.windows(2) {
        if w[0].0 == w[1].0 {
            return Err("duplicate key in trie".into());
        }
    }
    let root = build(&entries, 0);
    Ok(keccak(&root))
}

// ── Receipt encoding (EIP-2718) ────────────────────────────────────

/// A consensus receipt as it appears in the receipt trie.
#[derive(Debug, Clone)]
pub struct ConsensusReceipt {
    /// EIP-2718 transaction type. 0 is a legacy receipt, which is stored bare;
    /// any other type is stored as `type || rlp(receipt)`.
    pub tx_type: u8,
    pub status: u8,
    pub cumulative_gas_used: u64,
    pub logs_bloom: Vec<u8>,
    /// (address, topics, data) per log, in order.
    pub logs: Vec<(Vec<u8>, Vec<Vec<u8>>, Vec<u8>)>,
}

impl ConsensusReceipt {
    /// The value stored in the trie for this receipt.
    pub fn encode(&self) -> Vec<u8> {
        let logs: Vec<Vec<u8>> = self
            .logs
            .iter()
            .map(|(addr, topics, data)| {
                let t: Vec<Vec<u8>> = topics.iter().map(|x| rlp_bytes(x)).collect();
                rlp_list(&[rlp_bytes(addr), rlp_list(&t), rlp_bytes(data)])
            })
            .collect();
        let body = rlp_list(&[
            rlp_uint(self.status as u64),
            rlp_uint(self.cumulative_gas_used),
            rlp_bytes(&self.logs_bloom),
            rlp_list(&logs),
        ]);
        if self.tx_type == 0 {
            body
        } else {
            let mut out = vec![self.tx_type];
            out.extend_from_slice(&body);
            out
        }
    }
}

/// Rebuild a block's receipt trie root from its receipts, in index order.
///
/// The trie key for index `i` is `rlp(i)` — the scalar encoding, so index 0
/// keys on the empty string.
pub fn receipts_root(receipts: &[ConsensusReceipt]) -> Result<[u8; 32], String> {
    let entries: Vec<(Vec<u8>, Vec<u8>)> = receipts
        .iter()
        .enumerate()
        .map(|(i, r)| (rlp_uint(i as u64), r.encode()))
        .collect();
    trie_root(entries)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hx(h: &str) -> Vec<u8> {
        hex::decode(h).unwrap()
    }

    #[test]
    fn rlp_matches_the_yellow_paper_examples() {
        assert_eq!(rlp_bytes(b"dog"), hx("83646f67"));
        assert_eq!(rlp_bytes(&[]), hx("80"));
        assert_eq!(rlp_bytes(&[0x00]), hx("00"));
        assert_eq!(rlp_bytes(&[0x0f]), hx("0f"));
        assert_eq!(rlp_bytes(&[0x04, 0x00]), hx("820400"));
        assert_eq!(rlp_list(&[]), hx("c0"));
        assert_eq!(
            rlp_list(&[rlp_bytes(b"cat"), rlp_bytes(b"dog")]),
            hx("c88363617483646f67")
        );
        // 56 bytes crosses into the long-form prefix.
        let long = vec![b'a'; 56];
        assert_eq!(rlp_bytes(&long)[0..2], hx("b838")[..]);
        // Scalars: zero is the empty string, not 0x00.
        assert_eq!(rlp_uint(0), hx("80"));
        assert_eq!(rlp_uint(1), hx("01"));
        assert_eq!(rlp_uint(1024), hx("820400"));
    }

    #[test]
    fn empty_trie_root_is_the_known_constant() {
        assert_eq!(trie_root(vec![]).unwrap(), EMPTY_TRIE_ROOT);
        assert_eq!(keccak(&rlp_bytes(&[])), EMPTY_TRIE_ROOT);
    }

    #[test]
    fn single_leaf_root_is_hand_checkable() {
        // key 0x01 -> nibbles [0, 1]; even-length leaf, so hex-prefix is
        // 0x20 0x01. Node = rlp([ 0x2001, 0x02 ]) = c4 82 20 01 02.
        let node = hx("c4822001") // list header + the 2-byte hp string
            .into_iter()
            .chain(hx("02"))
            .collect::<Vec<u8>>();
        assert_eq!(
            rlp_list(&[rlp_bytes(&hex_prefix(&[0, 1], true)), rlp_bytes(&[0x02])]),
            node
        );
        assert_eq!(trie_root(vec![(vec![0x01], vec![0x02])]).unwrap(), keccak(&node));
    }

    #[test]
    fn hex_prefix_matches_appendix_c() {
        // even extension: flag 0, leading zero nibble
        assert_eq!(hex_prefix(&[1, 2, 3, 4], false), hx("001234"));
        // odd extension: flag 1, first nibble folded into the flag byte
        assert_eq!(hex_prefix(&[1, 2, 3], false), hx("1123"));
        // even leaf: flag 2
        assert_eq!(hex_prefix(&[1, 2, 3, 4], true), hx("201234"));
        // odd leaf: flag 3
        assert_eq!(hex_prefix(&[1, 2, 3], true), hx("3123"));
        // empty path is even, flag only
        assert_eq!(hex_prefix(&[], false), hx("00"));
        assert_eq!(hex_prefix(&[], true), hx("20"));
    }

    #[test]
    fn known_ethereum_trie_vector() {
        // Classic `trietest.json` case.
        let root = trie_root(vec![
            (b"doe".to_vec(), b"reindeer".to_vec()),
            (b"dog".to_vec(), b"puppy".to_vec()),
            (b"dogglesworth".to_vec(), b"cat".to_vec()),
        ])
        .unwrap();
        assert_eq!(
            hex::encode(root),
            "8aad789dff2f538bca5d8ea56e8abe10f4c7ba3a5dea95fea4cd6e7c3a1168d3"
        );
    }

    #[test]
    fn duplicate_keys_are_rejected() {
        let r = trie_root(vec![(vec![1], vec![1]), (vec![1], vec![2])]);
        assert!(r.is_err());
    }

    #[test]
    fn empty_receipt_list_is_the_empty_root() {
        assert_eq!(receipts_root(&[]).unwrap(), EMPTY_TRIE_ROOT);
    }

}
