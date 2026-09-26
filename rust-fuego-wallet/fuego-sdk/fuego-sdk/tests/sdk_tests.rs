use fuego_sdk::builder::{SdkBuilder, WalletBuilder};
use fuego_sdk::crypto;
use fuego_sdk::error::SdkError;
use fuego_sdk::node::EmbeddedNode;
use fuego_sdk::store::MemoryStore;
use fuego_sdk::traits::*;
use fuego_sdk::types::*;
use fuego_sdk::vault::WalletVault;
use fuego_sdk::wallet::Wallet;
use std::sync::Arc;
use tempfile::tempdir;

// ============================================================
// Crypto tests
// ============================================================

#[test]
fn test_keypair_generation() {
    let kp = crypto::generate_keypair();
    assert_ne!(kp.secret.as_bytes(), &[0u8; 32]);
    assert_ne!(kp.public.0, [0u8; 32]);
}

#[test]
fn test_keypair_from_secret() {
    let secret = [42u8; 32];
    let kp = crypto::keypair_from_secret(secret);
    // The secret is kept as the canonical scalar mod l.
    let mut reduced = secret;
    fuego_crypto::ref10::sc_reduce32(&mut reduced);
    assert_eq!(kp.secret.as_bytes(), &reduced);
    // Every vault-style key must be usable for CryptoNote derivation.
    let other = crypto::keypair_from_secret([0xffu8; 32]);
    assert!(crypto::generate_key_derivation(&other.public, &kp.secret).is_some());
}

#[test]
fn test_make_address() {
    let kp = crypto::generate_keypair();
    let view_kp = crypto::generate_keypair();
    let addr = crypto::make_address(&kp.public, &view_kp.public);
    assert!(crypto::is_valid_address(&addr.0));
}

#[test]
fn test_sign_and_verify() {
    let kp = crypto::generate_keypair();
    let message = b"hello fuego";
    let sig = crypto::sign(&kp, message);
    assert!(!sig.is_empty());
}

#[test]
fn test_verify_wrong_key() {
    let kp = crypto::generate_keypair();
    let kp2 = crypto::generate_keypair();
    let sig = crypto::sign(&kp, b"hello");
    assert!(!crypto::verify(&kp2.public, b"hello", &sig));
}

#[test]
fn test_hash_deterministic() {
    let data = b"test data";
    let h1 = crypto::hash(data);
    let h2 = crypto::hash(data);
    assert_eq!(h1, h2);
}

#[test]
fn test_hash_not_zero() {
    let h = crypto::hash(b"fuego");
    assert_ne!(h, [0u8; 32]);
}

#[test]
fn test_key_derivation_deterministic() {
    let spend = crypto::generate_keypair();
    let view = crypto::generate_keypair();
    let d1 = crypto::generate_key_derivation(&view.public, &spend.secret);
    let d2 = crypto::generate_key_derivation(&view.public, &spend.secret);
    assert!(d1.is_some());
    assert_eq!(d1, d2);
}

#[test]
fn test_key_derivation_different_index() {
    let spend = crypto::generate_keypair();
    let view = crypto::generate_keypair();
    let d0 = crypto::generate_key_derivation(&view.public, &spend.secret).unwrap();
    let d1 = crypto::derive_public_key(&d0, 0, &spend.public).unwrap();
    let d2 = crypto::derive_public_key(&d0, 1, &spend.public).unwrap();
    assert_ne!(d1.0, d2.0);
}

#[test]
fn test_key_image_unique() {
    let kp = crypto::generate_keypair();
    let kp2 = crypto::generate_keypair();
    let ki1 = crypto::generate_key_image(&kp.public, &kp.secret);
    let ki2 = crypto::generate_key_image(&kp2.public, &kp2.secret);
    assert_ne!(ki1.0, ki2.0);
}

// ============================================================
// Store tests
// ============================================================

#[test]
fn test_memory_store_height() {
    let store = MemoryStore::new();
    store.save_height(100).unwrap();
    assert_eq!(store.get_height().unwrap(), 100);
}

#[test]
fn test_memory_store_block() {
    let store = MemoryStore::new();
    let block = Block {
        header: BlockHeader {
            height: 1,
            hash: [1u8; 32],
            prev_hash: [0u8; 32],
            timestamp: 1000,
            tx_count: 0,
        },
        transactions: Vec::new(),
    };
    store.save_block(&block).unwrap();
    let retrieved = store.get_block(1).unwrap().unwrap();
    assert_eq!(retrieved.header.height, 1);
}

