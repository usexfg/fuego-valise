//! End-to-end builder test: a complete transaction (selection, decoys,
//! output derivation, signing, serialization) built with a deterministic
//! RNG. The produced per-input ring artifacts were verified by the C++
//! daemon's check_ring_signature via the cross-language harness; the test
//! pins the tx hash so CI catches any drift.

use fuego_crypto::ref10::{ge_p3_tobytes, ge_scalarmult_base, random_scalar, GeP3};
use fuego_sdk::serialization::serialize_tx;
use fuego_sdk::transaction_builder::{
    build_transaction, select_inputs, BuildDestination, DecoyEntry, SpendableOutput,
    DEFAULT_DUST_THRESHOLD, MINIMUM_FEE,
};
use rand::rngs::StdRng;
use rand::SeedableRng;


/// The sending wallet for these builds: only its view secret matters, since
/// none of them pays a sub-address.
fn sender_for(view_secret: &[u8; 32]) -> fuego_sdk::transaction_builder::TxSender {
    let view_public = fuego_crypto::ring::secret_key_to_public_key(view_secret);
    let keys = fuego_sdk::scanner::WalletKeys {
        spend_secret: *view_secret,
        spend_public: view_public,
        view_secret: *view_secret,
        view_public,
    };
    fuego_sdk::transaction_builder::TxSender::new(&keys, false)
}

fn make_output(
    amount: u64,
    secret: [u8; 32],
    global_index: u32,
    output_position: u32,
) -> SpendableOutput {
    let mut p = GeP3::default();
    ge_scalarmult_base(&mut p, &secret);
    let mut output_key = [0u8; 32];
    ge_p3_tobytes(&mut output_key, &p);
    let key_image = fuego_crypto::generate_key_image(&fuego_crypto::PublicKey(output_key), &secret);
    SpendableOutput {
        amount,
        output_key,
        secret_key: secret,
        key_image: key_image.0,
        global_index,
        tx_hash: [0x11; 32],
        output_position,
    }
}

fn make_decoy(global_index: u32, tag: u8) -> DecoyEntry {
    // decoy pubkeys: valid curve points via scalarmult_base of a fixed scalar
    let secret = {
        let mut s = [0u8; 32];
        s[0] = tag;
        s[31] = 7;
        s
    };
    let mut p = GeP3::default();
    ge_scalarmult_base(&mut p, &secret);
    let mut out_key = [0u8; 32];
    ge_p3_tobytes(&mut out_key, &p);
    DecoyEntry {
        global_index,
        out_key,
    }
}

