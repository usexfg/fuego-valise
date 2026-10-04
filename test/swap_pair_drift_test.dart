import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/models/chain_info.dart';
import 'package:fuego/models/swap_models.dart';
import 'package:fuego/services/swap_daemon_client.dart';

/// Regression guards for pair-id -> ticker drift between the daemon's wire
/// `SwapPair` ids and the ticker-keyed [ChainInfo] maps.
///
/// The bug these lock down: `SwapInfo.pairName` and
/// `DaemonEventBus._extractPairName` each carried a private 0-11 id table.
/// Pairs with ids >= 12 (GLEEC, RHC, AVAX, CRO, BOB, UNI, XPL, PLS, MON, OP)
/// resolved to `PAIR_12`..`PAIR_26`, and id 11 resolved to `POLYGON` while
/// every ChainInfo map is keyed `POLY`. Both getters now derive from
/// [SwapPairSdk]; these tests fail if that derivation ever regresses.
void main() {
  final pairs = SwapPairSdk.values;

  SwapInfo infoFor(int pair) => SwapInfo(
    swapId: 's',
    state: 'INITIATED',
    pair: pair,
    xfgAmount: 0,
    ctrAmount: 0,
    peerEndpoint: '',
    createdAt: 0,
    updatedAt: 0,
  );

  group('SwapPairSdk wire ids', () {
    test('ids are unique', () {
      final ids = pairs.map((p) => p.id).toList();
      expect(
        ids.toSet().length,
        ids.length,
        reason: 'duplicate SwapPairSdk id',
      );
    });

    test('ids are non-negative and match the C++ SwapPair values', () {
      // Must track fuego-suite src/SwapDaemon/SwapTypes.h. Append-only:
      // inserting mid-enum renumbers the wire format.
      const expected = <int, String>{
        0: 'SOL',
        1: 'ETH',
        2: 'XMR',
        3: 'BCH',
        4: 'ARB',
        5: 'BASE',
        6: 'KMD',
        7: 'BNB',
        8: 'DCR',
        9: 'BTC',
        10: 'LTC',
        11: 'POLY',
        12: 'GLEEC',
        13: 'RHC',
        14: 'AVAX',
        15: 'CRO',
        16: 'BOB',
        18: 'UNI',
        19: 'XPL',
        23: 'PLS',
        25: 'MON',
        26: 'OP',
      };
      final actual = <int, String>{for (final p in pairs) p.id: p.ticker};
      expect(
        actual,
        expected,
        reason: 'SwapPairSdk ids/tickers drifted from SwapTypes.h',
      );
    });

    test('every id round-trips through tryFromId', () {
      for (final p in pairs) {
        expect(SwapPairSdk.tryFromId(p.id), p);
      }
      expect(SwapPairSdk.tryFromId(999), isNull);
    });
  });

  group('SwapInfo.pairName resolves for every wired pair', () {
    test('never falls back to PAIR_<n>', () {
      for (final p in pairs) {
        expect(
          infoFor(p.id).pairName,
          p.ticker,
          reason:
              'pair ${p.id} (${p.ticker}) fell through to '
              '${infoFor(p.id).pairName}',
        );
      }
    });

    test('the ten previously-broken ids now resolve', () {
      const broken = {
        12: 'GLEEC',
        13: 'RHC',
        14: 'AVAX',
        15: 'CRO',
        16: 'BOB',
        18: 'UNI',
        19: 'XPL',
        23: 'PLS',
        25: 'MON',
        26: 'OP',
      };
      for (final e in broken.entries) {
        expect(infoFor(e.key).pairName, e.value);
      }
    });

    test('id 11 is POLY, not POLYGON (ChainInfo is keyed POLY)', () {
      expect(infoFor(11).pairName, 'POLY');
      expect(ChainInfo.colors['POLY'], isNotNull);
      expect(
        ChainInfo.colors.containsKey('POLYGON'),
        isFalse,
        reason: 'nothing is keyed POLYGON; emitting it broke every lookup',
      );
    });

    test('unknown id still yields the PAIR_<n> fallback', () {
      expect(infoFor(999).pairName, 'PAIR_999');
    });
  });

  group('every swapable chain has ChainInfo metadata', () {
    test('colour, icon and decimals resolve for all 22 pairs', () {
      for (final p in pairs) {
        final t = p.ticker;
        expect(ChainInfo.colors[t], isNotNull, reason: 'no colour for $t');
        expect(ChainInfo.icons[t], isNotNull, reason: 'no icon for $t');
        expect(ChainInfo.decimals[t], isNotNull, reason: 'no decimals for $t');
        expect(
          ChainInfo.ptlc[t],
          isNotNull,
          reason: 'no PTLC descriptor for $t',
        );
      }
    });

    test('referenced icon assets exist on disk', () {
      for (final p in pairs) {
        final path = ChainInfo.icons[p.ticker]!;
        expect(
          File(path).existsSync(),
          isTrue,
          reason: '${p.ticker} icon missing at $path',
        );
      }
    });

    test('explorerTx resolves for all but the three known gaps', () {
      // Deliberately explicit: adding a pair without an explorer fails here,
      // and closing one of these requires deleting it from the set.
      const knownMissing = {'GLEEC', 'RHC', 'XPL'};
      for (final p in pairs) {
        final t = p.ticker;
        if (knownMissing.contains(t)) {
          expect(
            ChainInfo.explorerTx.containsKey(t),
            isFalse,
            reason: '$t now has an explorer — drop it from knownMissing',
          );
          continue;
        }
        expect(
          ChainInfo.explorerTx[t],
          isNotNull,
          reason: 'no explorer for $t',
        );
        expect(ChainInfo.explorerTxUrl(t, 'deadbeef'), contains('deadbeef'));
      }
      expect(knownMissing, {'GLEEC', 'RHC', 'XPL'});
    });

    test('SwapInfo.explorerUrl is empty for a pair with no explorer', () {
      expect(infoFor(12).ctrLockTxId, isNull);
      final withTx = SwapInfo(
        swapId: 's',
        state: 'INITIATED',
        pair: 12, // GLEEC — no explorer template
        xfgAmount: 0,
        ctrAmount: 0,
        peerEndpoint: '',
        createdAt: 0,
        updatedAt: 0,
        ctrLockTxId: 'abc',
      );
      expect(withTx.explorerUrl, '');
    });
  });

  group('duplicated chain lists agree', () {
    test('ChainInfo.swapableChains == SwapPairSdk tickers', () {
      expect(
        ChainInfo.swapableChains.toSet(),
        pairs.map((p) => p.ticker).toSet(),
        reason: 'swapableChains and SwapPairSdk have diverged',
      );
      expect(ChainInfo.swapableChains.length, pairs.length);
    });

    test(
      'every swapable chain has an info entry and is not marked unwired',
      () {
        // Convention in ChainInfo.info: `wired` is only present when a chain is
        // NOT wired (the 4 staged chains carry 'wired': 'false'). So absence of
        // the key means wired.
        for (final t in ChainInfo.swapableChains) {
          final info = ChainInfo.info[t];
          expect(info, isNotNull, reason: 'ChainInfo.info missing $t');
          expect(
            info!['wired'],
            isNot('false'),
            reason: '$t is marked unwired but listed as swapable',
          );
          expect(info['htlc'], isNotNull, reason: '$t has no htlc descriptor');
        }
        // The only entries carrying an explicit flag are the unwired ones.
        final flagged = ChainInfo.info.entries
            .where((e) => e.value.containsKey('wired'))
            .map((e) => e.key)
            .toSet();
        expect(flagged, {'DASH', 'DOGE', 'ZANO', 'ZEC'});
        expect(flagged.any(ChainInfo.swapableChains.contains), isFalse);
      },
    );
  });
}
