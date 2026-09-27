//! Wallet semantics that must track fuego-suite (walletd balances, extras,
//! block layout) and consistency between hand-written crates and suite.rs.

use fuego_sdk::scanner::HistoryDirection;
use fuego_sdk::serialization::*;
use fuego_sdk::{suite, Wallet};

#[test]
fn crypto_crate_constants_match_suite() {
    assert_eq!(fuego_crypto::ADDRESS_BASE58_PREFIX, suite::CRYPTONOTE_PUBLIC_ADDRESS_BASE58_PREFIX);
    assert_eq!(
        fuego_crypto::TESTNET_ADDRESS_BASE58_PREFIX,
        suite::CRYPTONOTE_PUBLIC_ADDRESS_BASE58_PREFIX_TESTNET
    );
    let dev = fuego_crypto::parse_address_full(suite::FUEGO_DEV_FUND_ADDRESS).expect("dev fund address parses");
    assert_eq!(dev.prefix, suite::CRYPTONOTE_PUBLIC_ADDRESS_BASE58_PREFIX);
}

#[test]
fn transport_table_matches_sdk_usage() {
    use suite::rpc::{http_route, is_json_rpc_method, Transport};
    for path in ["/queryblockslite.bin", "/getrandom_outs.bin", "/get_o_indexes.bin", "/getrandom_commitment_outs.bin"] {
        assert_eq!(http_route(path), Some(Transport::Binary), "{path}");
    }
    for path in ["/getinfo", "/sendrawtransaction", "/amm_pool_info", "/estimate_cd_yield", "/is_key_image_spent", "/get_alias"] {
        assert_eq!(http_route(path), Some(Transport::Json), "{path}");
    }
    assert!(is_json_rpc_method("getblockcount"));
    assert!(is_json_rpc_method("on_getblockhash"));
}

#[test]
fn payment_id_nonce_round_trips() {
    let pid = [0x5au8; 32];
    let mut extra = build_extra_with_pubkey(&[1u8; 32]);
    add_payment_id_nonce(&mut extra, &pid);
    assert_eq!(&extra[33..36], &[0x02, 33, 0x00]);
    assert_eq!(parse_extra_payment_id(&extra), Some(pid));
    assert_eq!(parse_extra_pubkey(&extra), Some([1u8; 32]));
    assert_eq!(parse_extra_payment_id(&build_extra_with_pubkey(&[1u8; 32])), None);
}

#[test]
fn cd_bonus_claim_extra_layout() {
    let mut extra = Vec::new();
    add_cd_bonus_claim_extra(&mut extra, 3, 0x0102_0304_0506_0708);
    assert_eq!(extra, vec![0xD6, 3, 8, 7, 6, 5, 4, 3, 2, 1]);
}

#[test]
fn block_timestamp_v1_and_merge_mined_layouts() {
    let mut v1 = Vec::new();
    write_varint(1, &mut v1);
    write_varint(0, &mut v1);
    write_varint(1_700_000_123, &mut v1);
    v1.extend_from_slice(&[0u8; 36]);
    assert_eq!(parse_block_timestamp(&v1).unwrap(), 1_700_000_123);

    let mut v2 = Vec::new();
    write_varint(11, &mut v2);
    write_varint(0, &mut v2);
    v2.extend_from_slice(&[9u8; 32]);
    write_varint(1, &mut v2);
    write_varint(0, &mut v2);
    write_varint(1_800_000_456, &mut v2);
    v2.extend_from_slice(&[0u8; 8]);
    assert_eq!(parse_block_timestamp(&v2).unwrap(), 1_800_000_456);
    assert!(parse_block_timestamp(&[11, 0, 1]).is_err());
}

/// Build a tx prefix paying `amounts` to `wallet` with a fresh tx key.
fn pay_to(wallet: &Wallet, amounts: &[u64], unlock_time: u64, inputs: Vec<TxInput>) -> TransactionPrefix {
    let keys = wallet.wallet_keys();
    let r = fuego_crypto::Keypair::generate();
    let d = fuego_crypto::generate_key_derivation(&fuego_crypto::PublicKey(keys.view_public), &r.secret).unwrap();
    let outputs = amounts
        .iter()
        .enumerate()
        .map(|(i, &amount)| TxOutput {
            amount,
            target: OutputTarget::Key(fuego_crypto::derive_public_key(&d, i as u64, &keys.spend_public).unwrap().0),
        })
        .collect();
    TransactionPrefix { version: 1, unlock_time, inputs, outputs, extra: build_extra_with_pubkey(&r.public) }
}

