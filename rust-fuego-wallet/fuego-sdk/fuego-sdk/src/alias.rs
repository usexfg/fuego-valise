//! @alias registration (TX_EXTRA_ALIAS 0xEA), matching fuego-suite
//! TransactionExtraAliasRegistration and AliasIndex::isValidRegularAlias.

use crate::error::{Result, SdkError};
use crate::serialization::{add_alias_registration_extra, AliasRegistration};

/// aliasType 1: regular user alias (fee-bearing on mainnet).
pub const ALIAS_TYPE_REGULAR: u8 = 1;

/// Regular alias: exactly 8 characters from [a-z 0-9 &].
pub fn is_valid_regular_alias(alias: &str) -> bool {
    alias.len() == 8
        && alias
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'&')
}

/// Build the 0xEA extra for registering `alias` to `owner_address`.
///
/// `network_id` is 0: the suite accepts 0 unconditionally, while any non-zero
/// u32 is compared against a 64-bit hashed network id and can never match.
pub fn alias_registration_extra(
    alias: &str,
    owner_address: &str,
    spend_pub: &[u8; 32],
    view_pub: &[u8; 32],
) -> Result<Vec<u8>> {
    let alias = alias.to_ascii_lowercase();
    if !is_valid_regular_alias(&alias) {
        return Err(SdkError::Vault(
            "alias must be exactly 8 characters from a-z, 0-9 and &".into(),
        ));
    }
    let mut keys = [0u8; 64];
    keys[..32].copy_from_slice(spend_pub);
    keys[32..].copy_from_slice(view_pub);
    let reg = AliasRegistration {
        alias_hash: fuego_crypto::cn_fast_hash(alias.as_bytes()),
        address_hash: fuego_crypto::cn_fast_hash(&keys),
        alias,
        owner_address: owner_address.to_string(),
        alias_type: ALIAS_TYPE_REGULAR,
        network_id: 0,
    };
    let mut extra = Vec::new();
    add_alias_registration_extra(&mut extra, &reg);
    Ok(extra)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alias_rules_match_alias_index() {
        assert!(is_valid_regular_alias("fire2026"));
        assert!(is_valid_regular_alias("a&b&c&d1"));
        assert!(!is_valid_regular_alias("fire"));
        assert!(!is_valid_regular_alias("Fire2026"));
        assert!(!is_valid_regular_alias("fire_026"));
    }

    #[test]
    fn registration_extra_layout() {
        let extra = alias_registration_extra("FIRE2026", "fireX", &[1; 32], &[2; 32]).unwrap();
        assert_eq!(extra[0], 0xEA);
        let body = &extra[2..];
        assert_eq!(extra[1] as usize, body.len());
        assert_eq!(body[0], 1); // version
        assert_eq!(body[1], 8);
        assert_eq!(&body[2..10], b"fire2026");
        assert_eq!(&body[10..42], &fuego_crypto::cn_fast_hash(b"fire2026"));
        assert_eq!(body[74], 5);
        assert_eq!(&body[75..80], b"fireX");
        assert_eq!(&body[80..], &[ALIAS_TYPE_REGULAR, 0]);
    }
}
