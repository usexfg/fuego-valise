import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/models/swap_models.dart';
import 'package:fuego/models/swap_pair_catalog.g.dart';

void main() {
  group('SwapPairSdk is bound to the generated daemon catalog', () {
    test('every wallet pair is a protocol id of the catalog', () {
      for (final pair in SwapPairSdk.values) {
        expect(pair.catalog.id, pair.id, reason: pair.name);
        expect(
          pair.catalog.protocol,
          isTrue,
          reason: '${pair.name} is staged in the catalog',
        );
      }
    });

    // DOGE, DASH and ZEC are catalog ids the wallet has no chain support for.
    // A swap record naming one is dropped by the DEX parsers, never shown as ETH.
    const walletOmits = {20, 21, 22};

    test('every protocol id of the catalog has a wallet pair', () {
      final walletIds = {for (final pair in SwapPairSdk.values) pair.id};
      for (final entry in kSwapPairCatalog.where(
        (e) => e.protocol && !walletOmits.contains(e.id),
      )) {
        expect(walletIds, contains(entry.id), reason: entry.name);
      }
    });

    test('staged ids have no wallet pair', () {
      for (final entry in kSwapPairCatalog.where((e) => !e.protocol)) {
        expect(SwapPairSdk.tryFromId(entry.id), isNull, reason: entry.name);
      }
    });

    test('fromId fails closed instead of defaulting to ETH', () {
      expect(SwapPairSdk.fromId(9), SwapPairSdk.btc);
      expect(() => SwapPairSdk.fromId(17), throwsFormatException);
      expect(() => SwapPairSdk.fromId(999), throwsFormatException);
    });

    test('EVM chain ids agree with the catalog', () {
      for (final pair in SwapPairSdk.values.where((p) => p.chain.isEvm)) {
        expect(pair.catalog.family, 'evm', reason: pair.name);
      }
    });
  });
}
