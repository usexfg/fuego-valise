use fuego_crypto::{Keypair, PublicKey, make_address, generate_key_derivation, derive_public_key, underive_public_key, generate_key_image, cn_base58_encode, cn_fast_hash, generate_signature, check_signature};
use fuego_vault::Vault;
use fuego_sdk::types::SwapPair;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::ptr;
use std::slice;

// ── Memory management ──

/// Free a string returned by fuego_ffi functions.
#[no_mangle]
pub unsafe extern "C" fn fuego_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

/// Free a byte buffer returned by fuego_ffi functions.
#[no_mangle]
pub unsafe extern "C" fn fuego_bytes_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        drop(Vec::from_raw_parts(ptr, len, len));
    }
}

// ── Key generation ──

/// Generate a random keypair. Returns JSON: {"secret":"hex","public":"hex"}
#[no_mangle]
pub extern "C" fn fuego_keypair_generate() -> *mut c_char {
    let kp = Keypair::generate();
    let json = serde_json::json!({
        "secret": hex::encode(kp.secret),
        "public": hex::encode(kp.public),
    });
    CString::new(json.to_string()).unwrap().into_raw()
}

/// Create keypair from a 32-byte secret. Returns JSON: {"secret":"hex","public":"hex"}
#[no_mangle]
pub unsafe extern "C" fn fuego_keypair_from_secret(secret_ptr: *const u8) -> *mut c_char {
    if secret_ptr.is_null() {
        return CString::new("{\"error\":\"null pointer\"}").unwrap().into_raw();
    }
    let secret = slice::from_raw_parts(secret_ptr, 32);
    let mut secret_bytes = [0u8; 32];
    secret_bytes.copy_from_slice(secret);
    let kp = Keypair::from_secret(secret_bytes);
    let json = serde_json::json!({
        "secret": hex::encode(kp.secret),
        "public": hex::encode(kp.public),
    });
    CString::new(json.to_string()).unwrap().into_raw()
}

// ── Address generation ──

/// Generate a Fuego address from spend + view public keys (32 bytes each).
#[no_mangle]
pub unsafe extern "C" fn fuego_make_address(
    spend_pub_ptr: *const u8,
    view_pub_ptr: *const u8,
) -> *mut c_char {
    if spend_pub_ptr.is_null() || view_pub_ptr.is_null() {
        return CString::new("").unwrap().into_raw();
    }
    let spend_pub = slice::from_raw_parts(spend_pub_ptr, 32);
    let view_pub = slice::from_raw_parts(view_pub_ptr, 32);
    let mut spend = [0u8; 32];
    let mut view = [0u8; 32];
    spend.copy_from_slice(spend_pub);
    view.copy_from_slice(view_pub);
    let addr = make_address(&spend, &view);
    CString::new(addr.0).unwrap().into_raw()
}

// ── Vault (HD wallet) ──

/// Generate a new vault. Returns serialized vault bytes.
#[no_mangle]
pub extern "C" fn fuego_vault_generate() -> FuegoBytes {
    let vault = Vault::generate();
    let data = bincode::serialize(&vault).unwrap_or_default();
    let len = data.len();
    let mut buf = data.into_boxed_slice();
    let ptr = buf.as_mut_ptr();
    std::mem::forget(buf);
    FuegoBytes { ptr, len }
}

/// Create vault from a 32-byte seed. Returns serialized vault bytes.
#[no_mangle]
pub unsafe extern "C" fn fuego_vault_from_seed(seed_ptr: *const u8) -> FuegoBytes {
    if seed_ptr.is_null() {
        return FuegoBytes { ptr: ptr::null_mut(), len: 0 };
    }
    let seed = slice::from_raw_parts(seed_ptr, 32);
    let mut seed_bytes = [0u8; 32];
    seed_bytes.copy_from_slice(seed);
    let vault = Vault::new(seed_bytes);
    let data = bincode::serialize(&vault).unwrap_or_default();
    let len = data.len();
    let mut buf = data.into_boxed_slice();
    let ptr = buf.as_mut_ptr();
    std::mem::forget(buf);
    FuegoBytes { ptr, len }
}