#[test]
fn test_memory_store_utxo() {
    let store = MemoryStore::new();
    let utxo = Utxo {
        tx_hash: [1u8; 32],
        output_index: 0,
        amount: 1000,
        pubkey: [2u8; 32],
        height: 10,
    };
    store.save_utxo(&utxo).unwrap();
    let retrieved = store.get_utxo(&[1u8; 32], 0).unwrap().unwrap();
    assert_eq!(retrieved.amount, 1000);

    store.delete_utxo(&[1u8; 32], 0).unwrap();
    assert!(store.get_utxo(&[1u8; 32], 0).unwrap().is_none());
}

#[test]
fn test_memory_store_kv() {
    let store = MemoryStore::new();
    store.put(b"key", b"value").unwrap();
    assert_eq!(store.get(b"key").unwrap(), Some(b"value".to_vec()));
    assert!(store.exists(b"key").unwrap());
    store.delete(b"key").unwrap();
    assert!(!store.exists(b"key").unwrap());
}

// ============================================================
// Node builder tests
// ============================================================

#[test]
fn test_sdk_builder_defaults() {
    let node = SdkBuilder::new().build().unwrap();
    assert_eq!(node.height(), 0);
}

#[test]
fn test_sdk_builder_with_storage() {
    let store: Arc<dyn StorageProvider> = Arc::new(MemoryStore::new());
    let store_ptr = Arc::as_ptr(&store);
    let node = SdkBuilder::new()
        .with_storage(store.clone())
        .build()
        .unwrap();
    assert_eq!(node.height(), 0);
    assert!(std::ptr::eq(Arc::as_ptr(node.storage()), store_ptr));
}

#[test]
fn test_sdk_builder_custom_config() {
    let node = SdkBuilder::new()
        .data_dir("/tmp/fuego-test")
        .max_peers(100)
        .sync_interval(60)
        .enable_seeding(true)
        .build()
        .unwrap();
    assert_eq!(node.height(), 0);
}

#[test]
fn test_sdk_builder_rpc() {
    let node = SdkBuilder::new().rpc("127.0.0.1", 18081).build().unwrap();
    assert_eq!(node.height(), 0);
}

// ============================================================
// Node tests
// ============================================================

#[test]
fn test_node_height_default() {
    let node = EmbeddedNode::new(NodeConfig::default()).unwrap();
    assert_eq!(node.height(), 0);
}

#[test]
fn test_node_sync_status() {
    let node = EmbeddedNode::new(NodeConfig::default()).unwrap();
    let status = node.sync_status();
    assert_eq!(status.current_height, 0);
    assert!(!status.is_syncing);
}

#[test]
fn test_node_peer_count() {
    let node = EmbeddedNode::new(NodeConfig::default()).unwrap();
    assert_eq!(node.peer_count(), 0);
}

#[test]
fn test_node_get_nonexistent_block() {
    let node = EmbeddedNode::new(NodeConfig::default()).unwrap();
    assert!(node.get_block(1).unwrap().is_none());
}

#[test]
fn test_node_subscribe() {
    let node = EmbeddedNode::new(NodeConfig::default()).unwrap();
    let _rx = node.subscribe();
}

// ============================================================
// Type tests
// ============================================================

#[test]
fn test_balance_default() {
    let b = Balance::default();
    assert_eq!(b.confirmed, 0);
    assert_eq!(b.pending, 0);
    assert_eq!(b.immature, 0);
}

#[test]
fn test_balance_total() {
    let b = Balance {
        confirmed: 100,
        pending: 50,
        immature: 10,
    };
    assert_eq!(b.total(), 160);
}

#[test]
fn test_tx_builder() {
    let tx = TxBuilder::new()
        .add_input(TxInput {
            prev_tx_hash: [1u8; 32],
            prev_output_index: 0,
            signature: Vec::new(),
        })
        .add_output(500, [2u8; 32])
        .build();
    assert_eq!(tx.inputs.len(), 1);
    assert_eq!(tx.outputs.len(), 1);
    assert_eq!(tx.fee, 0);
}

#[test]
fn test_node_config_default() {
    let config = NodeConfig::default();
    assert_eq!(config.max_peers, 50);
    assert_eq!(config.sync_interval_secs, 30);
    assert!(!config.enable_seeding);
}

// ============================================================
// Vault tests
// ============================================================

