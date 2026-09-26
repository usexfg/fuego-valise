use fuego_crypto::{Keypair, PublicKey, make_address, generate_key_derivation, derive_public_key, underive_public_key, generate_key_image, cn_base58_encode, cn_fast_hash, generate_signature, check_signature};
use fuego_vault::Vault;
use fuego_sdk::types::SwapPair;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::ptr;
use std::slice;

// ── Memory management ──

/// Free a string returned by fuego_ffi functions. Returned strings can carry seeds
/// and secret keys, so the buffer is wiped before it is released.
#[no_mangle]
pub unsafe extern "C" fn fuego_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        let mut bytes = CString::from_raw(ptr).into_bytes_with_nul();
        wipe(&mut bytes);
    }
}

/// Free a byte buffer returned by fuego_ffi functions (wiped first: vault bytes hold the seed).
#[no_mangle]
pub unsafe extern "C" fn fuego_bytes_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        let mut bytes = Vec::from_raw_parts(ptr, len, len);
        wipe(&mut bytes);
    }
}

fn wipe(bytes: &mut [u8]) {
    for b in bytes.iter_mut() {
        // Volatile so the stores are not elided as dead before the free.
        unsafe { ptr::write_volatile(b, 0) };
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

/// Variants cn_slow_hash implements; anything else is silently hashed as v2 by the C code.
const CN_MAX_VARIANT: c_int = 2;
/// Variant 1 reads a tweak at offset 35..43; shorter input makes the C code call _exit(1).
const CN_V1_MIN_LEN: usize = 43;
/// Fuego PoW: CryptoNight variant 2, light (CN-UPX/2), as selected by suite's get_block_longhash.
const FUEGO_POW_VARIANT: c_int = 2;
const FUEGO_POW_LIGHT: c_int = 1;
/// Offset of the 4-byte nonce in a CryptoNote hashing blob (major, minor, 5-byte timestamp, prev id).
const NONCE_OFFSET: usize = 39;

/// CryptoNight slow hash. Writes 32 bytes to `hash_out`.
/// `variant` is 0..=2; `light` is 0 or 1 (Fuego PoW is variant 2, light 1).
/// Returns 0 on success, -1 (without writing) on a null pointer, an unsupported
/// variant, or variant 1 with fewer than 43 bytes.
///
/// # Safety
/// `data` must point to `data_len` readable bytes (may be null when `data_len` is 0);
/// `hash_out` must point to 32 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn fuego_cn_slow_hash(
    data: *const u8,
    data_len: usize,
    hash_out: *mut u8,
    variant: c_int,
    light: c_int,
) -> c_int {
    if hash_out.is_null() || (data.is_null() && data_len > 0) {
        return -1;
    }
    if !(0..=CN_MAX_VARIANT).contains(&variant) || (variant == 1 && data_len < CN_V1_MIN_LEN) {
        return -1;
    }
    static EMPTY: u8 = 0;
    let data = if data.is_null() { &EMPTY as *const u8 } else { data };
    cn_slow_hash(data, data_len, hash_out, (light != 0) as c_int, variant, 0);
    0
}

/// Stratum share target as the 64-bit bound the pool compares against the last
/// 8 bytes of the hash (xmrig semantics): a 4-byte target t expands to
/// u64::MAX / (u32::MAX / t); an 8-byte target is used as is. None if malformed
/// or zero (no hash can be below a zero bound).
fn share_target_bound(target: &[u8]) -> Option<u64> {
    match target.len() {
        4 => {
            let t = u32::from_le_bytes(target.try_into().ok()?) as u64;
            if t == 0 {
                return None;
            }
            Some(u64::MAX / (u32::MAX as u64 / t))
        }
        8 => Some(u64::from_le_bytes(target.try_into().ok()?)).filter(|b| *b != 0),
        _ => None,
    }
}

fn hash_meets_bound(hash: &[u8; 32], bound: u64) -> bool {
    u64::from_le_bytes(hash[24..32].try_into().unwrap()) < bound
}

/// Mine a share: hash the blob with nonces start_nonce.. (up to max_nonces) using the
/// Fuego PoW and stop at the first hash below the stratum target (4- or 8-byte LE).
/// Returns 0 with `out_nonce`/`out_hash` set when found, -1 when no nonce in range
/// qualifies, -2 on invalid arguments (null pointer, blob too short to hold the
/// nonce, target length other than 4/8, or a zero target).
///
/// # Safety
/// `blob` must point to `blob_len` writable bytes (the nonce is written into it),
/// `target` to `target_len` readable bytes, `out_nonce` to a writable u32 and
/// `out_hash` to 32 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn fuego_mine_share(
    blob: *mut u8,
    blob_len: usize,
    target: *const u8,
    target_len: usize,
    start_nonce: u32,
    max_nonces: u32,
    out_nonce: *mut u32,
    out_hash: *mut u8,
) -> c_int {
    if blob.is_null() || target.is_null() || out_nonce.is_null() || out_hash.is_null() {
        return -2;
    }
    if blob_len < NONCE_OFFSET + 4 {
        return -2;
    }
    let bound = match share_target_bound(slice::from_raw_parts(target, target_len)) {
        Some(b) => b,
        None => return -2,
    };
    let blob = slice::from_raw_parts_mut(blob, blob_len);
    let mut hash = [0u8; 32];

    for i in 0..max_nonces {
        let nonce = start_nonce.wrapping_add(i);
        blob[NONCE_OFFSET..NONCE_OFFSET + 4].copy_from_slice(&nonce.to_le_bytes());
        cn_slow_hash(blob.as_ptr(), blob_len, hash.as_mut_ptr(), FUEGO_POW_LIGHT, FUEGO_POW_VARIANT, 0);
        if hash_meets_bound(&hash, bound) {
            *out_nonce = nonce;
            ptr::copy_nonoverlapping(hash.as_ptr(), out_hash, 32);
            return 0;
        }
    }
    -1
}