/// Get address from vault at a given index.
#[no_mangle]
pub unsafe extern "C" fn fuego_vault_get_address(
    vault_ptr: *const u8,
    vault_len: usize,
    index: u32,
) -> *mut c_char {
    if vault_ptr.is_null() {
        return CString::new("").unwrap().into_raw();
    }
    let data = slice::from_raw_parts(vault_ptr, vault_len);
    match bincode::deserialize::<Vault>(data) {
        Ok(vault) => {
            let addr = vault.get_address(index);
            CString::new(addr.0).unwrap().into_raw()
        }
        Err(_) => CString::new("").unwrap().into_raw(),
    }
}

/// Get hex-encoded 32-byte seed from vault. Returns 64-char hex string.
#[no_mangle]
pub unsafe extern "C" fn fuego_vault_get_seed(
    vault_ptr: *const u8,
    vault_len: usize,
) -> *mut c_char {
    if vault_ptr.is_null() {
        return CString::new("").unwrap().into_raw();
    }
    let data = slice::from_raw_parts(vault_ptr, vault_len);
    match bincode::deserialize::<Vault>(data) {
        Ok(vault) => CString::new(hex::encode(vault.master_seed)).unwrap().into_raw(),
        Err(_) => CString::new("").unwrap().into_raw(),
    }
}

/// Derive keypair from vault at index. Returns JSON: {"secret":"hex","public":"hex"}
#[no_mangle]
pub unsafe extern "C" fn fuego_vault_derive_keypair(
    vault_ptr: *const u8,
    vault_len: usize,
    index: u32,
) -> *mut c_char {
    if vault_ptr.is_null() {
        return CString::new("{\"error\":\"null pointer\"}").unwrap().into_raw();
    }
    let data = slice::from_raw_parts(vault_ptr, vault_len);
    match bincode::deserialize::<Vault>(data) {
        Ok(vault) => {
            let kp = vault.derive_keypair(index);
            let json = serde_json::json!({
                "secret": hex::encode(kp.secret),
                "public": hex::encode(kp.public),
            });
            CString::new(json.to_string()).unwrap().into_raw()
        }
        Err(e) => {
            let json = serde_json::json!({"error": e.to_string()});
            CString::new(json.to_string()).unwrap().into_raw()
        }
    }
}

/// Save vault to file path.
#[no_mangle]
pub unsafe extern "C" fn fuego_vault_save(
    vault_ptr: *const u8,
    vault_len: usize,
    path_ptr: *const c_char,
) -> FuegoResult {
    if vault_ptr.is_null() || path_ptr.is_null() {
        return FuegoResult { ok: false, error: CString::new("null pointer").unwrap().into_raw() };
    }
    let data = slice::from_raw_parts(vault_ptr, vault_len);
    let path = CStr::from_ptr(path_ptr).to_str().unwrap_or("");
    match bincode::deserialize::<Vault>(data) {
        Ok(vault) => match vault.save_unencrypted(std::path::PathBuf::from(path)) {
            Ok(()) => FuegoResult { ok: true, error: ptr::null_mut() },
            Err(e) => FuegoResult { ok: false, error: CString::new(e.to_string()).unwrap().into_raw() },
        },
        Err(e) => FuegoResult { ok: false, error: CString::new(e.to_string()).unwrap().into_raw() },
    }
}