#[test]
fn test_vault_generate() {
    let vault = WalletVault::generate();
    let addr = vault.get_address(0);
    assert!(!addr.0.is_empty());
}

#[test]
fn test_vault_from_seed() {
    let seed = [99u8; 32];
    let vault = WalletVault::from_seed(seed);
    let addr = vault.get_address(0);
    assert!(!addr.0.is_empty());
}

#[test]
fn test_vault_save_and_load() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("vault_test.bin");
    let passphrase = b"vault-passphrase";

    let mut vault = WalletVault::generate();
    vault.set_display_name("Test Wallet".to_string());
    let addr = vault.get_address(0).0;
    vault.save(path.clone(), passphrase).unwrap();

    let loaded = WalletVault::load(path, passphrase).unwrap();
    assert_eq!(loaded.get_address(0).0, addr);
    assert_eq!(loaded.display_name(), Some("Test Wallet"));
}

#[test]
fn test_vault_guardians() {
    let mut vault = WalletVault::generate();
    assert!(vault.guardians().is_empty());

    let g = fuego_crypto::Address("fire1guardian".to_string());
    vault.add_guardian(g).unwrap();
    assert_eq!(vault.guardians().len(), 1);
}

// ============================================================
// Wallet tests
// ============================================================

#[test]
fn test_wallet_generate_and_address() {
    let wallet = Wallet::generate().unwrap();
    let addr = wallet.primary_address();
    assert!(!addr.0.is_empty());
}

#[test]
fn test_wallet_from_seed() {
    let seed = [7u8; 32];
    let wallet = Wallet::from_seed(seed).unwrap();
    let addr = wallet.primary_address();
    assert!(!addr.0.is_empty());
}

#[test]
fn test_wallet_same_seed_same_address() {
    let seed = [42u8; 32];
    let w1 = Wallet::from_seed(seed).unwrap();
    let w2 = Wallet::from_seed(seed).unwrap();
    assert_eq!(w1.primary_address().0, w2.primary_address().0);
}

#[test]
fn test_wallet_different_index_different_address() {
    let wallet = Wallet::generate().unwrap();
    let a0 = wallet.get_address(0);
    let a1 = wallet.get_address(1);
    assert_ne!(a0.0, a1.0);
}

#[test]
fn test_wallet_balance_starts_zero() {
    let wallet = Wallet::generate().unwrap();
    assert_eq!(wallet.balance().confirmed, 0);
    assert_eq!(wallet.height(), 0);
}

#[test]
fn test_wallet_transaction_history_empty() {
    let wallet = Wallet::generate().unwrap();
    assert!(wallet.get_transactions(10).is_empty());
}

#[test]
fn test_wallet_insufficient_funds() {
    let wallet = Wallet::generate().unwrap();
    let result = wallet.select_for_send(1000, &mut rand::thread_rng());
    assert!(matches!(result, Err(SdkError::InsufficientFunds { .. })));
}

#[test]
fn test_wallet_save_and_load() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("wallet_test.bin");
    let passphrase = b"test-passphrase";

    let wallet = Wallet::generate().unwrap();
    let addr = wallet.primary_address();
    wallet.save(path.clone(), passphrase).unwrap();

    let loaded = Wallet::load(path, passphrase).unwrap();
    assert_eq!(loaded.primary_address().0, addr.0);
}

#[test]
fn test_wallet_builder() {
    let wallet = WalletBuilder::new().seed([1u8; 32]).build().unwrap();
    let addr = wallet.primary_address();
    assert!(!addr.0.is_empty());
}

#[test]
fn test_scan_foreign_prefix() {
    use fuego_sdk::serialization::{KeyInput, OutputTarget, TransactionPrefix, TxInput, TxOutput};

    let wallet = Wallet::generate().unwrap();
    let mut extra = vec![0x01u8];
    extra.extend_from_slice(&[9u8; 32]);
    let prefix = TransactionPrefix {
        version: 1,
        unlock_time: 0,
        inputs: vec![TxInput::Key(KeyInput {
            amount: 100,
            offsets: vec![1, 2],
            key_image: [7u8; 32],
        })],
        outputs: vec![TxOutput { amount: 100, target: OutputTarget::Key([8u8; 32]) }],
        extra,
    };
    let (received, spent) = wallet.scan_tx_prefix(&[5u8; 32], &prefix, 1).unwrap();
    assert_eq!(received, 0);
    assert_eq!(spent, 0);
}