#[test]
fn full_transaction_build() {
    let mut rng = StdRng::seed_from_u64(0xBEEF_CAFE_1234_5678);

    // Wallet keys (arbitrary but fixed).
    let spend_secret = {
        let mut s = [0u8; 32];
        s[0] = 1;
        s
    };
    let view_secret = {
        let mut s = [0u8; 32];
        s[0] = 2;
        s
    };
    let mut spend_pub_p = GeP3::default();
    ge_scalarmult_base(&mut spend_pub_p, &spend_secret);
    let mut spend_pub = [0u8; 32];
    ge_p3_tobytes(&mut spend_pub, &spend_pub_p);
    let mut view_pub_p = GeP3::default();
    ge_scalarmult_base(&mut view_pub_p, &view_secret);
    let mut view_pub = [0u8; 32];
    ge_p3_tobytes(&mut view_pub, &view_pub_p);

    // Available outputs: 10, 200, 5000, 20000, 5000000.
    let available: Vec<SpendableOutput> = vec![
        make_output(10, random_scalar(&mut rng), 100, 0),
        make_output(200, random_scalar(&mut rng), 101, 0),
        make_output(5000, random_scalar(&mut rng), 102, 0),
        make_output(20000, random_scalar(&mut rng), 103, 0),
        make_output(5_000_000, random_scalar(&mut rng), 104, 0),
    ];

    let amount = 1_000_000;
    let fee = MINIMUM_FEE;
    let (selected, found) = select_inputs(&available, amount + fee, DEFAULT_DUST_THRESHOLD, &mut rng);
    assert!(found >= amount + fee, "selection must cover amount+fee");

    // Recipient keys.
    let recv_secret = {
        let mut s = [0u8; 32];
        s[0] = 3;
        s
    };
    let mut recv_p = GeP3::default();
    ge_scalarmult_base(&mut recv_p, &recv_secret);
    let mut recv_spend = [0u8; 32];
    ge_p3_tobytes(&mut recv_spend, &recv_p);
    let recv_view = view_pub; // same view key for the recipient in this test

    let change = found - amount - fee;
    let (change_chunks, dust) = fuego_sdk::transaction_builder::decompose_change(
        change,
        DEFAULT_DUST_THRESHOLD,
    );

    let mut dests = vec![BuildDestination {
        amount,
        spend_pub: recv_spend,
        view_pub: recv_view,
        is_subaddress: false,
    }];
    for chunk in change_chunks {
        dests.push(BuildDestination {
            amount: chunk,
            spend_pub,
            view_pub,
            is_subaddress: false,
        });
    }
    if dust > 0 {
        dests.push(BuildDestination {
            amount: dust,
            spend_pub,
            view_pub,
            is_subaddress: false,
        });
    }

    // Decoys: 4 per input, global indices around the real one.
    let mixin = 4;
    let mut decoys = Vec::new();
    for input in &selected {
        let mut group = Vec::new();
        for k in 0..mixin {
            let idx = input.global_index + 1 + k as u32;
            group.push(make_decoy(idx, (input.global_index % 250) as u8 + k as u8));
        }
        decoys.push(group);
    }

    let built = build_transaction(&selected, &dests, &sender_for(&view_secret), fee, mixin, &decoys, 0, &[], &mut rng)
        .expect("build_transaction");

    // Structural invariants.
    assert_eq!(built.tx.prefix.version, 1);
    assert_eq!(built.tx.prefix.inputs.len(), selected.len());
    let out_sum: u64 = built.tx.prefix.outputs.iter().map(|o| o.amount).sum();
    let in_sum: u64 = built.tx.prefix.inputs.iter().map(|i| i.amount()).sum();
    assert_eq!(in_sum - out_sum, fee);
    assert_eq!(built.serialized, serialize_tx(&built.tx));
    assert_eq!(
        built.tx_hash,
        fuego_crypto::cn_fast_hash(&built.serialized)
    );

    // The tx hash and every ring signature of this exact transaction were
    // verified against the C++ daemon verification path via the
    // cross-language harness (parse + check_ring_signature). Pin the hash.
    // Re-pinned when r stopped being seeded with the public view key.
    assert_eq!(
        hex::encode(built.tx_hash),
        "d8dee9c29622066025ffa15bfa2f738d93ad7a166ad948a2e1a72826f40f0e96"
    );

    println!("TXHEX {}", hex::encode(&built.serialized));

    // Print the per-input ring artifacts for the C++ harness.
    for (i, input) in built.tx.prefix.inputs.iter().enumerate() {
        let (offsets, image) = match input {
            fuego_sdk::serialization::TxInput::Key(k) => (&k.offsets, &k.key_image),
            fuego_sdk::serialization::TxInput::CommitmentSpend(c) => (&c.offsets, &c.key_image),
        };
        // reconstruct the ring order used at signing time: decoys + real sorted by index
        let mut ring: Vec<(u32, [u8; 32])> = decoys[i]
            .iter()
            .map(|d| (d.global_index, d.out_key))
            .collect();
        ring.push((offsets[0], selected[i].output_key));
        ring.sort_by_key(|(idx, _)| *idx);
        println!("RING {} {} {}", i, hex::encode(built.prefix_hash), hex::encode(image));
        for (idx, key) in ring {
            println!("  {} {}", idx, hex::encode(key));
        }
        let flat: Vec<u8> = built.tx.signatures[i].iter().flatten().cloned().collect();
        println!("SIG {} {}", i, hex::encode(flat));
    }
}