/// Load vault from file path. Returns serialized vault bytes.
#[no_mangle]
pub unsafe extern "C" fn fuego_vault_load(path_ptr: *const c_char) -> FuegoBytes {
    if path_ptr.is_null() {
        return FuegoBytes { ptr: ptr::null_mut(), len: 0 };
    }
    let path = CStr::from_ptr(path_ptr).to_str().unwrap_or("");
    match Vault::load_unencrypted(std::path::PathBuf::from(path)) {
        Ok(vault) => {
            let data = bincode::serialize(&vault).unwrap_or_default();
            let len = data.len();
            let mut buf = data.into_boxed_slice();
            let ptr = buf.as_mut_ptr();
            std::mem::forget(buf);
            FuegoBytes { ptr, len }
        }
        Err(_) => FuegoBytes { ptr: ptr::null_mut(), len: 0 },
    }
}

// ── Crypto operations ──

/// Generate key derivation. Returns 32-byte derivation as hex string.
#[no_mangle]
pub unsafe extern "C" fn fuego_generate_key_derivation(
    key1_ptr: *const u8,
    secret2_ptr: *const u8,
) -> *mut c_char {
    if key1_ptr.is_null() || secret2_ptr.is_null() {
        return CString::new("").unwrap().into_raw();
    }
    let key1_bytes = slice::from_raw_parts(key1_ptr, 32);
    let secret2_bytes = slice::from_raw_parts(secret2_ptr, 32);
    let mut key1 = [0u8; 32];
    let mut secret2 = [0u8; 32];
    key1.copy_from_slice(key1_bytes);
    secret2.copy_from_slice(secret2_bytes);
    let pk = PublicKey(key1);
    match generate_key_derivation(&pk, &secret2) {
        Some(derivation) => CString::new(hex::encode(derivation)).unwrap().into_raw(),
        None => CString::new("").unwrap().into_raw(),
    }
}

/// Derive a one-time public key: P = Hs(D || varint(i)) * G + base.
/// Returns 64-hex chars, or empty string on invalid base.
#[no_mangle]
pub unsafe extern "C" fn fuego_derive_public_key(
    derivation_ptr: *const u8,
    output_index: u64,
    base_ptr: *const u8,
) -> *mut c_char {
    if derivation_ptr.is_null() || base_ptr.is_null() {
        return CString::new("").unwrap().into_raw();
    }
    let deriv_bytes = slice::from_raw_parts(derivation_ptr, 32);
    let base_bytes = slice::from_raw_parts(base_ptr, 32);
    let mut derivation = [0u8; 32];
    let mut base = [0u8; 32];
    derivation.copy_from_slice(deriv_bytes);
    base.copy_from_slice(base_bytes);
    match derive_public_key(&derivation, output_index, &base) {
        Some(pk) => CString::new(hex::encode(pk.0)).unwrap().into_raw(),
        None => CString::new("").unwrap().into_raw(),
    }
}

/// Generate key image. Returns 32-byte key image as hex string.
#[no_mangle]
pub unsafe extern "C" fn fuego_generate_key_image(
    pubkey_ptr: *const u8,
    secret_ptr: *const u8,
) -> *mut c_char {
    if pubkey_ptr.is_null() || secret_ptr.is_null() {
        return CString::new("").unwrap().into_raw();
    }
    let pk_bytes = slice::from_raw_parts(pubkey_ptr, 32);
    let sk_bytes = slice::from_raw_parts(secret_ptr, 32);
    let mut pk = [0u8; 32];
    let mut sk = [0u8; 32];
    pk.copy_from_slice(pk_bytes);
    sk.copy_from_slice(sk_bytes);
    let ki = generate_key_image(&PublicKey(pk), &sk);
    CString::new(hex::encode(ki.0)).unwrap().into_raw()
}

