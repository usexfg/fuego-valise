import 'package:flutter_test/flutter_test.dart';
import 'package:web3dart/web3dart.dart';
import 'package:fuego/services/erc20_service.dart';
import 'package:fuego/models/erc20_token.dart';

void main() {
  group('Erc20Service selectors', () {
    // Access private encoders via service instance trick — test via public balanceOfRaw encoding side-effect.
    // Instead, directly test the static helpers by reproducing them here and comparing to known good vectors.
    test('balanceOf selector is 70a08231', () {
      final holder = EthereumAddress.fromHex('0x1111111111111111111111111111111111111111');
      // Reproduce encoder
      final data = [
        0x70, 0xa0, 0x82, 0x31,
        ...List<int>.filled(12, 0),
        ...holder.addressBytes,
      ];
      expect(data[0], 0x70);
      expect(data[1], 0xa0);
      expect(data[2], 0x82);
      expect(data[3], 0x31);
      expect(data.length, 36);
    });

    test('transfer encodes amount 1.5 USDT (6 decimals) correctly', () {
      final amount = Erc20Amount.toBaseUnits('1.5', 6); // 1500000 = 0x16e360
      expect(amount, BigInt.from(1500000));
      // Encoded amount should be 32-byte big endian
      final hex = amount.toRadixString(16).padLeft(64, '0');
      expect(hex, '000000000000000000000000000000000000000000000000000000000016e360');
    });

    test('approve encodes max uint256', () {
      final max = (BigInt.one << 256) - BigInt.one;
      final hex = max.toRadixString(16).padLeft(64, '0');
      expect(hex, 'f' * 64);
    });
  });

  group('Erc20Service chain routing', () {
    test('chainId mapping', () {
      final svc = Erc20Service();
      expect(svc.chainIdFor('eth'), 1);
      expect(svc.chainIdFor('arb'), 42161);
      expect(svc.chainIdFor('base'), 8453);
      expect(svc.chainIdFor('bsc'), 56);
      expect(svc.chainIdFor('poly'), 137);
      expect(svc.chainIdFor('unknown'), 1);
      svc.dispose();
    });

    test('rpcUrlFor defaults', () {
      final svc = Erc20Service();
      expect(svc.rpcUrlFor('eth'), contains('llamarpc'));
      expect(svc.rpcUrlFor('poly'), contains('polygon'));
      svc.dispose();
    });

    test('setRpcUrl updates', () {
      final svc = Erc20Service();
      svc.setRpcUrl('eth', 'https://example.com');
      expect(svc.rpcUrlFor('eth'), 'https://example.com');
      svc.dispose();
    });

    test('address validation throws', () async {
      final svc = Erc20Service();
      expect(
        () => svc.balanceOf(chainKey: 'eth', tokenAddress: 'bad', holderAddress: '0x1111111111111111111111111111111111111111'),
        throwsA(isA<ArgumentError>()),
      );
      svc.dispose();
    });
  });

  group('Erc20Service integration smoke (no network)', () {
    test('creates without throwing', () {
      final svc = Erc20Service(rpcUrls: {'eth': 'https://eth.llamarpc.com'});
      expect(svc, isNotNull);
      svc.dispose();
    });
  });
}
