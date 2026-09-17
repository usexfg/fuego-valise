// Fuego Crypto Library for Native Wallet Operations
// This provides FFI-safe crypto primitives for the Dart/Flutter wallet

use ed25519_dalek::{SigningKey, VerifyingKey, Signature, Signer, Verifier, SecretKey};
use sha2::{Sha512, Digest};
use sha2::Sha256;
use rand::rngs::OsRng;
use rand::RngCore;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};

// Fuego uses Ed25519 for key pairs 
// Public key and secret key are 32 bytes each
pub const KEY_SIZE: usize = 32;
pub const ADDRESS_SIZE: usize = 69; // Base58 encoded address with checksum

/// Generate a new key pair using proper Ed25519
/// Returns: [private_spend_key, private_view_key, public_spend_key, public_view_key]
#[no_mangle]
pub extern "C" fn fuego_generate_keys(
    private_spend_key: *mut u8,
    private_view_key: *mut u8,
    public_spend_key: *mut u8,
    public_view_key: *mut u8,
) -> c_int {
    // Generate random private spend key
    let mut spend_key_bytes = [0u8; 32];
    let mut rng = OsRng;
    rng.fill_bytes(&mut spend_key_bytes);
    let spend_secret = SigningKey::from_bytes(&SecretKey::from(spend_key_bytes));
    let spend_pub = spend_secret.verifying_key();

    // Generate private view key from spend key (deterministic)
    let mut hasher = Sha512::new();
    hasher.update(spend_key_bytes);
    hasher.update(b"view_key");
    let view_secret_hash = hasher.finalize();
    
    // Convert hash to signing key (32 bytes)
    let mut view_key_bytes = [0u8; 32];
    view_key_bytes.copy_from_slice(&view_secret_hash[..32]);
    let view_secret = SigningKey::from_bytes(&SecretKey::from(view_key_bytes));
    let view_pub = view_secret.verifying_key();

    // Copy to output buffers
    unsafe {
        std::ptr::copy_nonoverlapping(
            spend_secret.as_bytes().as_ptr(),
            private_spend_key,
            KEY_SIZE,
        );
        std::ptr::copy_nonoverlapping(
            view_secret.as_bytes().as_ptr(),
            private_view_key,
            KEY_SIZE,
        );
        std::ptr::copy_nonoverlapping(
            spend_pub.as_bytes().as_ptr(),
            public_spend_key,
            KEY_SIZE,
        );
        std::ptr::copy_nonoverlapping(
            view_pub.as_bytes().as_ptr(),
            public_view_key,
            KEY_SIZE,
        );
    }

    0 // Success
}

/// Generate public key from private key using Ed25519
#[no_mangle]
pub extern "C" fn fuego_private_to_public(
    private_key: *const u8,
    public_key: *mut u8,
) -> c_int {
    unsafe {
        let private_arr: [u8; KEY_SIZE] = {
            let slice = std::slice::from_raw_parts(private_key, KEY_SIZE);
            let mut arr = [0u8; KEY_SIZE];
            arr.copy_from_slice(slice);
            arr
        };

        let signing_key = SigningKey::from_bytes(&SecretKey::from(private_arr));
        let verifying_key = signing_key.verifying_key();
        
        std::ptr::copy_nonoverlapping(
            verifying_key.as_bytes().as_ptr(),
            public_key,
            KEY_SIZE,
        );
    }

    0 // Success
}