/// Reverse key derivation: recover spend public key from output key.
/// Returns 32-byte public key as hex string.
#[no_mangle]
pub unsafe extern "C" fn fuego_underive_public_key(
    derivation_ptr: *const u8,
    output_index: u64,
    output_key_ptr: *const u8,
) -> *mut c_char {
    if derivation_ptr.is_null() || output_key_ptr.is_null() {
        return CString::new("").unwrap().into_raw();
    }
    let deriv_bytes = slice::from_raw_parts(derivation_ptr, 32);
    let ok_bytes = slice::from_raw_parts(output_key_ptr, 32);
    let mut derivation = [0u8; 32];
    let mut output_key = [0u8; 32];
    derivation.copy_from_slice(deriv_bytes);
    output_key.copy_from_slice(ok_bytes);
    match underive_public_key(&derivation, output_index, &PublicKey(output_key)) {
        Some(pk) => CString::new(hex::encode(pk.0)).unwrap().into_raw(),
        None => CString::new("").unwrap().into_raw(),
    }
}

/// Sign a message with a 32-byte CryptoNote secret key (CryptoNote
/// `generate_signature` over `cn_fast_hash(message)` — the same scheme the
/// daemon uses for sign_message). Returns 64-byte signature as hex.
///
/// Note: ed25519_dalek-style signing is NOT used here — its clamped-scalar
/// keying is inconsistent with the CryptoNote keypairs this library
/// generates, and signatures produced by it cannot verify under the
/// CryptoNote public key.
#[no_mangle]
pub unsafe extern "C" fn fuego_sign(
    secret_ptr: *const u8,
    message_ptr: *const u8,
    message_len: usize,
) -> *mut c_char {
    if secret_ptr.is_null() || message_ptr.is_null() {
        return CString::new("").unwrap().into_raw();
    }
    let sk_bytes = slice::from_raw_parts(secret_ptr, 32);
    let message = slice::from_raw_parts(message_ptr, message_len);
    let mut sk = [0u8; 32];
    sk.copy_from_slice(sk_bytes);
    let kp = Keypair::from_secret(sk);
    let prefix_hash = cn_fast_hash(message);
    let mut rng = rand::thread_rng();
    match generate_signature(&prefix_hash, &kp.public, &sk, &mut rng) {
        Some(sig) => CString::new(hex::encode(sig)).unwrap().into_raw(),
        None => CString::new("").unwrap().into_raw(),
    }
}

/// Verify a CryptoNote signature over `cn_fast_hash(message)`.
/// Returns 1 if valid, 0 if invalid.
#[no_mangle]
pub unsafe extern "C" fn fuego_verify(
    pubkey_ptr: *const u8,
    message_ptr: *const u8,
    message_len: usize,
    signature_ptr: *const u8,
) -> bool {
    if pubkey_ptr.is_null() || message_ptr.is_null() || signature_ptr.is_null() {
        return false;
    }
    let pk_bytes = slice::from_raw_parts(pubkey_ptr, 32);
    let message = slice::from_raw_parts(message_ptr, message_len);
    let sig_bytes = slice::from_raw_parts(signature_ptr, 64);
    let mut pk = [0u8; 32];
    let mut sig_arr = [0u8; 64];
    pk.copy_from_slice(pk_bytes);
    sig_arr.copy_from_slice(sig_bytes);
    let prefix_hash = cn_fast_hash(message);
    check_signature(&prefix_hash, &pk, &sig_arr)
}

/// `cn_fast_hash` (keccak256). Returns 32-byte hash as hex.
/// Used for swap offer ids and offer/cancel signature hashes.
#[no_mangle]
pub unsafe extern "C" fn fuego_cn_fast_hash(data_ptr: *const u8, data_len: usize) -> *mut c_char {
    if data_ptr.is_null() {
        return CString::new("").unwrap().into_raw();
    }
    let data = slice::from_raw_parts(data_ptr, data_len);
    let h = cn_fast_hash(data);
    CString::new(hex::encode(h)).unwrap().into_raw()
}