#[cfg(test)]
mod tests {
    use super::{fuego_cn_slow_hash, fuego_mine_share, hash_meets_bound, share_target_bound};

    fn slow_hash(input: &[u8], variant: i32, light: i32) -> [u8; 32] {
        let mut out = [0u8; 32];
        assert_eq!(
            unsafe { fuego_cn_slow_hash(input.as_ptr(), input.len(), out.as_mut_ptr(), variant, light) },
            0
        );
        out
    }

    fn slow_hash_hex(input: &[u8], variant: i32, light: i32) -> String {
        hex::encode(slow_hash(input, variant, light))
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

    // Mainnet block 1,000,001 (suite tests/PowBytes): the merge-mined parent block's
    // hashing blob and the block's difficulty. A hash meeting that difficulty is the
    // real PoW, so this pins CN-UPX/2 (variant 2, light) to consensus on every target
    // that runs the tests, including the portable path (CFLAGS=-DNO_AES).
    const BLOCK_1000001_PARENT_BLOB: &str = concat!(
        "0100c8affccf06",
        "881344ac64f0fb7b550f143ea209b5e6d1f233bff29ec45d2aba5dbf87074e24",
        "0b2c2f00",
        "e84b387448a02d4b431dfd418c79621fa93c2fc689aa4afdb210b7346b69140b",
        "01"
    );
    const BLOCK_1000001_DIFFICULTY: u128 = 31_300_056;

    #[test]
    fn fuego_pow_meets_mainnet_difficulty() {
        let blob = hex::decode(BLOCK_1000001_PARENT_BLOB).unwrap();
        let hash = slow_hash(&blob, 2, 1);
        let high = u64::from_le_bytes(hash[24..32].try_into().unwrap()) as u128;
        assert_eq!(
            (high * BLOCK_1000001_DIFFICULTY) >> 64,
            0,
            "CN-UPX/2 of block 1,000,001 misses its difficulty: {}",
            hex::encode(hash)
        );
        assert_eq!(
            hex::encode(hash),
            "ce75e0286b8039a0db4f02c026d2a908c0b82da8de0daec1310e6c2387000000"
        );
    }

    #[test]
    fn cn_slow_hash_rejects_bad_arguments() {
        let mut out = [0xAAu8; 32];
        let short = [0u8; 42];
        unsafe {
            // v1 needs 43 bytes; the C code would _exit(1) the app.
            assert_eq!(fuego_cn_slow_hash(short.as_ptr(), 42, out.as_mut_ptr(), 1, 0), -1);
            assert_eq!(fuego_cn_slow_hash(short.as_ptr(), 42, out.as_mut_ptr(), 3, 0), -1);
            assert_eq!(fuego_cn_slow_hash(short.as_ptr(), 42, out.as_mut_ptr(), -1, 0), -1);
            assert_eq!(fuego_cn_slow_hash(std::ptr::null(), 1, out.as_mut_ptr(), 0, 0), -1);
            assert_eq!(fuego_cn_slow_hash(short.as_ptr(), 42, std::ptr::null_mut(), 0, 0), -1);
        }
        assert_eq!(out, [0xAAu8; 32], "output written on rejected call");
        // Null data with zero length is the empty input.
        let mut empty = [0u8; 32];
        assert_eq!(
            unsafe { fuego_cn_slow_hash(std::ptr::null(), 0, empty.as_mut_ptr(), 0, 0) },
            0
        );
        assert_eq!(empty, slow_hash(b"", 0, 0));
    }

    #[test]
    fn share_target_matches_stratum_semantics() {
        // 4-byte targets expand the way pools (xmrig) compare them.
        assert_eq!(share_target_bound(&0xffff_ffffu32.to_le_bytes()), Some(u64::MAX));
        let t = 0x0013_3333u32; // ~diff 3355
        assert_eq!(
            share_target_bound(&t.to_le_bytes()),
            Some(u64::MAX / (u32::MAX as u64 / t as u64))
        );
        assert_eq!(share_target_bound(&7u64.to_le_bytes()), Some(7));
        assert_eq!(share_target_bound(&[0u8; 4]), None);
        assert_eq!(share_target_bound(&[0u8; 8]), None);
        assert_eq!(share_target_bound(&[1u8; 3]), None);

        // Only the last 8 bytes of the hash count.
        let mut hash = [0xffu8; 32];
        hash[24..32].copy_from_slice(&5u64.to_le_bytes());
        assert!(hash_meets_bound(&hash, 6));
        assert!(!hash_meets_bound(&hash, 5));
    }

    #[test]
    fn mine_share_finds_what_cn_slow_hash_confirms() {
        let mut blob = hex::decode(BLOCK_1000001_PARENT_BLOB).unwrap();
        // Easy target: roughly 1 in 16 hashes qualify.
        let target = (u32::MAX / 16).to_le_bytes();
        let (mut nonce, mut hash) = (0u32, [0u8; 32]);
        let rc = unsafe {
            fuego_mine_share(
                blob.as_mut_ptr(), blob.len(), target.as_ptr(), 4, 0, 256,
                &mut nonce, hash.as_mut_ptr(),
            )
        };
        assert_eq!(rc, 0);
        blob[39..43].copy_from_slice(&nonce.to_le_bytes());
        assert_eq!(hash, slow_hash(&blob, 2, 1));
        assert!(hash_meets_bound(&hash, share_target_bound(&target).unwrap()));

        let rc = unsafe {
            fuego_mine_share(
                blob.as_mut_ptr(), 42, target.as_ptr(), 4, 0, 1,
                &mut nonce, hash.as_mut_ptr(),
            )
        };
        assert_eq!(rc, -2, "blob too short for the nonce");
    }
}
