import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/models/erc20_token.dart';

void main() {
  group('Erc20Registry', () {
    test('contains 41 tokens across 33 chains', () {
      expect(Erc20Registry.all.length, 41);
      expect(EvmChainKey.values.length, 33);
    });

    test('every registry entry is reachable by address and by symbol', () {
      for (final t in Erc20Registry.all) {
        expect(Erc20Registry.findByAddress(t.chainKey, t.address), isNotNull,
            reason: '${t.symbol} on ${t.chainKey} not addressable');
        expect(Erc20Registry.find(t.chainKey, t.symbol), isNotNull,
            reason: '${t.symbol} on ${t.chainKey} not findable');
      }
    });

    test('Venice Token (VVV) on Base — 18 decimals, not a stable', () {
      final t = Erc20Registry.find('base', 'VVV')!;
      expect(t.lcAddress, '0xacfe6019ed1a7dc6f7b508c02d1b04ec88cc21bf');
      expect(t.name, 'Venice Token');
      expect(t.decimals, 18);
      expect(t.chainId, 8453);
      expect(t.isNativeStable, isFalse);
      // 1 VVV must scale by 1e18, not the 6 the Base stables use.
      expect(Erc20Amount.toBaseUnits('1', t.decimals),
          BigInt.parse('1000000000000000000'));
    });

    test('oUSDT same Superchain address on all six chains', () {
      const addr = '0x1217bfe6c773eec6cc4a38b5dc45b92292b6e189';
      for (final k in ['op', 'base', 'bob', 'uni', 'ink', 'soneium']) {
        final t = Erc20Registry.forChain(k).where((t) => t.symbol == 'oUSDT').toList();
        expect(t.length, 1, reason: 'oUSDT missing on $k');
        expect(t.first.lcAddress, addr);
        expect(t.first.isNativeStable, false);
      }
    });

    test('find USDT on ETH returns 6 decimals', () {
      final t = Erc20Registry.find('eth', 'USDT')!;
      expect(t.address.toLowerCase(), '0xdac17f958d2ee523a2206206994597c13d831ec7');
      expect(t.decimals, 6);
      expect(t.chainKey, 'eth');
    });

    test('BSC USDT uses 18 decimals', () {
      final t = Erc20Registry.find('bsc', 'USDT')!;
      expect(t.decimals, 18);
    });

    test('forChain filters', () {
      expect(Erc20Registry.forChain('poly').length, 2);
      expect(Erc20Registry.forChain('base').length, 4); // USDC + USDT + oUSDT + VVV
      expect(Erc20Registry.forChain('eth').length, 2);
      expect(Erc20Registry.forChain('rsk'), isEmpty); // chain-only until verified
    });

    test('findByAddress case insensitive', () {
      final t = Erc20Registry.findByAddress('ETH', '0xDAC17F958D2EE523A2206206994597C13D831EC7');
      expect(t, isNotNull);
      expect(t!.symbol, 'USDT');
    });

    test('supportedChainKeys', () {
      expect(Erc20Registry.supportedChainKeys, containsAll(['eth','arb','base','bsc','poly']));
    });
  });

  group('Erc20Amount', () {
    test('toBaseUnits 6 decimals', () {
      expect(Erc20Amount.toBaseUnits('1.5', 6), BigInt.from(1500000));
      expect(Erc20Amount.toBaseUnits('1', 6), BigInt.from(1000000));
      expect(Erc20Amount.toBaseUnits('0.000001', 6), BigInt.one);
    });

    test('toBaseUnits 18 decimals', () {
      expect(Erc20Amount.toBaseUnits('1', 18), BigInt.parse('1000000000000000000'));
    });

    test('fromBaseUnits', () {
      expect(Erc20Amount.fromBaseUnits(BigInt.from(1500000), 6), '1.5');
      expect(Erc20Amount.fromBaseUnits(BigInt.from(1000000), 6), '1');
      expect(Erc20Amount.fromBaseUnits(BigInt.zero, 6), '0');
      expect(Erc20Amount.fromBaseUnits(BigInt.parse('1000000000000000000'), 18), '1');
    });

    test('round-trip', () {
      for (final s in ['0.1','1.234567','100','0.000001']) {
        final bi = Erc20Amount.toBaseUnits(s, 6);
        final back = Erc20Amount.fromBaseUnits(bi, 6);
        expect(back, s);
      }
    });

    test('toBaseUnits trims extra decimals', () {
      // 7 decimals input with 6 decimals token — should truncate/pad correctly
      expect(Erc20Amount.toBaseUnits('1.1234567', 6), BigInt.from(1123456));
    });
  });

  group('Erc20Token equality', () {
    test('same address different case equal', () {
      const a = Erc20Token(address: '0xABCDEF1234567890123456789012345678901234', symbol: 'T', name: 'T', decimals: 6, chain: EvmChainKey.eth);
      const b = Erc20Token(address: '0xabcdef1234567890123456789012345678901234', symbol: 'T', name: 'T', decimals: 6, chain: EvmChainKey.eth);
      expect(a, equals(b));
    });
  });
}
