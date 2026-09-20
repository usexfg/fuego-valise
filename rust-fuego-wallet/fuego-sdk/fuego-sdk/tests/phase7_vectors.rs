//! Phase 7 tests: AFK locks, HEAT mint, CDs, commitment spends.
//! Cross-language: the C++ harness verified the adaptor signature scheme
//! (check_adaptor_signature) and the transaction serialization
//! (parseAndValidateTransactionFromBinaryArray) for these builders.

use fuego_crypto::ref10::{ge_p3_tobytes, ge_scalarmult_base, random_scalar, GeP3};
use fuego_crypto::ring::{
    adapt_signature, check_adaptor_signature, derive_commitment_keys, derive_deposit_secret,
    extract_adaptor_secret, generate_afk_lock_data,
};
use fuego_sdk::serialization::{serialize_tx, OutputTarget, TxInput, HEAT_TERM};
use fuego_sdk::transaction_builder::{
    build_commitment_spend_transaction, build_mint_transaction, decompose_heat_into_bills,
    BuildCommitmentDestination, BuildDestination, CommitmentDeposit, DecoyEntry, SpendableOutput,
    MINIMUM_FEE,
};
use rand::rngs::StdRng;
use rand::SeedableRng;

fn make_output(amount: u64, secret: [u8; 32], global_index: u32) -> SpendableOutput {
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
        tx_hash: [0x22; 32],
        output_position: 0,
    }
}

fn make_decoy(global_index: u32, tag: u8) -> DecoyEntry {
    let mut s = [0u8; 32];
    s[0] = tag;
    s[31] = 9;
    let mut p = GeP3::default();
    ge_scalarmult_base(&mut p, &s);
    let mut out_key = [0u8; 32];
    ge_p3_tobytes(&mut out_key, &p);
    DecoyEntry {
        global_index,
        out_key,
    }
}

fn wallet_keys(rng: &mut StdRng) -> (([u8; 32], [u8; 32]), ([u8; 32], [u8; 32])) {
    let spend = random_scalar(rng);
    let view = random_scalar(rng);
    let mut sp = GeP3::default();
    ge_scalarmult_base(&mut sp, &spend);
    let mut spend_pub = [0u8; 32];
    ge_p3_tobytes(&mut spend_pub, &sp);
    let mut vp = GeP3::default();
    ge_scalarmult_base(&mut vp, &view);
    let mut view_pub = [0u8; 32];
    ge_p3_tobytes(&mut view_pub, &vp);
    ((spend, spend_pub), (view, view_pub))
}

// ---------------------------------------------------------------- adaptors

#[test]
fn adaptor_scheme_matches_cpp_semantics() {
    // C++ harness vectors (adaptvec mode): fixed pub/secret, C++ randomness.
    // These assert OUR checker agrees with the C++ checker.
    let prefix = [0u8; 32];
    let mut sec = [0u8; 32];
    for i in 0..32 {
        sec[i] = 0x11 + i as u8;
    }
    let mut p = GeP3::default();
    ge_scalarmult_base(&mut p, &sec);
    let mut pub_key = [0u8; 32];
    ge_p3_tobytes(&mut pub_key, &p);

    // C++-generated pre-sig (ADAPT_POINT / ADAPT_PRESIG from the harness).
    let point: [u8; 32] =
        hex::decode("49006ebbeeeb565b2f1adc8b866c93a39a00d7e739804f0f1b10705fe991d93a")
            .unwrap()
            .try_into()
            .unwrap();
    let presig: [u8; 64] = hex::decode(
        "5255725eea0d0924ae7b0f0e4d7de5ef0445c23c4afab91391e662cc9eb3f904\
         5cd4ba6535510fb3abafe05c3286091507782199f582caff1669167e08168008",
    )
    .unwrap()
    .try_into()
    .unwrap();
    assert!(
        check_adaptor_signature(&prefix, &pub_key, &point, &presig),
        "C++ pre-sig must verify under our checker"
    );

    // The completed signature (r = r_hat + t) must NOT verify under
    // check_adaptor_signature — matching the C++ harness ADAPT_CHECK_COMPLETED=0.
    let sec_scalar: [u8; 32] = hex::decode(
        "86eca992b6fb3e87935a5be3998df3c2ac1a09bd059489918ec946923b3b8e0f",
    )
    .unwrap()
    .try_into()
    .unwrap();
    let completed = adapt_signature(&presig, &sec_scalar);
    assert!(
        !check_adaptor_signature(&prefix, &pub_key, &point, &completed),
        "completed sig must fail the pre-sig checker (C++ semantics)"
    );

    // Extraction roundtrip: t = r - r_hat recovers the C++ secret.
    let extracted = extract_adaptor_secret(&presig, &completed).unwrap();
    assert_eq!(extracted, sec_scalar);
}

