use serde::{Serialize, Deserialize};
use sha3::{Digest, Keccak256};
use rand::rngs::OsRng;
use zeroize::Zeroize;

pub mod ref10;
pub mod ring;
pub mod subaddress;

pub use subaddress::{derive_subaddress_keys, SubaddressKeys};
pub use ring::{
    check_ring_signature, check_signature, cn_fast_hash, derive_public_key as derive_public_key_full,
    derive_secret_key, generate_key_derivation as generate_key_derivation_full,
    generate_key_image as generate_key_image_full, generate_ring_signature, generate_signature,
    hash_to_ec, hash_to_scalar, underive_public_key as underive_public_key_full, write_varint,
};

/// Fuego mainnet address prefix (CryptoNoteConfig.h:35).
pub const ADDRESS_BASE58_PREFIX: u64 = 1753191;
/// Fuego testnet address prefix (CryptoNoteConfig.h:452).
pub const TESTNET_ADDRESS_BASE58_PREFIX: u64 = 1075740;

// ── CryptoNote block-based Base58 (exact port of Base58.cpp) ───────

const ALPHABET: &[u8; 58] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const ALPHABET_SIZE: usize = 58;
const ENCODED_BLOCK_SIZES: [usize; 9] = [0, 2, 3, 5, 6, 7, 9, 10, 11];
const FULL_BLOCK_SIZE: usize = 8;
const FULL_ENCODED_BLOCK_SIZE: usize = 11;
const ADDR_CHECKSUM_SIZE: usize = 4;

/// Decode a big-endian byte slice into a u64.
fn uint_8be_to_64(data: &[u8]) -> u64 {
    assert!(data.len() >= 1 && data.len() <= 8);
    let mut res: u64 = 0;
    for &byte in data {
        res = (res << 8) | (byte as u64);
    }
    res
}

/// Encode a single block (1-8 bytes) into base58 characters.
fn encode_block(block: &[u8], size: usize) -> String {
    assert!(size >= 1 && size <= FULL_BLOCK_SIZE);
    let mut num = uint_8be_to_64(block);
    let encoded_size = ENCODED_BLOCK_SIZES[size];
    let mut result = vec![ALPHABET[0]; encoded_size];
    let mut i = encoded_size as i32 - 1;
    while num > 0 {
        let remainder = (num % ALPHABET_SIZE as u64) as usize;
        num /= ALPHABET_SIZE as u64;
        result[i as usize] = ALPHABET[remainder];
        i -= 1;
    }
    String::from_utf8(result).unwrap()
}

/// CryptoNote block-based Base58 encode (matching C++ Base58::encode).
pub fn cn_base58_encode(data: &[u8]) -> String {
    if data.is_empty() {
        return String::new();
    }
    let full_block_count = data.len() / FULL_BLOCK_SIZE;
    let last_block_size = data.len() % FULL_BLOCK_SIZE;
    let res_size = full_block_count * FULL_ENCODED_BLOCK_SIZE + ENCODED_BLOCK_SIZES[last_block_size];

    let mut res = vec![ALPHABET[0]; res_size];
    for i in 0..full_block_count {
        let block = &data[i * FULL_BLOCK_SIZE..(i + 1) * FULL_BLOCK_SIZE];
        let encoded = encode_block(block, FULL_BLOCK_SIZE);
        res[i * FULL_ENCODED_BLOCK_SIZE..(i + 1) * FULL_ENCODED_BLOCK_SIZE]
            .copy_from_slice(encoded.as_bytes());
    }
    if last_block_size > 0 {
        let offset = full_block_count * FULL_ENCODED_BLOCK_SIZE;
        let block = &data[full_block_count * FULL_BLOCK_SIZE..];
        let encoded = encode_block(block, last_block_size);
        res[offset..offset + ENCODED_BLOCK_SIZES[last_block_size]]
            .copy_from_slice(encoded.as_bytes());
    }
    String::from_utf8(res).unwrap()
}

