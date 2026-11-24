import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/models/fuego_address.dart';
import 'package:fuego/models/subaddress.dart';

void main() {
  group('ParsedFuegoAddress.fromNativeJson', () {
    test('reads a funsa sub-address result', () {
      final parsed = ParsedFuegoAddress.fromNativeJson(
        '{"valid":true,"is_subaddress":true,"testnet":false}',
      );
      expect(parsed?.isSubaddress, isTrue);
      expect(parsed?.testnet, isFalse);
    });

    test('refuses invalid, malformed and incomplete results', () {
      for (final json in [
        '{"valid":false}',
        'not json',
        '[]',
        '{"valid":true}',
        '{"valid":"true","is_subaddress":false,"testnet":false}',
        '{"valid":true,"is_subaddress":1,"testnet":false}',
      ]) {
        expect(ParsedFuegoAddress.fromNativeJson(json), isNull, reason: json);
      }
    });
  });

  group('recipientAddressProblemFor', () {
    const mainnetFunsa = ParsedFuegoAddress(isSubaddress: true, testnet: false);
    const testnetStandard = ParsedFuegoAddress(
      isSubaddress: false,
      testnet: true,
    );

    test('accepts an address of the wallet network', () {
      expect(
        recipientAddressProblemFor(mainnetFunsa, walletOnTestnet: false),
        isNull,
      );
      expect(
        recipientAddressProblemFor(testnetStandard, walletOnTestnet: true),
        isNull,
      );
    });

    test('refuses unparsed addresses and the other network', () {
      expect(
        recipientAddressProblemFor(null, walletOnTestnet: false),
        contains('Invalid address'),
      );
      expect(
        recipientAddressProblemFor(mainnetFunsa, walletOnTestnet: true),
        contains('mainnet address'),
      );
      expect(
        recipientAddressProblemFor(testnetStandard, walletOnTestnet: false),
        contains('testnet address'),
      );
    });
  });

  group('backendSubaddresses', () {
    test('keeps each entry scheme and defaults unversioned ones to Sublime', () {
      final listed = backendSubaddresses([
        {'index': 1, 'address': 'funsaA', 'version': 2},
        {'index': 1, 'address': 'fireB'},
        {'index': 'x', 'address': 'bad'},
        'junk',
      ]);
      expect(listed, [
        (scheme: Subaddress.funsaScheme, index: 1, address: 'funsaA'),
        (scheme: Subaddress.sublimeScheme, index: 1, address: 'fireB'),
      ]);
      expect(backendSubaddresses(null), isEmpty);
    });

    test('same index under two schemes is two slots', () {
      final v1 = Subaddress(
        address: 'fireB',
        label: '',
        index: 1,
        createdAt: DateTime(2026),
      );
      final v2 = Subaddress(
        address: 'funsaA',
        label: '',
        index: 1,
        createdAt: DateTime(2026),
        scheme: Subaddress.funsaScheme,
      );
      expect(v1.sameSlot(v2), isFalse);
      expect(v1.linkable, isTrue);
      expect(v2.linkable, isFalse);
      expect(Subaddress.fromJson(v2.toJson()).scheme, Subaddress.funsaScheme);
      expect(Subaddress.fromJson({'address': 'fireB'}).scheme,
          Subaddress.sublimeScheme);
    });
  });
}