#[test]
fn adaptor_generation_self_consistent() {
    let mut rng = StdRng::seed_from_u64(0xAF0C_AF0C_AF0C_AF0C);
    let ((spend_sec, spend_pub), _) = wallet_keys(&mut rng);
    let prefix = [0u8; 32];

    let (secret, point, presig) =
        generate_afk_lock_data(&prefix, &spend_pub, &spend_sec, &mut rng).unwrap();
    assert!(
        check_adaptor_signature(&prefix, &spend_pub, &point, &presig),
        "generated pre-sig must verify"
    );

    let completed = adapt_signature(&presig, &secret);
    let extracted = extract_adaptor_secret(&presig, &completed).unwrap();
    assert_eq!(extracted, secret);

    // Tampered pre-sig must fail.
    let mut tampered = presig;
    tampered[10] ^= 0x01;
    assert!(!check_adaptor_signature(&prefix, &spend_pub, &point, &tampered));
}

// ---------------------------------------------------------------- HEAT mint

#[test]
fn heat_mint_transaction() {
    let mut rng = StdRng::seed_from_u64(0xFEED_FACE_CAFE_BEEF);
    let ((spend_sec, spend_pub), (view_sec, view_pub)) = wallet_keys(&mut rng);

    let inputs = vec![
        make_output(5_000_000, random_scalar(&mut rng), 100),
        make_output(2_000_000, random_scalar(&mut rng), 101),
    ];
    let xfg_burned = 3_000_000u64;
    let heat_minted = 1_500_000_000u64; // 150 HEAT
    let fee = MINIMUM_FEE;
    let found: u64 = inputs.iter().map(|i| i.amount).sum();
    let change = found - xfg_burned - fee;

    let mixin = 2;
    let decoys: Vec<Vec<DecoyEntry>> = inputs
        .iter()
        .map(|i| {
            (0..mixin)
                .map(|k| make_decoy(i.global_index + 1 + k as u32, (i.global_index % 200) as u8 + k as u8))
                .collect()
        })
        .collect();

    let built = build_mint_transaction(
        &inputs,
        &decoys,
        mixin,
        xfg_burned,
        heat_minted,
        7_777,
        change,
        &view_pub,
        (&spend_pub, &view_pub),
        fee,
        &mut rng,
    )
    .unwrap();

    // Structure.
    assert_eq!(built.tx.prefix.version, 2);
    let bills = decompose_heat_into_bills(heat_minted);
    let heat_sum: u64 = built
        .tx
        .prefix
        .outputs
        .iter()
        .filter_map(|o| match &o.target {
            OutputTarget::Commitment(c) if c.term == HEAT_TERM => Some(o.amount),
            _ => None,
        })
        .sum();
    assert_eq!(heat_sum, heat_minted, "minted HEAT must equal outputs");
    assert_eq!(heat_sum, bills.iter().sum::<u64>());

    // XFG conservation (daemon per-asset check): in.xfg >= out.xfg + fee,
    // the difference is the burn that mints the HEAT outputs.
    let xfg_out: u64 = built
        .tx
        .prefix
        .outputs
        .iter()
        .filter_map(|o| match &o.target {
            OutputTarget::Key(_) => Some(o.amount),
            _ => None,
        })
        .sum();
    let in_sum: u64 = built.tx.prefix.inputs.iter().map(|i| i.amount()).sum();
    assert!(in_sum >= xfg_out + fee, "XFG must cover outputs + fee");
    assert_eq!(in_sum - xfg_out - fee, xfg_burned, "burn must be exact");

    // Auth extra: 0xF5 || xfgBurned LE || heatMinted LE || priceHeight LE.
    let extra = &built.tx.prefix.extra;
    let f5 = extra.iter().position(|b| *b == 0xF5).expect("auth tag");
    assert_eq!(&extra[f5 + 1..f5 + 9], &xfg_burned.to_le_bytes());
    assert_eq!(&extra[f5 + 9..f5 + 17], &heat_minted.to_le_bytes());
    assert_eq!(&extra[f5 + 17..f5 + 21], &7_777u32.to_le_bytes());

    // Commitment secret recovery: each HEAT output's commit key must match
    // deriveCommitmentKeys(Hs(D || outIndex)) with D = 8*(r*V).
    let pubkey_tag = extra[0];
    assert_eq!(pubkey_tag, 0x01);
    let r_bytes: [u8; 32] = extra[1..33].try_into().unwrap();
    let derivation = fuego_crypto::generate_key_derivation(
        &fuego_crypto::PublicKey(r_bytes),
        &view_sec,
    )
    .unwrap();
    let mut heat_index = 0u32;
    for output in &built.tx.prefix.outputs {
        if let OutputTarget::Commitment(c) = &output.target {
            assert_eq!(c.term, HEAT_TERM);
            let ds = derive_deposit_secret(&derivation, heat_index);
            let ck = derive_commitment_keys(&ds);
            assert_eq!(ck.commit_key, c.commit_key, "mint commit key mismatch");
            heat_index += 1;
        }
    }

    // Ring sigs self-verify.
    assert_eq!(built.tx.signatures.len(), inputs.len());
    assert_eq!(
        built.serialized,
        serialize_tx(&built.tx),
        "serialize roundtrip"
    );
    let _ = (&spend_sec, &spend_pub);
}

