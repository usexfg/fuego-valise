//! Owner-bound commitment keys: byte-for-byte vectors from fuego-suite branch
//! `keyderiv` (90672944), produced by its deriveOwnerBoundCommitKey,
//! deriveOwnerBoundKeyImage, deriveSubAddressKeys and deriveLegacyCommitmentKeys.
//!
//! Inputs: a = Hs("fuego-test-view"), b = Hs("fuego-test-spend"), r = Hs("fuego-test-tx"),
//! D = 8*(r*A). Sub-addresses (0,1) and (0,7) use B_sub = B + mG, b_sub = b + m.

use fuego_crypto::ring::{derive_commitment_keys, derive_deposit_secret, derive_public_key, derive_secret_key,
    generate_key_derivation, generate_key_image, secret_key_to_public_key};

const VIEW_SECRET: &str = "7a7bf6318c2307d1294e1958ec156e40105c329009b655f39a44557bf0d97709";
const SPEND_SECRET: &str = "1b7fb8744e107908891ad502d07f58cb3a28c4fb3afeee312a4323c91e066401";
const TX_SECRET: &str = "5e579bb6fdd693c6af76e12b413e6cc5553fa74a8734d33fc29f1b1ab61fc408";
const DERIVATION: &str = "ee8ad1524e532915014836a8ff7a94ff406759d69050cf3ab18cc88fbf267499";

/// (owner, output index, commit key P, key image I)
const OWNER_BOUND: &[(&str, u64, &str, &str)] = &[
    ("primary", 0, "0ce002654e6ef5daccfea70db1461986e2fd80effa8915673042a842b8b513b7", "321f26e1c77669ae65653a2bab8a08731004c890089444ae9dd907f56c8479a4"),
    ("primary", 1, "32c129e51d7d12637a3af1affc51602d473fba44c6d44cab2c914ae73037548f", "54fec7ee4a5813d3afa6344a01649c1cfc55b314d96a697aa0df78960231bd73"),
    ("primary", 127, "4e9ccc8299747eef4935ba9b310ed564590afc167b5b139c48f02c125d5a664f", "b1287ba5c4e70d0bd1f319a47f704c0621236103434b63c6170f61e52440104d"),
    ("primary", 128, "8e245626180353b211355236c120aab90f98f63698dff28315cede5eeccbd75d", "961a4a43208466aa2570c82e737cf363ecfc4f4c1041da7bca900d577119d11f"),
    ("primary", 1000000, "a40421316db3870864360396b467fafd283fea049a136853e200de162fdb54cc", "6a688a05526c8560abc502ab93e3e41b0ed1577ab695f0ad7e7b2edc8784e9f8"),
    ("sub0_1", 0, "d45ef0a09370f48f8715b52c8e2ff10cfc0917aa751209657a154d9297d0cf7e", "cd15ac9a1b113005e7c7be219097b78feb5c3b2d6ded1afcd3834df48ac6613a"),
    ("sub0_1", 1, "18a1730ee49289e932821d3d6129110a87618dfdc97f2c036eb67c337a8d1fd5", "172870eb65f65aad76a01469f9c1622ff2e30f7d95026a4cde49855f28cf8a68"),
    ("sub0_1", 127, "61f258a073880a0b1d04df68703bd0b54631d472be2ca205b475e457cd62a1b9", "757de6e51c65055b22d6f80675571ff3cb36997a2ee44a12ca949978e7a361b7"),
    ("sub0_1", 128, "8bb4bd48caab7b277db8a3d525d17d1ff59a107061a3449f5d10bba382b76d01", "3a76a4f53e74fd629d4444cbea38ae1fa0b82a93f0e125aa3b64bcfd11e607a5"),
    ("sub0_1", 1000000, "3704dd48f0d5ceed4232147b2c8f3a6bc58134dfddb7bcad97a48693dcf148cb", "e9d15afb3395a9798ac50dff4b0d05fcaa21499b87db107477813cd969f1f752"),
    ("sub0_7", 0, "d8a4b7d957f4ea22037f931a3dc4e233636af4e3925a2112b6a3b0336ed6dafe", "c4f32b2788069da33073f984409012447bd2630cd519d24b741ac3b5151b14d3"),
    ("sub0_7", 1, "13d52d3c05e17ecab1eb4620c152963336032061b7e996b9ab8dee3abaa2cf17", "3c8e9df6559ba554a9cc3ccb5063ae30f0db3150b937d7a511aefd334e04fa56"),
    ("sub0_7", 127, "37175eb3a96bba22ff226ab1d5b7402881bfec1e1750018e7d7b3510c3a3315f", "9237e19f46b76c12786c4f150d68e2f8a774ece99178a015b7f06fff472b8a4e"),
    ("sub0_7", 128, "cf079d18d98b52684557bf21097ea0887e3553efaa5c7bb2a1fffb382307cc10", "c4cc0732479ccd97a71ab5a6d97a48659f861bfc7dd67a5c8055e14d488353d8"),
    ("sub0_7", 1000000, "45117a317571aaae483d15819a37ebed78f86dbe04dac50cfdf8c777297ecedd", "50f6875dbf73c601dac800c20940680e768c4883751417b0cabf70c6c010509d"),
];