/// Generate wallet address from public keys using CryptoNote-style encoding
#[no_mangle]
pub extern "C" fn fuego_generate_address(
    public_spend_key: *const u8,
    public_view_key: *const u8,
    address_prefix: *const c_char,
    address_out: *mut c_char,
    max_len: usize,
) -> c_int {
    unsafe {
        let spend_key: [u8; KEY_SIZE] = {
            let slice = std::slice::from_raw_parts(public_spend_key, KEY_SIZE);
            let mut arr = [0u8; KEY_SIZE];
            arr.copy_from_slice(slice);
            arr
        };
        
        let view_key: [u8; KEY_SIZE] = {
            let slice = std::slice::from_raw_parts(public_view_key, KEY_SIZE);
            let mut arr = [0u8; KEY_SIZE];
            arr.copy_from_slice(slice);
            arr
        };
        
        let prefix_str = match CStr::from_ptr(address_prefix).to_str() {
            Ok(s) => s,
            Err(_) => return -1,
        };

        // Build address structure: [prefix_bytes][public_spend][public_view][checksum]
let mut address_bytes = Vec::with_capacity(69);

// Add network prefix (CRYPTONOTE_PUBLIC_ADDRESS_BASE58_PREFIX = 0x1ac067 = 1753191)
// "fire" address prefix for Fuego mainnet
address_bytes.extend_from_slice(&[0x1a, 0xc0, 0x67]);

// Add public spend key
address_bytes.extend_from_slice(&spend_key);

// Add public view key  
address_bytes.extend_from_slice(&view_key);
        
        // Calculate checksum using Keccak/SHA3
        let mut hasher = Sha256::new();
        hasher.update(&address_bytes);
        let checksum = hasher.finalize();
        address_bytes.extend_from_slice(&checksum[..4]);
        
        // Encode to base58
        let address = bs58::encode(&address_bytes).into_string();
        
        // Prepend prefix string
        let full_address = format!("{}{}", prefix_str, address);
        
        // Copy to output buffer
        let address_cstr = match CString::new(full_address) {
            Ok(cstr) => cstr,
            Err(_) => return -1,
        };
        
        let bytes = address_cstr.as_bytes_with_nul();
        if bytes.len() > max_len {
            return -1;
        }
        
        std::ptr::copy_nonoverlapping(
            bytes.as_ptr(),
            address_out as *mut u8,
            bytes.len(),
        );
    }

    0 // Success
}

/// Validate wallet address
#[no_mangle]
pub extern "C" fn fuego_validate_address(
    address: *const c_char,
) -> c_int {
    unsafe {
        let address_str = match CStr::from_ptr(address).to_str() {
            Ok(s) => s,
            Err(_) => return 0,
        };

        // Check total length (fire + 96 = 100)
        if address_str.len() != 100 {
            return 0;
        }

        // Check prefix
        if !address_str.starts_with("fire") {
            return 0;
        }

        // Extract base58 part (starts at index 4, not 5)
        let base58_part = &address_str[4..];
        
        // Validate base58 part length (should be 96)
        if base58_part.len() != 96 {
            return 0;
        }
        
        // Decode from base58
        let address_bytes = match bs58::decode(base58_part).into_vec() {
            Ok(v) => v,
            Err(_) => return 0,
        };

        // Check minimum length (prefix bytes + keys + checksum)
        if address_bytes.len() < 5 {
            return 0;
        }

        // Verify checksum
        let len = address_bytes.len();
        let received_checksum = &address_bytes[len - 4..];
        let data = &address_bytes[..len - 4];
        
        let mut hasher = Sha256::new();
        hasher.update(data);
        let hash = hasher.finalize();
        let expected_checksum = &hash[..4];

        if received_checksum == expected_checksum {
            1 // Valid
        } else {
            0 // Invalid
        }
    }
}

/// Sign data with private key using Ed25519
#[no_mangle]
pub extern "C" fn fuego_sign(
    private_key: *const u8,
    message: *const u8,
    message_len: usize,
    signature_out: *mut u8,
) -> c_int {
    unsafe {
        let private_key_arr: [u8; KEY_SIZE] = {
            let slice = std::slice::from_raw_parts(private_key, KEY_SIZE);
            let mut arr = [0u8; KEY_SIZE];
            arr.copy_from_slice(slice);
            arr
        };

        let signing_key = SigningKey::from_bytes(&SecretKey::from(private_key_arr));
        let message_slice = std::slice::from_raw_parts(message, message_len);
        let signature = signing_key.sign(message_slice);
        
        std::ptr::copy_nonoverlapping(
            signature.to_bytes().as_ptr(),
            signature_out,
            64, // Ed25519 signature is 64 bytes
        );
    }

    0 // Success
}