// ---------------------------------------------------------------- CDs

#[test]
fn commitment_spend_transaction() {
    let mut rng = StdRng::seed_from_u64(0xCDCD_CDCD_CDCD_CDCD);
    let ((spend_sec, spend_pub), (_, view_pub)) = wallet_keys(&mut rng);

    // Two finite-term deposits owned by us.
    let mut deposits = Vec::new();
    for i in 0..2u32 {
        let secret = random_scalar(&mut rng);
        let mut p = GeP3::default();
        ge_scalarmult_base(&mut p, &secret);
        let mut commit_key = [0u8; 32];
        ge_p3_tobytes(&mut commit_key, &p);
        let key_image = fuego_crypto::generate_key_image(&fuego_crypto::PublicKey(commit_key), &secret);
        deposits.push(CommitmentDeposit {
            amount: 5_000_000 + i as u64 * 1_000_000,
            commit_key,
            key_scalar: secret,
            key_image: key_image.0,
            global_index: 500 + i,
            claimed_interest: 0,
        });
    }

    let mixin = 2;
    let decoys: Vec<Vec<(u32, [u8; 32])>> = deposits
        .iter()
        .map(|d| {
            (0..mixin)
                .map(|k| {
                    let mut s = [0u8; 32];
                    s[0] = (d.global_index % 200) as u8 + k as u8;
                    s[31] = 3;
                    let mut p = GeP3::default();
                    ge_scalarmult_base(&mut p, &s);
                    let mut key = [0u8; 32];
                    ge_p3_tobytes(&mut key, &p);
                    (d.global_index + 1 + k as u32, key)
                })
                .collect()
        })
        .collect();

    let total: u64 = deposits.iter().map(|d| d.amount).sum();
    let fee = MINIMUM_FEE;
    let payout = total - fee;

    let key_dests = vec![BuildDestination {
        amount: payout,
        spend_pub,
        view_pub,
    }];

    let built = build_commitment_spend_transaction(
        &deposits,
        &decoys,
        mixin,
        &key_dests,
        &[],
        &view_pub,
        fee,
        &[],
        &mut rng,
    )
    .unwrap();

    assert_eq!(built.tx.prefix.inputs.len(), 2);
    for input in &built.tx.prefix.inputs {
        assert!(matches!(input, TxInput::CommitmentSpend(_)));
    }
    let in_sum: u64 = built.tx.prefix.inputs.iter().map(|i| i.amount()).sum();
    let out_sum: u64 = built.tx.prefix.outputs.iter().map(|o| o.amount).sum();
    assert_eq!(in_sum, out_sum + fee);
    assert_eq!(built.serialized, serialize_tx(&built.tx));

    // Verify ring signatures with our own checker.
    for (i, input) in built.tx.prefix.inputs.iter().enumerate() {
        if let TxInput::CommitmentSpend(c) = input {
            let pubs: Vec<[u8; 32]> = decoys[i]
                .iter()
                .map(|(_, k)| *k)
                .chain(std::iter::once(deposits[i].commit_key))
                .collect();
            let mut sorted = decoys[i].clone();
            sorted.push((deposits[i].global_index, deposits[i].commit_key));
            sorted.sort_by_key(|(idx, _)| *idx);
            let sorted_pubs: Vec<[u8; 32]> = sorted.iter().map(|(_, k)| *k).collect();
            assert!(
                fuego_crypto::check_ring_signature(
                    &built.prefix_hash,
                    &c.key_image,
                    &sorted_pubs,
                    &built.tx.signatures[i]
                ),
                "commitment ring sig {}",
                i
            );
            let _ = pubs;
        }
    }
    let _ = &spend_sec;
}