/// (output index, legacy commit key, legacy key image)
const LEGACY: &[(u32, &str, &str)] = &[
    (0, "37ce1c105871a9578b6d60e035d0ec96ef23a1edb7b049c56683b4956f44e706", "a389628bc8c379bcda6216c7371eabc86ae2a5fecb09ea6f83219bb241f5a40e"),
    (1, "79a186d024bb70a718d138cad0a677399a32fa821efd2583b4b6ae6d1d9913c7", "3a84a028b629dbd3346bc788a0b1924c6e17f3c6d6fa6a43afa4ed2c096c7ca0"),
    (127, "b4e40821b8d2b9d9e7d8fc1a36cc672decfde77498770a83def0db567d7a6ad8", "2083678be60a49809bbca295e41db1063f71f4db707a70afab266a53726bd3ca"),
    (128, "bf3f3c17f9e8cb0fc25a664858459766937f2a56c7e75d8e08d1271d32d92058", "ece3053da7251b8fc870343c76a2dc6de259fbd835e4a77fc1733f7525b2b259"),
    (1000000, "430c23a37b9b7a86499988ce157c33fd708644e747d01c380aceba0737e5869d", "687ac23c96fdec0edf7d59969ff8c98dc4df1b466b350bdb06e72e705661253a"),
];

fn key(hex_str: &str) -> [u8; 32] {
    let mut out = [0u8; 32];
    hex::decode_to_slice(hex_str, &mut out).unwrap();
    out
}

fn owner_keys(name: &str) -> ([u8; 32], [u8; 32]) {
    let (a, b) = (key(VIEW_SECRET), key(SPEND_SECRET));
    let spend_pub = secret_key_to_public_key(&b);
    match name {
        "primary" => (spend_pub, b),
        "sub0_1" | "sub0_7" => {
            let minor = if name == "sub0_1" { 1 } else { 7 };
            let sk = fuego_crypto::derive_subaddress_keys(&a, &spend_pub, Some(&b), 0, minor).unwrap();
            (sk.spend_public, sk.spend_secret.unwrap())
        }
        other => panic!("unknown owner {other}"),
    }
}

#[test]
fn derivation_matches_suite() {
    let a = key(VIEW_SECRET);
    let r = key(TX_SECRET);
    let sender = generate_key_derivation(&secret_key_to_public_key(&a), &r).unwrap();
    let receiver = generate_key_derivation(&secret_key_to_public_key(&r), &a).unwrap();
    assert_eq!(hex::encode(sender), DERIVATION);
    assert_eq!(sender, receiver);
}

#[test]
fn owner_bound_keys_match_suite() {
    let d = key(DERIVATION);
    for &(owner, index, p_hex, i_hex) in OWNER_BOUND {
        let (spend_pub, spend_sec) = owner_keys(owner);
        let p = derive_public_key(&d, index, &spend_pub).unwrap();
        assert_eq!(hex::encode(p), p_hex, "{owner} {index} commit key");
        let x = derive_secret_key(&d, index, &spend_sec).unwrap();
        assert_eq!(secret_key_to_public_key(&x), p, "{owner} {index} spend scalar");
        assert_eq!(hex::encode(generate_key_image(&p, &x)), i_hex, "{owner} {index} key image");
    }
}

#[test]
fn legacy_keys_match_suite() {
    let d = key(DERIVATION);
    for &(index, p_hex, i_hex) in LEGACY {
        let ck = derive_commitment_keys(&derive_deposit_secret(&d, index));
        assert_eq!(hex::encode(ck.commit_key), p_hex, "legacy {index} commit key");
        assert_eq!(hex::encode(ck.key_image), i_hex, "legacy {index} key image");
        // Owner-bound and legacy keys never coincide.
        let (spend_pub, _) = owner_keys("primary");
        assert_ne!(derive_public_key(&d, index as u64, &spend_pub).unwrap(), ck.commit_key);
    }
}