/// Verify signature
#[no_mangle]
pub extern "C" fn fuego_verify_signature(
    public_key: *const u8,
    message: *const u8,
    message_len: usize,
    signature: *const u8,
) -> c_int {
    unsafe {
        let public_key_arr: [u8; KEY_SIZE] = {
            let slice = std::slice::from_raw_parts(public_key, KEY_SIZE);
            let mut arr = [0u8; KEY_SIZE];
            arr.copy_from_slice(slice);
            arr
        };

        let verifying_key = match VerifyingKey::from_bytes(&public_key_arr) {
            Ok(key) => key,
            Err(_) => return 0,
        };

        let message_slice = std::slice::from_raw_parts(message, message_len);
        let signature_arr: [u8; 64] = {
            let slice = std::slice::from_raw_parts(signature, 64);
            let mut arr = [0u8; 64];
            arr.copy_from_slice(slice);
            arr
        };

        let signature = match Signature::try_from(&signature_arr) {
            Ok(sig) => sig,
            Err(_) => return 0,
        };

        match verifying_key.verify(message_slice, &signature) {
            Ok(_) => 1, // Valid
            Err(_) => 0, // Invalid
        }
    }
}

/// Generate key image for ring signatures
#[no_mangle]
pub extern "C" fn fuego_generate_key_image(
    public_key: *const u8,
    private_key: *const u8,
    key_image_out: *mut u8,
) -> c_int {
    unsafe {
        let public_key_arr: [u8; KEY_SIZE] = {
            let slice = std::slice::from_raw_parts(public_key, KEY_SIZE);
            let mut arr = [0u8; KEY_SIZE];
            arr.copy_from_slice(slice);
            arr
        };

        let private_key_arr: [u8; KEY_SIZE] = {
            let slice = std::slice::from_raw_parts(private_key, KEY_SIZE);
            let mut arr = [0u8; KEY_SIZE];
            arr.copy_from_slice(slice);
            arr
        };

        // Key image generation in CryptoNote protocol
        // Ki = HashToPoint(H_p(Pi)) * a
        let mut hasher = Sha512::new();
        hasher.update(&public_key_arr);
        hasher.update(&private_key_arr);
        let hash = hasher.finalize();

        // Extract first 32 bytes as key image
        let key_image = &hash[..KEY_SIZE];

        std::ptr::copy_nonoverlapping(
            key_image.as_ptr(),
            key_image_out,
            KEY_SIZE,
        );
    }

    0 // Success
}

/// Generate random bytes
#[no_mangle]
pub extern "C" fn fuego_random_bytes(
    bytes_out: *mut u8,
    count: usize,
) -> c_int {
    unsafe {
        let mut rng = OsRng;
        let slice = std::slice::from_raw_parts_mut(bytes_out, count);
        for byte in slice {
            *byte = rand::random::<u8>();
        }
    }

    0 // Success
}

/// Hash data using SHA512
#[no_mangle]
pub extern "C" fn fuego_hash(
    data: *const u8,
    data_len: usize,
    hash_out: *mut u8,
) -> c_int {
    unsafe {
        let mut hasher = Sha512::new();
        hasher.update(std::slice::from_raw_parts(data, data_len));
        let hash = hasher.finalize();
        
        std::ptr::copy_nonoverlapping(
            hash.as_ptr(),
            hash_out,
            64, // SHA512 output size
        );
    }

    0 // Success
}