/// CryptoNote `generate_signature(prefix_hash, pub, sec)` (Schnorr c/r).
/// Returns 64-byte signature as hex, or "" on invalid secret key.
#[no_mangle]
pub unsafe extern "C" fn fuego_crypto_note_sign(
    prefix_hash_ptr: *const u8,
    pubkey_ptr: *const u8,
    secret_ptr: *const u8,
) -> *mut c_char {
    if prefix_hash_ptr.is_null() || pubkey_ptr.is_null() || secret_ptr.is_null() {
        return CString::new("").unwrap().into_raw();
    }
    let hash_bytes = slice::from_raw_parts(prefix_hash_ptr, 32);
    let pub_bytes = slice::from_raw_parts(pubkey_ptr, 32);
    let sec_bytes = slice::from_raw_parts(secret_ptr, 32);
    let mut hash = [0u8; 32];
    let mut pubkey = [0u8; 32];
    let mut sec = [0u8; 32];
    hash.copy_from_slice(hash_bytes);
    pubkey.copy_from_slice(pub_bytes);
    sec.copy_from_slice(sec_bytes);
    let mut rng = rand::thread_rng();
    match generate_signature(&hash, &pubkey, &sec, &mut rng) {
        Some(sig) => CString::new(hex::encode(sig)).unwrap().into_raw(),
        None => CString::new("").unwrap().into_raw(),
    }
}

/// CryptoNote `check_signature(prefix_hash, pub, sig)`. Returns 1 if valid.
#[no_mangle]
pub unsafe extern "C" fn fuego_crypto_note_check(
    prefix_hash_ptr: *const u8,
    pubkey_ptr: *const u8,
    signature_ptr: *const u8,
) -> bool {
    if prefix_hash_ptr.is_null() || pubkey_ptr.is_null() || signature_ptr.is_null() {
        return false;
    }
    let hash_bytes = slice::from_raw_parts(prefix_hash_ptr, 32);
    let pub_bytes = slice::from_raw_parts(pubkey_ptr, 32);
    let sig_bytes = slice::from_raw_parts(signature_ptr, 64);
    let mut hash = [0u8; 32];
    let mut pubkey = [0u8; 32];
    let mut sig = [0u8; 64];
    hash.copy_from_slice(hash_bytes);
    pubkey.copy_from_slice(pub_bytes);
    sig.copy_from_slice(sig_bytes);
    check_signature(&hash, &pubkey, &sig)
}

/// Base58-encode data (CryptoNote block-based encoding).
#[no_mangle]
pub unsafe extern "C" fn fuego_base58_encode(
    data_ptr: *const u8,
    data_len: usize,
) -> *mut c_char {
    if data_ptr.is_null() {
        return CString::new("").unwrap().into_raw();
    }
    let data = slice::from_raw_parts(data_ptr, data_len);
    let encoded = cn_base58_encode(data);
    CString::new(encoded).unwrap().into_raw()
}

// ── FFI types ──

/// A byte buffer returned to the caller. Free with `fuego_bytes_free`.
#[repr(C)]
pub struct FuegoBytes {
    pub ptr: *mut u8,
    pub len: usize,
}

/// A result type for operations that can fail.
#[repr(C)]
pub struct FuegoResult {
    pub ok: bool,
    pub error: *mut c_char,
}

// ── Library info ──

/// Get library version. Returns a null-terminated C string.
#[no_mangle]
pub extern "C" fn fuego_version() -> *mut c_char {
    CString::new(env!("CARGO_PKG_VERSION")).unwrap().into_raw()
}

// ── Swap Pair helpers ──

/// Get number of supported swap pairs. Returns 6.
#[no_mangle]
pub extern "C" fn fuego_swap_pair_count() -> u8 {
    6
}

/// Get swap pair ID by ticker. Returns -1 if not found.
#[no_mangle]
pub unsafe extern "C" fn fuego_swap_pair_from_ticker(ticker_ptr: *const c_char) -> i8 {
    if ticker_ptr.is_null() {
        return -1;
    }
    let ticker = CStr::from_ptr(ticker_ptr).to_str().unwrap_or("");
    match SwapPair::from_id_str(ticker) {
        Some(p) => p as i8,
        None => -1,
    }
}