/// CryptoNote block-based Base58 decode (matching C++ Base58::decode).
pub fn cn_base58_decode(encoded: &str) -> Option<Vec<u8>> {
    if encoded.is_empty() {
        return Some(Vec::new());
    }
    let full_block_count = encoded.len() / FULL_ENCODED_BLOCK_SIZE;
    let remainder_size = encoded.len() % FULL_ENCODED_BLOCK_SIZE;

    let mut last_block_size = 0;
    if remainder_size > 0 {
        for (i, &size) in ENCODED_BLOCK_SIZES.iter().enumerate().skip(1) {
            if size == remainder_size {
                last_block_size = i;
                break;
            }
        }
        if last_block_size == 0 && remainder_size != 0 {
            return None;
        }
    }

    let total_bytes = full_block_count * FULL_BLOCK_SIZE + last_block_size;
    let mut result = vec![0u8; total_bytes];
    let mut pos = 0;

    for i in 0..full_block_count {
        let block_start = i * FULL_ENCODED_BLOCK_SIZE;
        let block = &encoded[block_start..block_start + FULL_ENCODED_BLOCK_SIZE];
        let decoded = decode_block(block, FULL_BLOCK_SIZE)?;
        result[pos..pos + FULL_BLOCK_SIZE].copy_from_slice(&decoded);
        pos += FULL_BLOCK_SIZE;
    }

    if last_block_size > 0 {
        let block = &encoded[full_block_count * FULL_ENCODED_BLOCK_SIZE..];
        let decoded = decode_block(block, last_block_size)?;
        result[pos..pos + last_block_size].copy_from_slice(&decoded);
    }

    Some(result)
}

fn decode_block(encoded: &str, size: usize) -> Option<Vec<u8>> {
    let mut num: u64 = 0;
    for c in encoded.chars() {
        let digit = ALPHABET.iter().position(|&b| b == c as u8)?;
        // Overflow means the block is not valid base58 (Base58.cpp rejects it too).
        num = num.checked_mul(ALPHABET_SIZE as u64)?.checked_add(digit as u64)?;
    }
    if size < FULL_BLOCK_SIZE && num >> (8 * size) != 0 {
        return None;
    }
    let mut block = vec![0u8; size];
    for i in (0..size).rev() {
        if num == 0 {
            break;
        }
        block[i] = (num & 0xFF) as u8;
        num >>= 8;
    }
    Some(block)
}

// ── Key types ──────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Zeroize)]
#[zeroize(drop)]
pub struct Keypair {
    pub secret: [u8; 32],
    pub public: [u8; 32],
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct PublicKey(pub [u8; 32]);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct Address(pub String);

// ── Key generation (matching C++ generate_keys) ────────────────────

impl Keypair {
    /// Generate a random Ed25519 keypair (matching C++ generate_keys).
    pub fn generate() -> Self {
        let secret = ref10::random_scalar(&mut OsRng);
        Self::from_secret(secret)
    }

    /// Create keypair from 32 secret bytes, reduced mod l (CryptoNote style, no
    /// clamping). The stored secret is the reduced scalar: every CryptoNote
    /// routine (generate_key_derivation, derive_secret_key, key images) rejects
    /// unreduced scalars via sc_check, and `public` is computed from it.
    pub fn from_secret(secret: [u8; 32]) -> Self {
        let mut s = secret;
        ref10::sc_reduce32(&mut s);
        let mut point = ref10::GeP3::default();
        ref10::ge_scalarmult_base(&mut point, &s);
        let mut pk = [0u8; 32];
        ref10::ge_p3_tobytes(&mut pk, &point);
        Keypair { secret: s, public: pk }
    }

    pub fn public_key(&self) -> PublicKey {
        PublicKey(self.public)
    }

