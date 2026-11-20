import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/models/network_catalog.g.dart';
import 'package:fuego/models/swap_models.dart';

void main() {
  test('ready set is the generated picker, not a second list', () {
    expect(SwapPairSdk.values.map((p) => p.id), [
      for (final row in kReadyNetworks) row.swapPairId,
    ]);
    expect(SwapPairSdk.values, hasLength(22));
    expect(SwapPairSdk.values.map((p) => p.ticker).toSet(), {
      'SOL',
      'ETH',
      'XMR',
      'BCH',
      'ARB',
      'BASE',
      'KMD',
      'BNB',
      'DCR',
      'BTC',
      'LTC',
      'POLY',
      'GLEEC',
      'RHC',
      'AVAX',
      'CRO',
      'BOB',
      'UNI',
      'XPL',
      'PLS',
      'MON',
      'OP',
    });
  });

  test('every pin id is in the catalog once, and unknown is not ETH', () {
    final ids = kNetworkCatalog
        .map((row) => row.swapPairId)
        .whereType<int>()
        .toList();
    expect(ids.toSet(), hasLength(ids.length));
    expect(ids, containsAll(List<int>.generate(29, (i) => i)));
    expect(SwapPairSdk.tryFromId(22), isNull);
    expect(SwapPairSdk.tryFromId(17), isNull);
    expect(() => SwapPairSdk.fromId(22), throwsArgumentError);
    expect(SwapPairSdk.fromId(1), SwapPairSdk.eth);
  });

  test('staged rows cannot be ready, and SIA divisor is recorded', () {
    final sia = networkBySwapPairId(17);
    expect(sia, isNotNull);
    expect(sia!.activation, 'staged_in_suite');
    expect(sia.suiteStatus, 'staged');
    expect(sia.ctrDivisor, '1e24');
    expect(sia.cppAcceptsTicker, isTrue);

    for (final row in kNetworkCatalog) {
      if (row.suiteStatus == 'staged') {
        expect(row.activation, isNot('ready'));
      }
      if (row.activation == 'ready') {
        expect(row.suiteStatus, 'registers');
        expect(row.enumName, isNotNull);
      }
    }
  });

  test('display tickers the C++ parser rejects stay off the wire', () {
    final rejected = kNetworkCatalog
        .where((row) => row.swapPairId != null && !row.cppAcceptsTicker)
        .map((row) => row.ticker)
        .toSet();
    expect(rejected, containsAll({'RHC', 'UNI', 'XPL', 'MON'}));
    expect(networkBySwapPairId(11)!.wireName, 'POLYGON');
    expect(networkBySwapPairId(11)!.ticker, 'POLY');
    expect(networkBySwapPairId(11)!.cppAcceptsTicker, isTrue);
  });

  test('wallet-only rows have no swap pair id', () {
    final wallet = kNetworkCatalog.where(
      (row) => row.activation == 'wallet_only',
    );
    expect(wallet, isNotEmpty);
    for (final row in wallet) {
      expect(row.swapPairId, isNull);
    }
    expect(
      kNetworkCatalog.map((row) => row.key),
      containsAll(['tempo', 'zksync', 'abstract', 'rsk', 'zec']),
    );
    expect(networkBySwapPairId(22)!.activation, 'needs_wallet_wiring');
  });
}