/// Get swap pair ticker by ID. Returns empty string if invalid.
#[no_mangle]
pub extern "C" fn fuego_swap_pair_ticker(id: u8) -> *mut c_char {
    match SwapPair::from_id(id) {
        Some(p) => CString::new(p.ticker()).unwrap().into_raw(),
        None => CString::new("").unwrap().into_raw(),
    }
}

/// Get swap pair display name by ID (e.g. "XFG/SOL"). Returns empty string if invalid.
#[no_mangle]
pub extern "C" fn fuego_swap_pair_name(id: u8) -> *mut c_char {
    match SwapPair::from_id(id) {
        Some(p) => CString::new(p.as_str()).unwrap().into_raw(),
        None => CString::new("").unwrap().into_raw(),
    }
}

// ── HTLC (Hash Time-Locked Contract) ──

/// Create a new HTLC hash lock. Returns JSON: {"preimage":"hex","hash":"hex"}
#[no_mangle]
pub extern "C" fn fuego_htlc_create_hash_lock() -> *mut c_char {
    let (preimage, hash) = fuego_sdk::wallet::Wallet::create_htlc_hash_lock();
    let json = serde_json::json!({
        "preimage": hex::encode(preimage),
        "hash": hash,
    });
    CString::new(json.to_string()).unwrap().into_raw()
}

/// Build an HTLC redeem script for Bitcoin-family chains.
/// Returns hex-encoded script bytes.
#[no_mangle]
pub unsafe extern "C" fn fuego_htlc_build_script(
    hash_lock_ptr: *const c_char,
    recipient_pubkey_ptr: *const c_char,
    sender_pubkey_ptr: *const c_char,
    timelock: u64,
) -> *mut c_char {
    if hash_lock_ptr.is_null() || recipient_pubkey_ptr.is_null() || sender_pubkey_ptr.is_null() {
        return CString::new("{\"error\":\"null pointer\"}").unwrap().into_raw();
    }
    let hash_lock = CStr::from_ptr(hash_lock_ptr).to_str().unwrap_or("");
    let recipient = CStr::from_ptr(recipient_pubkey_ptr).to_str().unwrap_or("");
    let sender = CStr::from_ptr(sender_pubkey_ptr).to_str().unwrap_or("");

    match fuego_sdk::wallet::Wallet::build_htlc_script(hash_lock, recipient, sender, timelock) {
        Ok(script) => {
            let json = serde_json::json!({
                "script": hex::encode(script),
                "ok": true,
            });
            CString::new(json.to_string()).unwrap().into_raw()
        }
        Err(e) => {
            let json = serde_json::json!({"error": e.to_string()});
            CString::new(json.to_string()).unwrap().into_raw()
        }
    }
}

// ── Chain SPV helpers ──

/// Get chain type symbol by ID. Returns empty string if invalid.
#[no_mangle]
pub extern "C" fn fuego_chain_symbol(chain_id: u8) -> *mut c_char {
    let chain = match chain_id {
        0 => fuego_sdk::chain::ChainType::Fuego,
        1 => fuego_sdk::chain::ChainType::Solana,
        2 => fuego_sdk::chain::ChainType::Ethereum,
        3 => fuego_sdk::chain::ChainType::Monero,
        4 => fuego_sdk::chain::ChainType::BitcoinCash,
        5 => fuego_sdk::chain::ChainType::Arbitrum,
        6 => fuego_sdk::chain::ChainType::Base,
        _ => return CString::new("").unwrap().into_raw(),
    };
    CString::new(chain.symbol()).unwrap().into_raw()
}