#[test]
fn balances_follow_walletd_spendability_rules() {
    let wallet = Wallet::from_seed([3u8; 32]).unwrap();
    let tx = [1u8; 32];
    let prefix = pay_to(&wallet, &[70_000, 30_000], 0, vec![]);
    let (received, spent) = wallet.scan_tx_prefix_at(&tx, &prefix, 10, 1_700_000_000).unwrap();
    assert_eq!((received, spent), (100_000, 0));

    // Not yet indexed: owned but locked.
    wallet.set_height(20);
    let b = wallet.balance_breakdown();
    assert_eq!((b.unlocked_xfg, b.locked_xfg), (0, 100_000));

    wallet.attach_global_indices(&tx, &[5, 6]);
    wallet.set_height(10 + suite::CRYPTONOTE_DEFAULT_TX_SPENDABLE_AGE - 1);
    assert_eq!(wallet.balance_breakdown().unlocked_xfg, 0, "younger than spendable age");
    wallet.set_height(10 + suite::CRYPTONOTE_DEFAULT_TX_SPENDABLE_AGE);
    assert_eq!(wallet.balance_breakdown().unlocked_xfg, 100_000);
    assert_eq!(wallet.balance().confirmed, 100_000);

    let history = wallet.get_transactions(10);
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].direction, HistoryDirection::Incoming);
    assert_eq!((history[0].amount, history[0].fee, history[0].timestamp), (100_000, 0, 1_700_000_000));

    // A pending send reserves its inputs: neither balance nor selection sees them.
    let utxo = wallet.utxos().into_iter().find(|u| u.amount == 70_000).unwrap();
    wallet.reserve_pending(&[utxo.key_image]);
    assert_eq!(wallet.balance_breakdown().unlocked_xfg, 30_000);
    assert!(wallet.select_for_send(40_000, &mut rand::thread_rng()).is_err());
    assert_eq!(wallet.select_for_send(30_000, &mut rand::thread_rng()).unwrap().len(), 1);
}

#[test]
fn unlock_time_locks_until_reached() {
    let wallet = Wallet::from_seed([4u8; 32]).unwrap();
    let tx = [2u8; 32];
    let prefix = pay_to(&wallet, &[500], 40, vec![]);
    wallet.scan_tx_prefix_at(&tx, &prefix, 10, 0).unwrap();
    wallet.attach_global_indices(&tx, &[9]);
    wallet.set_height(30);
    assert_eq!(wallet.balance_breakdown().locked_xfg, 500);
    wallet.set_height(40 - suite::CRYPTONOTE_LOCKED_TX_ALLOWED_DELTA_BLOCKS);
    assert_eq!(wallet.balance_breakdown().unlocked_xfg, 500);
}

#[test]
fn a_send_with_change_is_one_net_outgoing_entry() {
    let wallet = Wallet::from_seed([5u8; 32]).unwrap();
    let fund = pay_to(&wallet, &[1000], 0, vec![]);
    wallet.scan_tx_prefix_at(&[1u8; 32], &fund, 10, 0).unwrap();
    let spent = wallet.utxos()[0].clone();

    // Spend 1000: 600 leaves the wallet, 392 change returns, 8 fee.
    let mut send = pay_to(&wallet, &[392], 0, vec![TxInput::Key(KeyInput {
        amount: 1000,
        offsets: vec![1],
        key_image: spent.key_image,
    })]);
    send.outputs.push(TxOutput { amount: 600, target: OutputTarget::Key([7u8; 32]) });
    wallet.scan_tx_prefix_at(&[2u8; 32], &send, 11, 0).unwrap();

    let history = wallet.get_transactions(10);
    assert_eq!(history.len(), 2, "one entry per transaction");
    let out = &history[0];
    assert_eq!(out.direction, HistoryDirection::Outgoing);
    assert_eq!(out.amount, 608);
    assert_eq!(out.fee, 8);
    assert_eq!(out.signed_amount(), -608);
}
