import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/models/swap_models.dart';
import 'package:fuego/services/swap_daemon_client.dart';

void main() {
  group('SwapLockTypeSdk', () {
    test('tryFromId roundtrip', () {
      expect(SwapLockTypeSdk.tryFromId(0), SwapLockTypeSdk.htlc);
      expect(SwapLockTypeSdk.tryFromId(1), SwapLockTypeSdk.ptlc);
      expect(SwapLockTypeSdk.tryFromId(2), SwapLockTypeSdk.bridge);
      // Was `fromId(99) == htlc`. An unknown lock type is a claim about how
      // the swap is secured, so it must not resolve to HTLC.
      expect(SwapLockTypeSdk.tryFromId(99), isNull);
    });
    test('fromString case insensitive', () {
      expect(SwapLockTypeSdk.fromString('ptlc'), SwapLockTypeSdk.ptlc);
      expect(SwapLockTypeSdk.fromString('BRIDGE'), SwapLockTypeSdk.bridge);
      expect(SwapLockTypeSdk.fromString('PTLC_HTLC_BRIDGE'), SwapLockTypeSdk.bridge);
      expect(SwapLockTypeSdk.fromString('htlc'), SwapLockTypeSdk.htlc);
      expect(SwapLockTypeSdk.fromString('unknown'), SwapLockTypeSdk.htlc);
    });
    test('helpers', () {
      expect(SwapLockTypeSdk.ptlc.isPtlcPure, true);
      expect(SwapLockTypeSdk.bridge.isBridge, true);
      expect(SwapLockTypeSdk.htlc.isHtlc, true);
    });
  });

  group('SwapInfo lockType parsing', () {
    test('parses int lockType 1 -> PTLC', () {
      final j = {
        'swapId': 'abc',
        'state': 11,
        'params': {
          'swapId': 'abc',
          'pair': 9,
          'xfgAmount': 10000000,
          'ctrAmount': 50000,
          'lockType': 1,
          'ptlcPoint': 'ab' * 32,
          'requirePtlc': true,
        },
        'createdAt': 0,
        'updatedAt': 0,
      };
      final info = SwapInfo.fromJson(j);
      expect(info.lockType, 1);
      expect(info.lockTypeName, 'PTLC');
      expect(info.isPtlc, true);
      expect(info.ptlcPoint.length, 64);
      expect(info.requirePtlc, true);
    });
    test('defaults to HTLC when missing', () {
      final j = {
        'swapId': 'def',
        'state': 'ADAPTOR_KEYS_EXCHANGED',
        'params': {'pair': 1, 'xfgAmount': 0, 'ctrAmount': 0},
        'createdAt': 0,
        'updatedAt': 0,
      };
      final info = SwapInfo.fromJson(j);
      expect(info.lockType, 0);
      expect(info.isHtlc, true);
      expect(info.lockTypeLabel, 'HTLC');
    });
    test('bridge from lock_type snake', () {
      final j = {
        'swapId': 'ghi',
        'state': 13,
        'params': {'pair': 1, 'xfgAmount': 0, 'ctrAmount': 0, 'lock_type': 2, 'ptlc_point': 'cd' * 32},
        'createdAt': 0,
        'updatedAt': 0,
      };
      final info = SwapInfo.fromJson(j);
      expect(info.lockType, 2);
      expect(info.isBridge, true);
      expect(info.lockTypeName, 'BRIDGE');
    });
  });
}