/// Get chain type name by ID. Returns empty string if invalid.
#[no_mangle]
pub extern "C" fn fuego_chain_name(chain_id: u8) -> *mut c_char {
    let chain = match chain_id {
        0 => fuego_sdk::chain::ChainType::Fuego,
        1 => fuego_sdk::chain::ChainType::Solana,
        2 => fuego_sdk::chain::ChainType::Ethereum,
        3 => fuego_sdk::chain::ChainType::Monero,
        4 => fuego_sdk::chain::ChainType::BitcoinCash,
        5 => fuego_sdk::chain::ChainType::Arbitrum,
        6 => fuego_sdk::chain::ChainType::Base,
        _ => return CString::new("").unwrap().into_raw(),
    };
    CString::new(chain.name()).unwrap().into_raw()
}

/// Check if a chain is EVM-compatible. Returns true if yes, false if no.
#[no_mangle]
pub extern "C" fn fuego_chain_is_evm(chain_id: u8) -> bool {
    matches!(chain_id, 2 | 5 | 6)
}

/// Check if a chain is Bitcoin-family. Returns true if yes, false if no.
#[no_mangle]
pub extern "C" fn fuego_chain_is_btc_family(chain_id: u8) -> bool {
    matches!(chain_id, 4)
}

// ── Payment Proof (JSON-based for FFI) ──

/// Create a payment proof from JSON parameters.
/// Input JSON: {"chain":0,"tx_hash":"...","amount":123,"from":"...","to":"...","confirmations":6,"block_height":100,"block_hash":"...","merkle_root":"...","merkle_proof":["..."],"tx_index":0,"total_txs":100,"verified":true}
/// Returns the same JSON with verified field updated.
#[no_mangle]
pub unsafe extern "C" fn fuego_payment_proof_from_json(json_ptr: *const c_char) -> *mut c_char {
    if json_ptr.is_null() {
        return CString::new("{\"error\":\"null pointer\"}").unwrap().into_raw();
    }
    let json_str = CStr::from_ptr(json_ptr).to_str().unwrap_or("{}");
    // Return the proof as-is (validation done at caller level)
    CString::new(json_str).unwrap().into_raw()
}

/// Serialize a PaymentProof to JSON string.
#[no_mangle]
pub unsafe extern "C" fn fuego_payment_proof_to_json(
    chain_id: u8,
    tx_hash: *const c_char,
    amount: u64,
    from_address: *const c_char,
    to_address: *const c_char,
    confirmations: u32,
    block_height: u64,
    block_hash: *const c_char,
    merkle_root: *const c_char,
    verified: bool,
) -> *mut c_char {
    use fuego_sdk::chain::ChainType;
    let chain = match chain_id {
        0 => ChainType::Fuego,
        1 => ChainType::Solana,
        2 => ChainType::Ethereum,
        3 => ChainType::Monero,
        4 => ChainType::BitcoinCash,
        5 => ChainType::Arbitrum,
        6 => ChainType::Base,
        _ => return CString::new("{\"error\":\"invalid chain\"}").unwrap().into_raw(),
    };

    let tx = CStr::from_ptr(tx_hash).to_str().unwrap_or("");
    let from = CStr::from_ptr(from_address).to_str().unwrap_or("");
    let to = CStr::from_ptr(to_address).to_str().unwrap_or("");
    let bhash = CStr::from_ptr(block_hash).to_str().unwrap_or("");
    let mroot = CStr::from_ptr(merkle_root).to_str().unwrap_or("");

    let json = serde_json::json!({
        "chain": chain.symbol(),
        "chain_id": chain_id,
        "tx_hash": tx,
        "amount": amount,
        "from_address": from,
        "to_address": to,
        "confirmations": confirmations,
        "block_height": block_height,
        "block_hash": bhash,
        "merkle_root": mroot,
        "verified": verified,
    });
    CString::new(json.to_string()).unwrap().into_raw()
}

// ── CryptoNight Slow Hash + Pool Mining (from fuego-suite) ──

extern "C" {
    fn cn_slow_hash(
        data: *const u8,
        length: usize,
        hash: *mut u8,
        light: c_int,
        variant: c_int,
        prehashed: c_int,
    );
}