#[test]
fn commitment_key_derivation_vectors() {
    // deriveCommitmentKeys with a fixed secret: pinned for regression.
    let secret = [7u8; 32];
    let ck = derive_commitment_keys(&secret);
    assert_eq!(
        hex::encode(ck.key_scalar),
        "1664d64078c290ebb3d1a5969769fefc23eaafa8d914a0fbb9e9ec6c4bd10007"
    );
    let mut p = GeP3::default();
    ge_scalarmult_base(&mut p, &ck.key_scalar);
    let mut expect_pub = [0u8; 32];
    ge_p3_tobytes(&mut expect_pub, &p);
    assert_eq!(ck.commit_key, expect_pub);
    let expect_image =
        fuego_crypto::generate_key_image(&fuego_crypto::PublicKey(ck.commit_key), &ck.key_scalar);
    assert_eq!(ck.key_image, expect_image.0);

    // deposit secret derivation: Hs(D || outIndex LE32).
    let d = [9u8; 32];
    let ds = derive_deposit_secret(&d, 3);
    let mut buf = Vec::new();
    buf.extend_from_slice(&d);
    buf.extend_from_slice(&3u32.to_le_bytes());
    assert_eq!(ds, fuego_crypto::cn_fast_hash(&buf));
}

#[test]
fn print_cross_language_artifacts() {
    // Deterministic AFK pre-sig + a mint tx + a commitment-spend tx for the
    // C++ harness (checkadapt / parsetx).
    let mut rng = StdRng::seed_from_u64(0xDEAD_BEEF_1234_5678);
    let ((spend_sec, spend_pub), (view_sec, view_pub)) = wallet_keys(&mut rng);
    let prefix = [0u8; 32];
    let (secret, point, presig) =
        generate_afk_lock_data(&prefix, &spend_pub, &spend_sec, &mut rng).unwrap();
    println!("AFK_PREFIX {}", hex::encode(prefix));
    println!("AFK_PUB {}", hex::encode(spend_pub));
    println!("AFK_POINT {}", hex::encode(point));
    println!("AFK_PRESIG {}", hex::encode(presig));
    println!("AFK_SECRET {}", hex::encode(secret));

    let inputs = vec![
        make_output(5_000_000, random_scalar(&mut rng), 100),
        make_output(2_000_000, random_scalar(&mut rng), 101),
    ];
    let mixin = 2;
    let decoys: Vec<Vec<DecoyEntry>> = inputs
        .iter()
        .map(|i| {
            (0..mixin)
                .map(|k| make_decoy(i.global_index + 1 + k as u32, (i.global_index % 200) as u8 + k as u8))
                .collect()
        })
        .collect();
    let built = build_mint_transaction(
        &inputs,
        &decoys,
        mixin,
        3_000_000,
        1_500_000_000,
        7_777,
        7_000_000 - 3_000_000 - MINIMUM_FEE,
        &view_pub,
        (&spend_pub, &view_pub),
        MINIMUM_FEE,
        &mut rng,
    )
    .unwrap();
    // Regenerated when the mint auth extra gained priceHeight, which adds 4
    // bytes to the transaction and so changes its hash. The changed bytes
    // were checked against the C++ encoder directly: addHeatMintAuthToExtra
    // and add_heat_mint_auth_extra emit an identical 21-byte field for these
    // inputs. The surrounding transaction body is untouched by that change.
    assert_eq!(
        hex::encode(built.tx_hash),
        "529e1c601e0bea07a29ba143554c9290df9cf7aed945e70c5c9c689c58647926"
    );

    // Commitment-spend artifact.
    let mut deposits = Vec::new();
    for i in 0..2u32 {
        let sec = random_scalar(&mut rng);
        let mut p = GeP3::default();
        ge_scalarmult_base(&mut p, &sec);
        let mut commit_key = [0u8; 32];
        ge_p3_tobytes(&mut commit_key, &p);
        let key_image =
            fuego_crypto::generate_key_image(&fuego_crypto::PublicKey(commit_key), &sec);
        deposits.push(CommitmentDeposit {
            amount: 5_000_000 + i as u64 * 1_000_000,
            commit_key,
            key_scalar: sec,
            key_image: key_image.0,
            global_index: 500 + i,
            claimed_interest: 0,
        });
    }
    let cdecoys: Vec<Vec<(u32, [u8; 32])>> = deposits
        .iter()
        .map(|d| {
            (0..mixin)
                .map(|k| {
                    let mut s = [0u8; 32];
                    s[0] = (d.global_index % 200) as u8 + k as u8;
                    s[31] = 3;
                    let mut p = GeP3::default();
                    ge_scalarmult_base(&mut p, &s);
                    let mut key = [0u8; 32];
                    ge_p3_tobytes(&mut key, &p);
                    (d.global_index + 1 + k as u32, key)
                })
                .collect()
        })
        .collect();
    let total: u64 = deposits.iter().map(|d| d.amount).sum();
    let cs = build_commitment_spend_transaction(
        &deposits,
        &cdecoys,
        mixin,
        &[BuildDestination {
            amount: total - MINIMUM_FEE,
            spend_pub,
            view_pub,
        }],
        &[],
        &view_pub,
        MINIMUM_FEE,
        &[],
        &mut rng,
    )
    .unwrap();
    // Verified by the C++ production parser: roundtrip byte-identical.
    assert_eq!(
        hex::encode(cs.tx_hash),
        "50515b3e7784e02d4e657c52c7eb8317b6736fe15716bf04ac9ff6285e9850a4"
    );
    let _ = view_sec;
}

