//! The property that matters: a receipt that was not in the block cannot be
//! made to verify against that block's `receiptsRoot`.

use fuego_sdk::chain::mpt::{receipts_root, ConsensusReceipt, EMPTY_TRIE_ROOT};

fn receipt(tx_type: u8, status: u8, gas: u64, n_logs: usize) -> ConsensusReceipt {
    ConsensusReceipt {
        tx_type,
        status,
        cumulative_gas_used: gas,
        logs_bloom: vec![0u8; 256],
        logs: (0..n_logs)
            .map(|i| {
                (
                    vec![i as u8; 20],
                    vec![vec![0xaa; 32], vec![0xbb; 32]],
                    vec![0xcd; 64],
                )
            })
            .collect(),
    }
}

fn block(n: usize) -> Vec<ConsensusReceipt> {
    (0..n)
        .map(|i| receipt((i % 3) as u8, 1, 21_000 * (i as u64 + 1), i % 4))
        .collect()
}

#[test]
fn root_is_stable_for_identical_blocks() {
    assert_eq!(
        receipts_root(&block(12)).unwrap(),
        receipts_root(&block(12)).unwrap()
    );
}

#[test]
fn empty_block_is_the_empty_root() {
    assert_eq!(receipts_root(&[]).unwrap(), EMPTY_TRIE_ROOT);
}

#[test]
fn flipping_a_status_changes_the_root() {
    // A reverted transaction passed off as successful is the exact forgery
    // the old `block_hash == header.hash` check could not see.
    let good = block(8);
    let mut forged = good.clone();
    forged[3].status = 0;
    assert_ne!(
        receipts_root(&good).unwrap(),
        receipts_root(&forged).unwrap()
    );
}

#[test]
fn altering_a_log_changes_the_root() {
    let good = block(6);
    let mut forged = good.clone();
    forged[2].logs[0].2[0] ^= 0xff;
    assert_ne!(
        receipts_root(&good).unwrap(),
        receipts_root(&forged).unwrap()
    );
}

#[test]
fn reordering_receipts_changes_the_root() {
    // Index is the trie key, so order is committed to.
    let good = block(9);
    let mut swapped = good.clone();
    swapped.swap(1, 7);
    assert_ne!(
        receipts_root(&good).unwrap(),
        receipts_root(&swapped).unwrap()
    );
}

#[test]
fn dropping_or_adding_a_receipt_changes_the_root() {
    let good = block(10);
    let mut short = good.clone();
    short.pop();
    assert_ne!(
        receipts_root(&good).unwrap(),
        receipts_root(&short).unwrap()
    );

    let mut long = good.clone();
    long.push(receipt(2, 1, 999_999, 1));
    assert_ne!(receipts_root(&good).unwrap(), receipts_root(&long).unwrap());
}

#[test]
fn typed_and_legacy_receipts_encode_differently() {
    // EIP-2718: a legacy receipt is stored bare, a typed one as
    // `type || rlp(receipt)`. Encoding a typed receipt as legacy would make
    // the rebuilt root disagree with every real block after Berlin.
    let legacy = receipt(0, 1, 21_000, 1);
    let typed = receipt(2, 1, 21_000, 1);
    let le = legacy.encode();
    let te = typed.encode();
    assert_ne!(le, te);
    assert_eq!(te[0], 2, "typed receipt must carry its type byte first");
    assert_eq!(&te[1..], &le[..], "body is the same RLP under the envelope");
}

#[test]
fn block_sizes_across_the_branch_boundary() {
    // 0..=16 entries exercise the single-leaf, extension and branch paths,
    // and >127 pushes the rlp(index) key from one byte to two.
    let mut seen = std::collections::HashSet::new();
    for n in [1usize, 2, 15, 16, 17, 127, 128, 129, 260] {
        let r = receipts_root(&block(n)).unwrap();
        assert!(seen.insert(r), "root collision at n={n}");
    }
}