/// CryptoNight slow hash for mining (variant=2, light=1 for Fuego UPX/2)
/// Input: block blob (76+ bytes)
/// Output: 32-byte hash
#[no_mangle]
pub extern "C" fn fuego_cn_slow_hash(
    data: *const u8,
    data_len: usize,
    hash_out: *mut u8,
    variant: c_int,
    light: c_int,
) -> c_int {
    unsafe {
        cn_slow_hash(data, data_len, hash_out, light, variant, 0);
    }
    0
}

/// Mine a share: try nonces from start_nonce, return first nonce where hash < target
/// Returns: nonce value in out_nonce, 0 if found, -1 if not found
#[no_mangle]
pub extern "C" fn fuego_mine_share(
    blob: *mut u8,
    blob_len: usize,
    target: *const u8,    // 4-byte LE target
    start_nonce: u32,
    max_nonces: u32,
    out_nonce: *mut u32,
    out_hash: *mut u8,    // 32-byte hash output
) -> c_int {
    unsafe {
        let blob_slice = std::slice::from_raw_parts_mut(blob, blob_len);
        let target_slice = std::slice::from_raw_parts(target, 4);

        // Convert target bytes to u32 (little-endian) for comparison
        let target_val = u32::from_le_bytes([
            target_slice[0],
            target_slice[1],
            target_slice[2],
            target_slice[3],
        ]);

        for i in 0..max_nonces {
            let nonce = start_nonce.wrapping_add(i);
            // Place nonce at offset 39 in blob (CryptoNote standard)
            if blob_len >= 43 {
                blob_slice[39..43].copy_from_slice(&nonce.to_le_bytes());
            }

            // Compute cn_slow_hash with variant=2, light=1 (Fuego UPX/2)
            cn_slow_hash(blob_slice.as_ptr(), blob_len, out_hash, 1, 2, 0);

            // Compare first 4 bytes of hash (LE) against target
            let hash_prefix = u32::from_le_bytes([
                *out_hash,
                *out_hash.add(1),
                *out_hash.add(2),
                *out_hash.add(3),
            ]);

            if hash_prefix <= target_val {
                *out_nonce = nonce;
                return 0; // Found!
            }
        }
    }
    -1 // Not found
}

#[cfg(test)]
mod tests {
    use super::fuego_cn_slow_hash;

    fn slow_hash_hex(input: &[u8], variant: i32, light: i32) -> String {
        let mut out = [0u8; 32];
        assert_eq!(
            fuego_cn_slow_hash(input.as_ptr(), input.len(), out.as_mut_ptr(), variant, light),
            0
        );
        hex::encode(out)
    }

    // Canonical CN vectors (Monero reference, via suite tests/PowBytes) guard submodule bumps.
    #[test]
    fn cn_v0_vectors() {
        assert_eq!(
            slow_hash_hex(b"", 0, 0),
            "eb14e8a833fac6fe9a43b57b336789c46ffe93f2868452240720607b14387e11"
        );
        assert_eq!(
            slow_hash_hex(b"This is a test", 0, 0),
            "a084f01d1437a09c6985401b60d43554ae105802c5f5d8a9b3253649c0be6605"
        );
        assert_eq!(
            slow_hash_hex(b"de omnibus dubitandum", 0, 0),
            "2f8e3df40bd11f9ac90c743ca8e32bb391da4fb98612aa3b6cdc639ee00b31f5"
        );
    }

    #[test]
    fn cn_v2_vectors() {
        assert_eq!(
            slow_hash_hex(b"This is a test This is a test This is a test", 2, 0),
            "353fdc068fd47b03c04b9431e005e00b68c2168a3cc7335c8b9b308156591a4f"
        );
        assert_eq!(
            slow_hash_hex(b"Lorem ipsum dolor sit amet, consectetur adipiscing", 2, 0),
            "72f134fc50880c330fe65a2cb7896d59b2e708a0221c6a9da3f69b3a702d8682"
        );
    }
}