#[test]
fn heat_cd_transaction_structure() {
    // heat_cd: spend HEAT deposits -> CD commitment (finite term) + HEAT
    // change + treasury-fund extra.
    let mut rng = StdRng::seed_from_u64(0x5EED_CDCD_CDCD_CDCD);
    let ((_spend_sec, _spend_pub), (_, view_pub)) = wallet_keys(&mut rng);

    let mut deposits = Vec::new();
    for _ in 0..1u32 {
        let sec = random_scalar(&mut rng);
        let mut p = GeP3::default();
        ge_scalarmult_base(&mut p, &sec);
        let mut commit_key = [0u8; 32];
        ge_p3_tobytes(&mut commit_key, &p);
        let key_image =
            fuego_crypto::generate_key_image(&fuego_crypto::PublicKey(commit_key), &sec);
        deposits.push(CommitmentDeposit {
            amount: 100_000_000,
            commit_key,
            key_scalar: sec,
            key_image: key_image.0,
            global_index: 900,
            claimed_interest: 0,
        });
    }

    let amount = 50_000_000u64;
    let banking_fee = amount / 1000;
    let term_blocks = 5400u32;
    let mixin = 2;
    let decoys: Vec<Vec<(u32, [u8; 32])>> = deposits
        .iter()
        .map(|d| {
            (0..mixin)
                .map(|k| {
                    let mut s = [0u8; 32];
                    s[0] = 0x30 + k as u8;
                    s[31] = 4;
                    let mut p = GeP3::default();
                    ge_scalarmult_base(&mut p, &s);
                    let mut key = [0u8; 32];
                    ge_p3_tobytes(&mut key, &p);
                    (d.global_index + 1 + k as u32, key)
                })
                .collect()
        })
        .collect();

    let change = deposits[0].amount - amount - banking_fee - MINIMUM_FEE;
    let mut extra = Vec::new();
    fuego_sdk::serialization::add_treasury_fund_extra(&mut extra, 1, banking_fee);

    let built = build_commitment_spend_transaction(
        &deposits,
        &decoys,
        mixin,
        &[],
        &[
            BuildCommitmentDestination { amount, term: term_blocks, view_pub: None },
            BuildCommitmentDestination { amount: change, term: HEAT_TERM, view_pub: None },
        ],
        &view_pub,
        MINIMUM_FEE,
        &extra,
        &mut rng,
    )
    .unwrap();

    assert_eq!(built.tx.prefix.version, 2);
    let in_sum: u64 = built.tx.prefix.inputs.iter().map(|i| i.amount()).sum();
    // inputs = CD + change + treasury fee (burned, not an output)
    let out_sum: u64 = built.tx.prefix.outputs.iter().map(|o| o.amount).sum();
    assert_eq!(in_sum, out_sum + banking_fee + MINIMUM_FEE);

    // Commitment output order: CD first (index 0), HEAT change second.
    let cds: Vec<&fuego_sdk::serialization::CommitmentOutputTarget> = built
        .tx
        .prefix
        .outputs
        .iter()
        .filter_map(|o| match &o.target {
            OutputTarget::Commitment(c) => Some(c),
            _ => None,
        })
        .collect();
    assert_eq!(cds.len(), 2);
    assert_eq!(cds[0].term, term_blocks);
    assert_eq!(cds[1].term, HEAT_TERM);

    // Treasury fund extra: 0xFF || asset(1) || amount LE64.
    let pos = built
        .tx
        .prefix
        .extra
        .iter()
        .position(|b| *b == 0xFF)
        .expect("treasury tag");
    assert_eq!(built.tx.prefix.extra[pos + 1], 1);
    assert_eq!(
        &built.tx.prefix.extra[pos + 2..pos + 10],
        &banking_fee.to_le_bytes()
    );
}

