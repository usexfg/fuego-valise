import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/models/network_config.dart';
import 'package:fuego/services/daemon_manager.dart';
import 'package:fuego/services/fuego_rpc_service.dart';
import 'package:fuego/services/node_connection.dart';

/// Live stack validation against real binaries on this machine.
///
/// Requires:
/// - `rust-fuego-wallet/target/release/fuego_walletd`
/// - `rust-fuego-wallet/target/release/fuegod` (via --local or separate)
/// - `xfgo/swapxfg/xfg-swapd` (Go headless)
///
/// Skips automatically when binaries are missing so CI without binaries stays green.
void main() {
  final root = Directory.current.path;
  final walletd = File('$root/rust-fuego-wallet/target/release/fuego_walletd');
  final swapd = File('$root/xfgo/swapxfg/xfg-swapd');
  final hasBins = walletd.existsSync() && swapd.existsSync();

  group('live daemon stack (testnet local)', () {
    test('NodeConnection local testnet starts proxy; swapd binary discoverable',
        () async {
      if (!hasBins) {
        // ignore: avoid_print
        print('SKIP: binaries not present');
        return;
      }

      final dm = DaemonManager(config: NetworkConfig.testnet);
      expect(dm.walletdPort, NetworkConfig.testnet.walletRpcPort);
      expect(dm.fuegodPort, NetworkConfig.testnet.daemonRpcPort);

      final rpc = FuegoRPCService(
        host: '127.0.0.1',
        port: NetworkConfig.testnet.walletRpcPort,
        networkConfig: NetworkConfig.testnet,
      );
      final nc = NodeConnection(
        daemonManager: dm,
        rpcService: rpc,
        networkConfig: NetworkConfig.testnet,
        mode: ConnectionMode.local,
      );

      // Prefer not fighting an already-healthy stack: if proxy answers, assert
      // connectivity instead of restarting.
      final already = await _httpGetOk(
        'http://127.0.0.1:${NetworkConfig.testnet.walletRpcPort}/health',
      );
      if (!already) {
        final ep = await nc.connect(useTestnet: true);
        expect(ep.proxyRunning, isTrue, reason: ep.error);
        expect(ep.walletPort, NetworkConfig.testnet.walletRpcPort);
      }

      final health = await _httpGetJson(
        'http://127.0.0.1:${NetworkConfig.testnet.walletRpcPort}/health',
      );
      expect(health['status'], 'ok');
      expect(health['wallet'], isA<Map<String, dynamic>>());

      // Chain via local proxy
      final bal = await rpc.getBalance();
      expect(bal.unlockedBalance, isNonNegative);

      // Swap daemon: either already running or started by connect
      final swapHealth = await _httpGetJson('http://127.0.0.1:18902/health');
      expect(swapHealth['status'], 'ok');
      expect(swapHealth['connected'], isTrue);
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('chain getinfo has height+status on testnet daemon port', () async {
      if (!hasBins) return;
      final port = NetworkConfig.testnet.daemonRpcPort;
      // Prefer local testnet node; if not up, try wallet proxy-forwarded getinfo
      Map<String, dynamic>? info;
      try {
        info = await _httpGetJson('http://127.0.0.1:$port/getinfo');
      } catch (_) {
        final rpc = FuegoRPCService(
          host: '127.0.0.1',
          port: NetworkConfig.testnet.walletRpcPort,
          networkConfig: NetworkConfig.testnet,
        );
        info = await rpc.getInfo();
      }
      expect(info['status'], anyOf('OK', 'ok'));
      expect(info['height'], isNotNull);
    });
  });
}

Future<bool> _httpGetOk(String url) async {
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close().timeout(const Duration(seconds: 2));
    await resp.drain<void>();
    client.close(force: true);
    return resp.statusCode == 200;
  } catch (_) {
    return false;
  }
}

Future<Map<String, dynamic>> _httpGetJson(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final req = await client.getUrl(Uri.parse(url));
  final resp = await req.close().timeout(const Duration(seconds: 5));
  final body = await resp.transform(utf8.decoder).join();
  client.close(force: true);
  if (resp.statusCode != 200) {
    throw StateError('HTTP ${resp.statusCode} for $url: $body');
  }
  return jsonDecode(body) as Map<String, dynamic>;
}
