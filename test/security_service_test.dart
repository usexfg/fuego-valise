import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/services/security_service.dart';

void main() {
  group('SecurityService mnemonic', () {
    test('generateMnemonic produces valid BIP39 24-word phrase', () {
      final m = SecurityService.generateMnemonic();
      final words = m.trim().split(RegExp(r'\s+'));
      expect(words.length, 24);
      expect(SecurityService.validateMnemonic(m), isTrue);
    });

    test('generateMnemonic is non-deterministic', () {
      final a = SecurityService.generateMnemonic();
      final b = SecurityService.generateMnemonic();
      // Astronomically unlikely to collide with secure RNG
      expect(a, isNot(equals(b)));
    });

    test('validateMnemonic rejects garbage and placeholders', () {
      expect(SecurityService.validateMnemonic(''), isFalse);
      expect(
        SecurityService.validateMnemonic('not a real seed phrase at all'),
        isFalse,
      );
      expect(
        SecurityService.validateMnemonic(List.filled(24, 'abandon').join(' ')),
        isFalse, // invalid checksum for all-abandon 24-word
      );
    });

    test('validateMnemonic accepts known valid 12-word vector', () {
      // Standard BIP39 test vector (12 words)
      const m =
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      expect(SecurityService.validateMnemonic(m), isTrue);
    });

    test('mnemonicToVaultSeed returns 32 bytes', () {
      const m =
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final seed = SecurityService.mnemonicToVaultSeed(m);
      expect(seed.length, 32);
      // Deterministic for fixed mnemonic
      final seed2 = SecurityService.mnemonicToVaultSeed(m);
      expect(seed, orderedEquals(seed2));
    });

    test('mnemonicToVaultSeed rejects invalid mnemonic', () {
      expect(
        () => SecurityService.mnemonicToVaultSeed('not valid'),
        throwsArgumentError,
      );
    });
  });

  group('SecurityService random', () {
    test('secureRandomBytes length and entropy', () {
      final a = SecurityService.secureRandomBytes(32);
      final b = SecurityService.secureRandomBytes(32);
      expect(a.length, 32);
      expect(b.length, 32);
      expect(a, isNot(orderedEquals(b)));
    });
  });
}