    /// Sign a message using Ed25519.
    pub fn sign(&self, message: &[u8]) -> ed25519_dalek::Signature {
        use ed25519_dalek::Signer;
        let sk = ed25519_dalek::SigningKey::from_bytes(&self.secret);
        sk.sign(message)
    }
}

// ── PublicKey operations ───────────────────────────────────────────

impl PublicKey {
    pub fn verify(&self, message: &[u8], signature: &ed25519_dalek::Signature) -> bool {
        use ed25519_dalek::Verifier;
        ed25519_dalek::VerifyingKey::from_bytes(&self.0)
            .map(|vk| vk.verify(message, signature).is_ok())
            .unwrap_or(false)
    }
}

// ── CryptoNote key derivation (matching C++ crypto.cpp) ────────────

pub type KeyDerivation = [u8; 32];

/// generate_key_derivation: derivation = 8 * (key1 * scalar2 mod l).
/// Exact C++ semantics: sc_check on key2, ge_frombytes on key1.
pub fn generate_key_derivation(key1: &PublicKey, secret2: &[u8; 32]) -> Option<KeyDerivation> {
    generate_key_derivation_full(&key1.0, secret2)
}

/// Derive a one-time output key: P = Hs(D || varint(i)) * G + base.
/// `base` is the recipient's spend public key.
pub fn derive_public_key(derivation: &KeyDerivation, output_index: u64, base: &[u8; 32]) -> Option<PublicKey> {
    derive_public_key_full(derivation, output_index, base).map(PublicKey)
}

/// Underive: base = P - Hs(D || varint(i)) * G.
pub fn underive_public_key(derivation: &KeyDerivation, output_index: u64, output_key: &PublicKey) -> Option<PublicKey> {
    underive_public_key_full(derivation, output_index, &output_key.0).map(PublicKey)
}

/// Generate key image for ring signatures: KI = x * H_p(P).
pub fn generate_key_image(key: &PublicKey, secret: &[u8; 32]) -> PublicKey {
    PublicKey(generate_key_image_full(&key.0, secret))
}

// ── Fuego address generation (matching Base58::encode_addr) ────────

pub fn make_address(spend_pub: &[u8; 32], view_pub: &[u8; 32]) -> Address {
    make_address_with_prefix(spend_pub, view_pub, ADDRESS_BASE58_PREFIX)
}

/// Address generation with an explicit network prefix.
pub fn make_address_with_prefix(spend_pub: &[u8; 32], view_pub: &[u8; 32], prefix: u64) -> Address {
    // Step 1: varint-encode the prefix
    let mut buf = varint_encode(prefix);
    // Step 2: append spend + view public keys (64 bytes)
    buf.extend_from_slice(spend_pub);
    buf.extend_from_slice(view_pub);
    // Step 3: keccak256 checksum of (prefix || keys)
    let hash = Keccak256::digest(&buf);
    buf.extend_from_slice(&hash[..ADDR_CHECKSUM_SIZE]);
    // Step 4: CryptoNote block-based base58 encode
    Address(cn_base58_encode(&buf))
}

/// Parse a Fuego address into (spend pubkey, view pubkey). Validates base58,
/// checksum and network prefix. The leading "fire" (mainnet) / "TEST"
/// (testnet) is how the varint prefix encodes in base58, not a separate tag,
/// so the whole string is decoded.
pub fn parse_address(address: &str) -> Option<([u8; 32], [u8; 32])> {
    let decoded = cn_base58_decode(address)?;
    // varint prefix (3 bytes for both networks) + 64 key bytes + 4 checksum bytes.
    if decoded.len() <= ADDR_CHECKSUM_SIZE {
        return None;
    }
    let payload = &decoded[..decoded.len() - ADDR_CHECKSUM_SIZE];
    let checksum = &decoded[decoded.len() - ADDR_CHECKSUM_SIZE..];
    let hash = Keccak256::digest(payload);
    if &hash[..ADDR_CHECKSUM_SIZE] != checksum {
        return None;
    }
    let (prefix, prefix_len) = varint_decode(payload);
    if prefix != ADDRESS_BASE58_PREFIX && prefix != TESTNET_ADDRESS_BASE58_PREFIX {
        return None;
    }
    let rest = &payload[prefix_len..];
    if rest.len() != 64 {
        return None;
    }
    let mut spend = [0u8; 32];
    let mut view = [0u8; 32];
    spend.copy_from_slice(&rest[..32]);
    view.copy_from_slice(&rest[32..]);
    Some((spend, view))
}

/// Validate a Fuego address string.
/// Returns true if the address is a valid CryptoNote Base58 encoded address
/// with the correct prefix and checksum.
pub fn is_valid_address(address: &str) -> bool {
    let decoded = match cn_base58_decode(address) {
        Some(d) => d,
        None => return false,
    };
    if decoded.len() < 71 {
        return false;
    }
    let payload = &decoded[..decoded.len() - ADDR_CHECKSUM_SIZE];
    let checksum = &decoded[decoded.len() - ADDR_CHECKSUM_SIZE..];
    let hash = Keccak256::digest(payload);
    if &hash[..ADDR_CHECKSUM_SIZE] != checksum {
        return false;
    }
    let (prefix, _) = varint_decode(&decoded);
    prefix == ADDRESS_BASE58_PREFIX || prefix == TESTNET_ADDRESS_BASE58_PREFIX
}

fn varint_decode(data: &[u8]) -> (u64, usize) {
    let mut result: u64 = 0;
    let mut shift = 0;
    let mut i = 0;
    for &byte in data {
        result |= ((byte & 0x7F) as u64) << shift;
        i += 1;
        if byte & 0x80 == 0 {
            break;
        }
        shift += 7;
    }
    (result, i)
}

// ── Internal helpers ────────────────────────────────────────────────

fn varint_encode(mut value: u64) -> Vec<u8> {
    let mut buf = Vec::new();
    while value >= 0x80 {
        buf.push(((value & 0x7F) | 0x80) as u8);
        value >>= 7;
    }
    buf.push(value as u8);
    buf
}

impl std::fmt::Display for Address {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl From<String> for Address {
    fn from(s: String) -> Self { Address(s) }
}

// ── Tests ───────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_base58_block_encode() {
        // 8 zero bytes should encode to "11111111111" (11 '1' chars)
        let block = [0u8; 8];
        let encoded = encode_block(&block, 8);
        assert_eq!(encoded, "11111111111");

