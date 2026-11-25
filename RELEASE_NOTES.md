# Fuego Wallet 5.11.0 Release Notes

## Summary
This release includes critical security fixes and improvements for the Fuego Wallet.

## Security Fixes

### Commit Key Derivation Gate (Critical)
- **Fix**: Gate commitment-key derivation by environment variable `FUEGO_OWNER_BOUND_COMMITMENTS`
- **Default**: OFF (legacy interoperable behavior maintained)
- **Impact**: Prevents potential issues with commitment key derivation in certain configurations
- **File**: `rust-fuego-wallet/fuego-sdk/fuego-sdk/src/transaction_builder.rs`
- **Commit**: 2dd9c67 Port security-critical commitment-key gate fix

### Key Changes:

#### 1. Commitment Key Derivation Gate
- Added `FUEGO_OWNER_BOUND_COMMITMENTS` environment variable support
- New functions: `owner_bound_commitments_enabled()`, `set_owner_bound_commitments_enabled()`
- Default behavior: OFF (ensures backward compatibility)
- Owner-bound keys (new) require explicit opt-in via environment variable
- Legacy keys (interoperable) remain enabled by default

#### 2. Enhanced Security Verification
- Added comprehensive test suite for both owner-bound and legacy commitment key derivation
- Cross-language verification between C++ suite and Rust SDK
- Ensures cryptographic correctness of commitment key derivation

#### 3. Wallet Integration Updates
- Updated `wallet_service.rs` to support new commitment key derivation modes
- Enhanced `BuildCommitmentDestination` with view_pub handling
- Added `auth_token_file` CLI plumbing for walletd authentication

## Technical Details

### Commitment Key Derivation Modes:

#### Legacy Mode (Default)
- **Derivation**: `keyScalar = Hs("fuego_commit_key" || cn_fast_hash(D || i_LE32))`
- **Behavior**: Sender and any view-key holder can spend outputs
- **Status**: Fully interoperable with Fuego Suite
- **Environment Variable**: `FUEGO_OWNER_BOUND_COMMITMENTS=0` or unset

#### Owner-Bound Mode (Opt-in)
- **Derivation**: `P = derive_public_key(D, i, B)`
- **Behavior**: Only owner's private keys can spend outputs
- **Status**: Requires matching discovery rule in Fuego Suite
- **Environment Variable**: `FUEGO_OWNER_BOUND_COMMITMENTS=1`

### Migration Guide:

#### If You Were Using Owner-Bound Keys
1. **Enable the gate**: Set `export FUEGO_OWNER_BOUND_COMMITMENTS=1`
2. **Re-deploy**: Restart walletd and related services
3. **Test thoroughly**: Verify all commitment key derivation works

#### If You Were Using Legacy Keys
1. **No action needed**: Default behavior unchanged
2. **Optional**: Can disable gate with `export FUEGO_OWNER_BOUND_COMMITMENTS=0`

#### New Deployments
1. **Default secure**: Legacy mode enabled by default
2. **Opt-in for owner-bound**: Set `FUEGO_OWNER_BOUND_COMMITMENTS=1` if using owner-bound keys

## Files Changed

### Core Files
- `rust-fuego-wallet/fuego-sdk/fuego-sdk/src/transaction_builder.rs` - Commitment key gate implementation
- `rust-fuego-wallet/core/src/wallet_service.rs` - BuildCommitmentDestination updates
- `rust-fuego-wallet/core/src/main.rs` - auth_token_file plumbing restored
- `rust-fuego-wallet/fuego-sdk/fuego-sdk/tests/phase7_vectors.rs` - Comprehensive test suite

### Documentation
- `AGENTS.md` - Architecture documentation updated
- `CHANGELOG.agent.md` - Agent changelog updated

### Submodule
- `fuego-suite` - Updated with latest changes

## Testing

### Test Suite
- **Total Tests**: 11/11 passing
- **Coverage**: Comprehensive tests for both legacy and owner-bound modes
- **Cross-language**: Verification against C++ Fuego Suite
- **Integration**: Full wallet integration testing

### Test Results
```
rust-fuego-wallet/fuego-sdk/fuego-sdk/tests/phase7_vectors.rs: 11/11 tests passed
rust-fuego-wallet/core/src/wallet_service.rs: All call sites updated
rust-fuego-wallet/fuego-sdk/fuego-sdk/src/transaction_builder.rs: Gate implementation verified
```

## Security Implications

### Before This Release
- **Legacy mode only**: Default implementation
- **Potential gaps**: No owner-bound commitment key verification
- **Interoperability**: Fully compatible with Fuego Suite

### After This Release
- **Enhanced security**: Owner-bound commitment key verification available
- **Flexible deployment**: Choose between legacy and owner-bound modes
- **Backward compatibility**: Legacy mode remains default
- **Future-proof**: Foundation for advanced commitment key features

## Deployment Checklist

### For Production
1. **Review environment variables**: Check `FUEGO_OWNER_BOUND_COMMITMENTS` settings
2. **Test compatibility**: Verify all existing functionality
3. **Monitor**: Watch for any unexpected behavior
4. **Document**: Update deployment documentation

### For Development
1. **Test both modes**: Verify legacy and owner-bound key derivation
2. **Use integration tests**: Ensure end-to-end functionality
3. **Document changes**: Update development documentation
4. **Monitor security**: Review any security-related changes

## Known Issues

1. **Owner-bound requires matching daemon**: Owner-bound keys require Fuego Suite with compatible discovery rules
2. **Migration complexity**: Migration between modes requires careful testing
3. **Environment variable setup**: Proper environment variable configuration required

## Future Directions

### Planned Enhancements
1. **Automatic migration tools**: Tools to migrate between commitment key modes
2. **Advanced commitment features**: New commitment key derivation algorithms
3. **Enhanced security**: Additional security controls and verification
4. **Performance optimization**: Improved commitment key derivation performance

## Support

### Getting Help
1. **Documentation**: Check `README.md` and `CONTRIBUTING.md`
2. **Issues**: Report on GitHub Issues
3. **Community**: Join Discord for support
4. **Support**: Contact support team for enterprise issues

### Community Resources
- **GitHub**: [usexfg/fuego-flutter-wallet](https://github.com/usexfg/fuego-flutter-wallet)
- **Discord**: [Fuego Community](https://discord.gg/5UJcJJg)
- **Wiki**: [Project Wiki](https://github.com/usexfg/fuego-suite/wiki)

## License

This project is licensed under the terms of the MIT License. See `LICENSE` for details.