#[test]
fn tx_proof_roundtrip() {
    use fuego_crypto::ring::{check_tx_proof, generate_tx_proof, raw_scalarmult_key};
    let mut rng = StdRng::seed_from_u64(0x9A0F_9A0F_9A0F_9A0F);
    let ((_ss, _sp), (view_sec, view_pub)) = wallet_keys(&mut rng);

    let prefix = random_scalar(&mut rng);
    let r = random_scalar(&mut rng);
    let mut rp = GeP3::default();
    ge_scalarmult_base(&mut rp, &r);
    let mut r_pub = [0u8; 32];
    ge_p3_tobytes(&mut r_pub, &rp);

    let d = raw_scalarmult_key(&view_pub, &r).unwrap();
    let sig = generate_tx_proof(&prefix, &r, &r_pub, &view_pub, &d, &mut rng).unwrap();

    assert!(check_tx_proof(&prefix, &r_pub, &view_pub, &d, &sig));
    // Tampered sig fails.
    let mut bad = sig;
    bad[40] ^= 1;
    assert!(!check_tx_proof(&prefix, &r_pub, &view_pub, &d, &bad));
    // Wrong D fails.
    let mut bad_d = d;
    bad_d[0] ^= 1;
    assert!(!check_tx_proof(&prefix, &r_pub, &view_pub, &bad_d, &sig));
    let _ = view_sec;

    println!("PROOF_PREFIX {}", hex::encode(prefix));
    println!("PROOF_R {}", hex::encode(r_pub));
    println!("PROOF_A {}", hex::encode(view_pub));
    println!("PROOF_D {}", hex::encode(d));
    println!("PROOF_SIG {}", hex::encode(sig));

    // C++-generated proof vector (harness txproofvec) — must verify here.
    let c_prefix: [u8; 32] =
        hex::decode("4445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60616263")
            .unwrap()
            .try_into()
            .unwrap();
    let c_r: [u8; 32] =
        hex::decode("355df5b5ac93da953b28550fb717c7dffc76a5df741b0c84902de6c5b68d1925")
            .unwrap()
            .try_into()
            .unwrap();
    let c_a: [u8; 32] =
        hex::decode("4e9ff25828fc34e7b0402066bdfee6668d983b8a6f6f417dfbf34ff3c45d256f")
            .unwrap()
            .try_into()
            .unwrap();
    let c_d: [u8; 32] =
        hex::decode("fb71e1178aba92e12ffa4761c5ceb8ae80ed88d813a1811c1b3a20234ff36f49")
            .unwrap()
            .try_into()
            .unwrap();
    let c_sig: [u8; 64] = hex::decode(
        "dfa3c931f0ecf2e4d6577d297a5fa0844a8fd44c6b4cbce3c7fac2785189ef07\
         88d2da00f111573436fc613357f5376dbd6886d2e659751030297e82a87a4700",
    )
    .unwrap()
    .try_into()
    .unwrap();
    assert!(
        check_tx_proof(&c_prefix, &c_r, &c_a, &c_d, &c_sig),
        "C++-generated tx proof must verify in Rust"
    );
}