        // 8 bytes of 0xFF should encode to "jpXCZedGfVQ" (from C++ test vector)
        let block = [0xFFu8; 8];
        let encoded = encode_block(&block, 8);
        assert_eq!(encoded, "jpXCZedGfVQ");
    }

    #[test]
    fn test_cn_base58_encode_empty() {
        assert_eq!(cn_base58_encode(b""), "");
    }

    #[test]
    fn test_varint() {
        // 18 -> [0x12] (Monero prefix)
        assert_eq!(varint_encode(18), vec![0x12]);
        // 1753191 -> [0xE7, 0x80, 0x6B]
        assert_eq!(varint_encode(1753191), vec![0xE7, 0x80, 0x6B]);
    }

    #[test]
    fn test_keccak_matches_cn_fast_hash() {
        let hash = Keccak256::digest(b"");
        let expected = "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";
        assert_eq!(hex::encode(hash), expected);
    }

    #[test]
    fn test_address_format() {
        let spend = Keypair::generate();
        let view = Keypair::generate();
        let addr = make_address(&spend.public, &view.public);
        eprintln!("Address:   {}", addr.0);
        eprintln!("Starts with 'fire': {}", addr.0.starts_with("fire"));
        assert!(!addr.0.is_empty());
        assert!(addr.0.len() > 80);
    }

    #[test]
    fn parse_address_round_trips_both_networks() {
        for i in 0..16u8 {
            let spend = Keypair::from_secret([i; 32]).public;
            let view = Keypair::from_secret([i.wrapping_add(77); 32]).public;
            let main = make_address(&spend, &view).0;
            assert!(main.starts_with("fire"));
            assert_eq!(parse_address(&main), Some((spend, view)));
            let test = make_address_with_prefix(&spend, &view, TESTNET_ADDRESS_BASE58_PREFIX).0;
            assert!(test.starts_with("TEST"));
            assert_eq!(parse_address(&test), Some((spend, view)));
        }
    }

    #[test]
    fn parse_address_rejects_damage_without_panicking() {
        let addr = make_address(&Keypair::from_secret([3; 32]).public, &Keypair::from_secret([4; 32]).public).0;
        assert_eq!(parse_address(&addr[4..]), None, "prefix stripped");
        let mut flipped = addr.clone().into_bytes();
        flipped[20] = if flipped[20] == b'z' { b'y' } else { b'z' };
        assert_eq!(parse_address(std::str::from_utf8(&flipped).unwrap()), None, "checksum");
        assert_eq!(parse_address("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"), None);
    }

    #[test]
    fn test_address_length() {
        // 71 bytes input -> 8 full blocks (64 bytes) + 1 partial (7 bytes)
        // 8 * 11 + 10 = 98 chars
        let spend = Keypair::generate();
        let view = Keypair::generate();
        let addr = make_address(&spend.public, &view.public);
        assert_eq!(addr.0.len(), 98);
    }
}