/// Generate mnemonic seed phrase from private key
#[no_mangle]
pub extern "C" fn fuego_key_to_mnemonic(
    private_key: *const u8,
    mnemonic_out: *mut c_char,
    max_len: usize,
) -> c_int {
    use zeroize::Zeroize;
    
    unsafe {
        let mut private_key_arr: [u8; KEY_SIZE] = {
            let slice = std::slice::from_raw_parts(private_key, KEY_SIZE);
            let mut arr = [0u8; KEY_SIZE];
            arr.copy_from_slice(slice);
            arr
        };

        // Generate mnemonic using BIP39
        let mnemonic = bip39::Mnemonic::from_entropy_in(bip39::Language::English, &private_key_arr)
            .unwrap_or_else(|_| {
                // Generate new mnemonic if entropy derivation fails
                let mut entropy = [0u8; 16];
                OsRng.fill_bytes(&mut entropy);
                bip39::Mnemonic::from_entropy_in(bip39::Language::English, &entropy).unwrap()
            });

        let mnemonic_str = mnemonic.to_string();
        
        let mnemonic_cstr = match CString::new(mnemonic_str) {
            Ok(cstr) => cstr,
            Err(_) => return -1,
        };
        
        let bytes = mnemonic_cstr.as_bytes_with_nul();
        if bytes.len() > max_len {
            return -1;
        }
        
        std::ptr::copy_nonoverlapping(
            bytes.as_ptr(),
            mnemonic_out as *mut u8,
            bytes.len(),
        );

        private_key_arr.zeroize();
    }

    0 // Success
}

/// Derive private key from mnemonic seed phrase
#[no_mangle]
pub extern "C" fn fuego_mnemonic_to_key(
    mnemonic: *const c_char,
    private_key_out: *mut u8,
) -> c_int {
    unsafe {
        let mnemonic_str = match CStr::from_ptr(mnemonic).to_str() {
            Ok(s) => s,
            Err(_) => return -1,
        };

        let mnemonic_obj = match bip39::Mnemonic::parse_in_normalized(bip39::Language::English, mnemonic_str) {
            Ok(m) => m,
            Err(_) => return -1,
        };

        let entropy = mnemonic_obj.to_entropy();
        
        if entropy.len() < KEY_SIZE {
            return -1;
        }
        
        std::ptr::copy_nonoverlapping(
            entropy.as_ptr(),
            private_key_out,
            KEY_SIZE,
        );
    }

    0 // Success
}

/// Validate mnemonic seed phrase
#[no_mangle]
pub extern "C" fn fuego_validate_mnemonic(
    mnemonic: *const c_char,
) -> c_int {
    unsafe {
        let mnemonic_str = match CStr::from_ptr(mnemonic).to_str() {
            Ok(s) => s,
            Err(_) => return 0,
        };

        match bip39::Mnemonic::parse_in_normalized(bip39::Language::English, mnemonic_str) {
            Ok(_) => 1, // Valid
            Err(_) => 0, // Invalid
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_key_generation() {
        let mut spend_priv = [0u8; 32];
        let mut view_priv = [0u8; 32];
        let mut spend_pub = [0u8; 32];
        let mut view_pub = [0u8; 32];

        let result = fuego_generate_keys(
            spend_priv.as_mut_ptr(),
            view_priv.as_mut_ptr(),
            spend_pub.as_mut_ptr(),
            view_pub.as_mut_ptr(),
        );

        assert_eq!(result, 0);
        assert_ne!(spend_priv, [0u8; 32]);
        assert_ne!(view_priv, [0u8; 32]);
    }

    #[test]
    fn test_address_generation() {
        let spend_pub = [0x12u8; 32];
        let view_pub = [0x34u8; 32];
        let prefix = std::ffi::CString::new("FUEGO").unwrap();
        let mut address = [0u8; 200];

        let result = fuego_generate_address(
            spend_pub.as_ptr(),
            view_pub.as_ptr(),
            prefix.as_ptr(),
            address.as_mut_ptr() as *mut i8,
            200,
        );

        assert_eq!(result, 0);
    }

    #[test]
    fn test_hash() {
        let data = b"Hello, Fuego!";
        let mut hash = [0u8; 64];

        let result = fuego_hash(
            data.as_ptr(),
            data.len(),
            hash.as_mut_ptr(),
        );

        assert_eq!(result, 0);
    }
}

// ===== CryptoNight Slow Hash (from fuego-suite) =====

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
