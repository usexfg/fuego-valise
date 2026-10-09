import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fuego/services/swap_daemon_client.dart';

Map<String, dynamic> _readyChain({bool ready = true}) => {
  'id': 1,
  'key': 'ethereum',
  'symbol': 'ETH',
  'assetTicker': 'ETH',
  'name': 'Ethereum',
  'family': 'EVM',
  'decimals': 18,
  'implementation': 'PROTOCOL',
  'protocol': true,
  'configured': true,
  'ready': ready,
  'readinessError': ready ? '' : 'RPC unavailable',
};

http.Response _result(Object result) => http.Response(
  jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': result}),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('SwapDaemonClient', () {
    test(
      'sends authenticated no-redirect requests and string amounts',
      () async {
        final methods = <String>[];
        Map<String, dynamic>? initiateParams;
        final mock = MockClient((request) async {
          expect(request.followRedirects, isFalse);
          expect(request.headers['x-swap-token'], 'secret-token');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final method = body['method'] as String;
          methods.add(method);
          switch (method) {
            case 'status':
              return _result({'network': 'testnet', 'profile': 'testnet'});
            case 'list_chains':
              return _result({
                'chains': [_readyChain()],
              });
            case 'initiate_swap':
              initiateParams = body['params'] as Map<String, dynamic>;
              return _result({'swap_id': 'swap-1'});
            default:
              fail('Unexpected RPC method $method');
          }
        });
        final client = SwapDaemonClient(
          expectedNetwork: 'testnet',
          token: 'secret-token',
          httpClient: mock,
        );

        final swapId = await client.initiateSwap(
          pair: 'ethereum',
          xfgAmount: '12500000',
          ctrAmount: '900000000000000000',
          peer: 'swap.example:18901',
          expectedPeerPubkey: List.filled(64, '1').join(),
        );

        expect(swapId, 'swap-1');
        expect(methods, ['status', 'list_chains', 'initiate_swap']);
        expect(initiateParams!['xfg_amount'], '12500000');
        expect(initiateParams!['ctr_amount'], '900000000000000000');
        expect(initiateParams!['xfg_amount'], isA<String>());
        expect(initiateParams!['ctr_amount'], isA<String>());
      },
    );

    test('rejects daemon network mismatch before listing chains', () async {
      final mock = MockClient(
        (_) async => _result({'network': 'mainnet', 'profile': 'mainnet'}),
      );
      final client = SwapDaemonClient(
        expectedNetwork: 'testnet',
        httpClient: mock,
      );

      await expectLater(client.listChains(), throwsA(isA<SwapRpcException>()));
    });

    test('reads the fail-closed AFK capability from status', () async {
      final client = SwapDaemonClient(
        expectedNetwork: 'mainnet',
        httpClient: MockClient(
          (_) async => _result({
            'network': 'mainnet',
            'profile': 'mainnet',
            'afk_soft_orders_enabled': false,
          }),
        ),
      );

      final status = await client.verifyContext();
      expect(status.afkSoftOrdersEnabled, isFalse);
    });

    test('rejects unready chain before mutation', () async {
      var initiated = false;
      final mock = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        switch (body['method']) {
          case 'status':
            return _result({'network': 'mainnet', 'profile': 'mainnet'});
          case 'list_chains':
            return _result({
              'chains': [_readyChain(ready: false)],
            });
          case 'initiate_swap':
            initiated = true;
            return _result({'swap_id': 'must-not-run'});
          default:
            fail('Unexpected method ${body['method']}');
        }
      });
      final client = SwapDaemonClient(
        expectedNetwork: 'mainnet',
        httpClient: mock,
      );

      await expectLater(
        client.initiateSwap(
          pair: 'ethereum',
          xfgAmount: '1',
          ctrAmount: '1',
          peer: '127.0.0.1:18901',
          expectedPeerPubkey: List.filled(64, '2').join(),
        ),
        throwsA(isA<SwapRpcException>()),
      );
      expect(initiated, isFalse);
    });

    test('reports mutation redirect as unknown outcome', () async {
      final mock = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        switch (body['method']) {
          case 'status':
            return _result({'network': 'mainnet', 'profile': 'mainnet'});
          case 'list_chains':
            return _result({
              'chains': [_readyChain()],
            });
          case 'initiate_swap':
            return http.Response('', 307, headers: {'location': 'http://bad/'});
          default:
            fail('Unexpected method ${body['method']}');
        }
      });
      final client = SwapDaemonClient(
        expectedNetwork: 'mainnet',
        httpClient: mock,
      );

      await expectLater(
        client.initiateSwap(
          pair: 'ethereum',
          xfgAmount: '1',
          ctrAmount: '1',
          peer: '127.0.0.1:18901',
          expectedPeerPubkey: List.filled(64, '3').join(),
        ),
        throwsA(isA<SwapOutcomeUnknownException>()),
      );
    });

    test('treats timeout checks as mutations', () async {
      final mock = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['method'] == 'status') {
          return _result({'network': 'mainnet', 'profile': 'mainnet'});
        }
        expect(body['method'], 'check_timeouts');
        return http.Response('', 503);
      });
      final client = SwapDaemonClient(
        expectedNetwork: 'mainnet',
        httpClient: mock,
      );

      await expectLater(
        client.checkTimeouts(),
        throwsA(isA<SwapOutcomeUnknownException>()),
      );
    });

    test('converts display amounts without floating point', () {
      expect(SwapDaemonClient.xfgToAtomic('1.2345678'), '12345678');
      expect(
        SwapDaemonClient.counterpartyToAtomic('0.000000000000000001', 18),
        '1',
      );
      expect(
        () => SwapDaemonClient.xfgToAtomic('0.00000001'),
        throwsFormatException,
      );
      expect(
        () => SwapDaemonClient.xfgToAtomic('1844674407370.9551616'),
        throwsFormatException,
      );
    });

    test('decodes exact root amount and numeric SPV flags', () {
      final swap = SwapInfo.fromJson({
        'swapId': 'swap-2',
        'state': 17,
        'pair': 45,
        'pairName': 'TON',
        'xfgAmount': 7,
        'xfgAmountAtomic': '18446744073709551615',
        'ctrAmount': '1000000000',
        'spvVerified': 1,
        'confirmed': 0,
      });

      expect(swap.xfgAmount, BigInt.parse('18446744073709551615'));
      expect(swap.spvVerified, isTrue);
      expect(swap.confirmed, isFalse);
      expect(swap.pairName, 'TON');
    });
  });
}