#[test]
fn heat_send_recipient_view_key() {
    // send_heat: the recipient commitment must derive with the RECIPIENT's
    // view key so only they can recover/spend it.
    let mut rng = StdRng::seed_from_u64(0x5EED_5EED_5EED_5EED);
    let ((_ss, _sp), (view_sec, view_pub)) = wallet_keys(&mut rng);
    let recv_view_sec = random_scalar(&mut rng);
    let mut rv = GeP3::default();
    ge_scalarmult_base(&mut rv, &recv_view_sec);
    let mut recv_view = [0u8; 32];
    ge_p3_tobytes(&mut recv_view, &rv);

    let sec = random_scalar(&mut rng);
    let mut p = GeP3::default();
    ge_scalarmult_base(&mut p, &sec);
    let mut commit_key = [0u8; 32];
    ge_p3_tobytes(&mut commit_key, &p);
    let key_image = fuego_crypto::generate_key_image(&fuego_crypto::PublicKey(commit_key), &sec);
    let deposits = vec![CommitmentDeposit {
        amount: 100_000_000,
        commit_key,
        key_scalar: sec,
        key_image: key_image.0,
        global_index: 800,
        claimed_interest: 0,
    }];

    let amount = 40_000_000u64;
    let change = deposits[0].amount - amount - MINIMUM_FEE;
    let mixin = 2;
    let decoys: Vec<Vec<(u32, [u8; 32])>> = vec![(0..mixin)
        .map(|k| {
            let mut s = [0u8; 32];
            s[0] = 0x40 + k as u8;
            s[31] = 5;
            let mut p = GeP3::default();
            ge_scalarmult_base(&mut p, &s);
            let mut key = [0u8; 32];
            ge_p3_tobytes(&mut key, &p);
            (801 + k as u32, key)
        })
        .collect()];

    let mut extra = Vec::new();
    fuego_sdk::serialization::add_heat_send_auth_extra(&mut extra, amount);

    let built = build_commitment_spend_transaction(
        &deposits,
        &decoys,
        mixin,
        &[],
        &[
            BuildCommitmentDestination { amount, term: HEAT_TERM, view_pub: Some(recv_view) },
            BuildCommitmentDestination { amount: change, term: HEAT_TERM, view_pub: None },
        ],
        &view_pub,
        MINIMUM_FEE,
        &extra,
        &mut rng,
    )
    .unwrap();

    // 0xF9 auth: heatAmount LE64.
    let pos = built.tx.prefix.extra.iter().position(|b| *b == 0xF9).expect("send auth");
    assert_eq!(&built.tx.prefix.extra[pos + 1..pos + 9], &amount.to_le_bytes());

    // Recipient output (index 0) must be recoverable with the RECIPIENT's
    // view key: D = 8*(r*V_recv), depositSecret = Hs(D || 0), commitKey match.
    let r_bytes: [u8; 32] = built.tx.prefix.extra[1..33].try_into().unwrap();
    let d_recv = fuego_crypto::generate_key_derivation(
        &fuego_crypto::PublicKey(r_bytes),
        &recv_view_sec,
    )
    .unwrap();
    let ds = derive_deposit_secret(&d_recv, 0);
    let ck = derive_commitment_keys(&ds);
    match &built.tx.prefix.outputs[0].target {
        OutputTarget::Commitment(c) => {
            assert_eq!(c.commit_key, ck.commit_key, "recipient commit key mismatch");
            assert_eq!(c.term, HEAT_TERM);
        }
        _ => panic!("expected commitment output"),
    }

    assert_eq!(
        hex::encode(fuego_crypto::cn_fast_hash(&fuego_sdk::serialization::serialize_tx(&built.tx))),
        "4040667af39d0f586448024e6ea1e2a373429e813d837f2f5c840a34c0e0001f",
        "heat-send tx hash must match C++ parseAndValidate roundtrip"
    );

    // Change output (index 1) recovers with OUR view key.
    let d_own = fuego_crypto::generate_key_derivation(
        &fuego_crypto::PublicKey(r_bytes),
        &view_sec,
    )
    .unwrap();
    let ds2 = derive_deposit_secret(&d_own, 1);
    let ck2 = derive_commitment_keys(&ds2);
    match &built.tx.prefix.outputs[1].target {
        OutputTarget::Commitment(c) => assert_eq!(c.commit_key, ck2.commit_key),
        _ => panic!("expected commitment output"),
    }
}
