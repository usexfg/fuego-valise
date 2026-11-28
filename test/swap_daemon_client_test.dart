import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:fuego/services/swap_daemon_client.dart';

class ScriptedClient extends http.BaseClient {
  ScriptedClient(this.handler);

  final Future<http.Response> Function(http.Request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await handler(request as http.Request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
      request: request,
    );
  }
}

Map<String, dynamic> _readyChain({bool ready = true}) => {
  'id': 1,
  'key': 'eth',
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
        final transport = ScriptedClient((request) async {
          expect(request.followRedirects, isFalse);
          expect(request.headers['x-swap-token'], List.filled(64, 'a').join());
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
          token: List.filled(64, 'a').join(),
          httpClient: transport,
        );

        final swapId = await client.initiatePeerSwap(
          pair: 'eth',
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
      final transport = ScriptedClient(
        (_) async => _result({'network': 'mainnet', 'profile': 'mainnet'}),
      );
      final client = SwapDaemonClient(
        expectedNetwork: 'testnet',
        httpClient: transport,
      );

      await expectLater(client.listChains(), throwsA(isA<SwapRpcException>()));
    });

    test('reads the fail-closed AFK capability from status', () async {
      final client = SwapDaemonClient(
        expectedNetwork: 'mainnet',
        httpClient: ScriptedClient(
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
      final transport = ScriptedClient((request) async {
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
        token: List.filled(64, 'a').join(),
        httpClient: transport,
      );

      await expectLater(
        client.initiatePeerSwap(
          pair: 'eth',
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
      final transport = ScriptedClient((request) async {
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
        token: List.filled(64, 'a').join(),
        httpClient: transport,
      );

      await expectLater(
        client.initiatePeerSwap(
          pair: 'eth',
          xfgAmount: '1',
          ctrAmount: '1',
          peer: '127.0.0.1:18901',
          expectedPeerPubkey: List.filled(64, '3').join(),
        ),
        throwsA(isA<SwapOutcomeUnknownException>()),
      );
    });

    test('treats timeout checks as mutations', () async {
      final transport = ScriptedClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['method'] == 'status') {
          return _result({'network': 'mainnet', 'profile': 'mainnet'});
        }
        expect(body['method'], 'check_timeouts');
        return http.Response('', 503);
      });
      final client = SwapDaemonClient(
        expectedNetwork: 'mainnet',
        token: List.filled(64, 'a').join(),
        httpClient: transport,
      );

      await expectLater(
        client.checkTimeouts(),
        throwsA(isA<SwapOutcomeUnknownException>()),
      );
    });

    test('refuses tokenless high-level mutations before dispatch', () async {
      final methods = <String>[];
      final client = SwapDaemonClient(
        expectedNetwork: 'mainnet',
        httpClient: ScriptedClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          methods.add(body['method'] as String);
          if (body['method'] == 'status') {
            return _result({'network': 'mainnet', 'profile': 'mainnet'});
          }
          return _result({'processed': 0, 'refunded': const <String>[]});
        }),
      );

      final tokenFailure = isA<SwapRpcException>().having(
        (error) => error.message,
        'message',
        contains('control token is required'),
      );
      const peer = '127.0.0.1:18901';
      final peerKey = List.filled(64, '1').join();

      await expectLater(
        client.initiatePeerSwap(
          pair: 'eth',
          xfgAmount: '1',
          ctrAmount: '1',
          peer: peer,
          expectedPeerPubkey: peerKey,
        ),
        throwsA(tokenFailure),
      );
      await expectLater(
        client.initiateAfkSwap(
          pair: 'eth',
          xfgAmount: '1',
          ctrAmount: '1',
          peer: peer,
          expectedPeerPubkey: peerKey,
          swapId: 'swap-1',
          ourSwapSecretKey: 'secret',
          adaptorPoint: 'point',
          hashLock: 'lock',
          preSig: 'pre-signature',
          ctrAddress: 'counterparty-address',
        ),
        throwsA(tokenFailure),
      );
      await expectLater(client.acceptSwap('swap-1'), throwsA(tokenFailure));
      await expectLater(client.refund('swap-1'), throwsA(tokenFailure));
      await expectLater(client.checkTimeouts(), throwsA(tokenFailure));
      expect(methods, isEmpty);
    });

    test('formats a bare IPv6 loopback control endpoint', () async {
      Uri? requestUri;
      final client = SwapDaemonClient(
        host: '::1',
        expectedNetwork: 'mainnet',
        token: List.filled(64, 'a').join(),
        httpClient: ScriptedClient((request) async {
          requestUri = request.url;
          return _result({'network': 'mainnet', 'profile': 'mainnet'});
        }),
      );

      await client.verifyContext();

      expect(requestUri!.scheme, 'http');
      expect(requestUri!.host, '::1');
      expect(requestUri!.port, 18902);
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

    test('converts counterparty rates with exact decimal arithmetic', () {
      expect(SwapDaemonClient.counterpartyPerXfgToRateNum('2'), 5000000);
      expect(SwapDaemonClient.counterpartyPerXfgToRateNum('0.5'), 20000000);
      expect(
        () => SwapDaemonClient.counterpartyPerXfgToRateNum('0'),
        throwsFormatException,
      );
    });

    test('uses daemon-compatible floor division for offer amounts', () {
      expect(
        SwapDaemonClient.counterpartyAmountForOffer(
          xfgAmount: 10000000,
          rateNum: 3000000,
          counterpartyDecimals: 6,
        ),
        '3333333',
      );
      expect(
        SwapDaemonClient.counterpartyAmountForOffer(
          xfgAmount: 10000000,
          rateNum: 2000000,
          counterpartyDecimals: 6,
        ),
        '5000000',
      );
    });

    test('rejects non-loopback control endpoints', () {
      expect(
        () =>
            SwapDaemonClient(host: 'swap.example', expectedNetwork: 'mainnet'),
        throwsArgumentError,
      );
    });

    test('reads the current control token for each request', () async {
      var tokenReads = 0;
      final seenTokens = <String?>[];
      final client = SwapDaemonClient(
        expectedNetwork: 'mainnet',
        tokenProvider: () async {
          tokenReads += 1;
          return List.filled(64, tokenReads == 1 ? 'a' : 'b').join();
        },
        httpClient: ScriptedClient((request) async {
          seenTokens.add(request.headers['x-swap-token']);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body['method'] == 'status') {
            return _result({'network': 'mainnet', 'profile': 'mainnet'});
          }
          return _result({
            'chains': [_readyChain()],
          });
        }),
      );

      await client.listChains();

      expect(seenTokens, [
        List.filled(64, 'a').join(),
        List.filled(64, 'b').join(),
      ]);
    });

    test('rejects alias pair names before mutation', () async {
      var initiated = false;
      final client = SwapDaemonClient(
        expectedNetwork: 'mainnet',
        token: List.filled(64, 'a').join(),
        httpClient: ScriptedClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          switch (body['method']) {
            case 'status':
              return _result({'network': 'mainnet', 'profile': 'mainnet'});
            case 'list_chains':
              return _result({
                'chains': [_readyChain()],
              });
            case 'initiate_swap':
              initiated = true;
              return _result({'swap_id': 'unexpected'});
            default:
              fail('Unexpected RPC method ${body['method']}');
          }
        }),
      );

      await expectLater(
        client.initiatePeerSwap(
          pair: 'ethereum',
          xfgAmount: '1',
          ctrAmount: '1',
          peer: '127.0.0.1:18901',
          expectedPeerPubkey: List.filled(64, '4').join(),
        ),
        throwsA(isA<SwapRpcException>()),
      );
      expect(initiated, isFalse);
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

    test('rejects fractional atomic amounts from RPC responses', () {
      expect(
        () => SwapInfo.fromJson({
          'swapId': 'swap-3',
          'state': 'INITIATED',
          'pair': 1,
          'xfgAmountAtomic': 1.5,
          'ctrAmount': '1',
        }),
        throwsFormatException,
      );
    });
  });
}
