import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'constants.dart';
import 'network_info.dart';
import 'transaction.dart';

class FuegoDaemonClient {
  String host;
  int port;
  final int walletPort;
  final http.Client _http;

  FuegoDaemonClient({
    this.host = '127.0.0.1',
    this.port = defaultRpcPort,
    this.walletPort = 18189,
    http.Client? client,
  }) : _http = client ?? http.Client();

  /// Update chain endpoint after connection resolution.
  void updateNode(String newHost, {int? newPort}) {
    host = newHost;
    if (newPort != null) port = newPort;
  }

  /// True when [host] is a loopback address suitable for key-bearing APIs.
  static bool isLocalHost(String host) {
    final h = host.trim().toLowerCase();
    return h == '127.0.0.1' || h == 'localhost' || h == '::1' || h == '0.0.0.0';
  }

  Uri _rest(String path, {bool useWallet = false}) => Uri(
    scheme: 'http',
    host: useWallet ? '127.0.0.1' : host,
    port: useWallet ? walletPort : port,
    path: path,
  );

  void _log(String message) {
    if (kDebugMode) {
      debugPrint(message);
    }
  }

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, String>? query,
    bool useWallet = false,
  }) async {
    final uri = _rest(
      path,
      useWallet: useWallet,
    ).replace(queryParameters: query);
    _log('[daemon] GET $uri');
    final resp = await _http.get(uri).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw FuegoRpcException('HTTP ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    bool useWallet = false,
  }) async {
    final uri = _rest(path, useWallet: useWallet);
    _log('[daemon] POST $uri');
    final resp = await _http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw FuegoRpcException('HTTP ${resp.statusCode}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (data.containsKey('error') && data['error'] != null) {
      throw FuegoRpcException(data['error'].toString());
    }
    return data;
  }

  // ── Network info ──

  Future<NetworkInfo> getInfo() async {
    final r = await _post('/json_rpc', {
      'jsonrpc': '2.0',
      'id': 'fuego_core',
      'method': 'getinfo',
      'params': {},
    }, useWallet: true);
    final result = r['result'] as Map<String, dynamic>? ?? r;
    return NetworkInfo.fromJson(result);
  }

  Future<int> getPeerCount() async {
    final r = await _post('/json_rpc', {
      'jsonrpc': '2.0',
      'id': 'fuego_core',
      'method': 'getinfo',
      'params': {},
    }, useWallet: true);
    final result = r['result'] as Map<String, dynamic>? ?? r;
    final outgoing = result['outgoing_connections_count'] as int? ?? 0;
    final incoming = result['incoming_connections_count'] as int? ?? 0;
    return outgoing + incoming;
  }

  Future<int> getWalletHeight() async {
    try {
      final r = await _post('/json_rpc', {
        'jsonrpc': '2.0',
        'id': 'fuego_core',
        'method': 'getStatus',
        'params': {},
      }, useWallet: true);
      final result = r['result'] as Map<String, dynamic>? ?? r;
      return (result['height'] as int?) ??
          (result['scanned_height'] as int?) ??
          (result['current_height'] as int?) ??
          0;
    } catch (_) {
      final health = await _get('/health', useWallet: true);
      final wallet = health['wallet'] as Map<String, dynamic>?;
      return (health['scanned_height'] as int?) ??
          (wallet?['height'] as int?) ??
          0;
    }
  }

  // ── Wallet operations (local walletd / backend only) ──

  Future<String> getWalletAddress() async {
    final r = await _post('/json_rpc', {
      'jsonrpc': '2.0',
      'id': 'fuego_core',
      'method': 'getAddress',
      'params': {},
    }, useWallet: true);
    final result = r['result'] as Map<String, dynamic>? ?? r;
    return (result['address'] as String?) ?? '';
  }

  Future<String> getAddress() async {
    final r = await _post('/json_rpc', {
      'jsonrpc': '2.0',
      'id': 'fuego_core',
      'method': 'getAddresses',
      'params': {},
    }, useWallet: true);
    final result = r['result'] as Map<String, dynamic>? ?? r;
    final addresses = result['addresses'] as List<dynamic>? ?? [];
    return addresses.isNotEmpty ? addresses.first as String : '';
  }

  Future<int> getBalance() async {
    final r = await _post('/json_rpc', {
      'jsonrpc': '2.0',
      'id': 'fuego_core',
      'method': 'getBalance',
      'params': {},
    }, useWallet: true);
    final result = r['result'] as Map<String, dynamic>? ?? r;
    return (result['availableBalance'] ?? result['balance'] ?? 0) as int;
  }

  Future<({int available, int locked, int lockedDeposit, int unlockedDeposit, int lockedHeat, int unlockedHeat})> getBalanceDetailed() async {
    final r = await _post('/json_rpc', {
      'jsonrpc': '2.0',
      'id': 'fuego_core',
      'method': 'getBalance',
      'params': {},
    }, useWallet: true);
    final result = r['result'] as Map<String, dynamic>? ?? r;
    final available =
        (result['availableBalance'] ??
                result['available_balance'] ??
                result['balance'] ??
                0)
            as int;
    final locked =
        (result['lockedAmount'] ?? result['locked_amount'] ?? 0) as int;
    final lockedDeposit =
        (result['lockedDepositBalance'] ?? 0) as int;
    final unlockedDeposit =
        (result['unlockedDepositBalance'] ?? 0) as int;
    final lockedHeat =
        (result['lockedHeatBalance'] ?? 0) as int;
    final unlockedHeat =
        (result['unlockedHeatBalance'] ?? 0) as int;
    return (
      available: available,
      locked: locked,
      lockedDeposit: lockedDeposit,
      unlockedDeposit: unlockedDeposit,
      lockedHeat: lockedHeat,
      unlockedHeat: unlockedHeat,
    );
  }

  Future<String> sendTransaction(SendTransactionRequest req) async {
    final r = await _post('/json_rpc', {
      'jsonrpc': '2.0',
      'id': 'fuego_core',
      'method': 'sendTransaction',
      'params': {
        'transfers': [
          {'amount': (req.amount * 1e7).toInt(), 'address': req.address},
        ],
        'fee': (req.fee * 1e7).toInt(),
        'anonymity': req.mixin,
        if (req.paymentId != null) 'paymentId': req.paymentId,
      },
    }, useWallet: true);
    final result = r['result'] as Map<String, dynamic>? ?? r;
    final hash = result['transactionHash'] as String? ?? '';
    if (hash.isEmpty) {
      throw FuegoRpcException('Empty transaction hash from daemon');
    }
    return hash;
  }

  Future<List<FuegoTransaction>> getTransactions({int count = 20}) async {
    final r = await _post('/json_rpc', {
      'jsonrpc': '2.0',
      'id': 'fuego_core',
      'method': 'getTransactions',
      'params': {'blockCount': count, 'firstBlockIndex': 0},
    }, useWallet: true);
    final result = r['result'] as Map<String, dynamic>? ?? r;
    final items = result['items'] as List<dynamic>? ?? [];
    final txs = <FuegoTransaction>[];
    for (final item in items) {
      final txList = item['transactions'] as List<dynamic>? ?? [];
      for (final t in txList) {
        final map = Map<String, dynamic>.from(t as Map);
        final amountVal = map['amount'];
        final amountNum = amountVal is num ? amountVal.toInt() : 0;
        map['direction'] = amountNum < 0 ? 'out' : 'in';
        txs.add(FuegoTransaction.fromJson(map));
      }
    }
    txs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return txs.take(count).toList();
  }

  // ── Mining ──

  Future<void> startMining({int threads = 1, String? address}) async {
    try {
      await _post('/json_rpc', {
        'jsonrpc': '2.0',
        'id': 'fuego_core',
        'method': 'start_mining',
        'params': {
          'threads_count': threads,
          if (address != null) 'miner_address': address,
        },
      });
    } catch (_) {}
  }

  Future<void> stopMining() async {
    try {
      await _post('/json_rpc', {
        'jsonrpc': '2.0',
        'id': 'fuego_core',
        'method': 'stop_mining',
        'params': {},
      });
    } catch (_) {}
  }

  Future<Map<String, dynamic>> getMiningStatus() async {
    try {
      final r = await _post('/json_rpc', {
        'jsonrpc': '2.0',
        'id': 'fuego_core',
        'method': 'getinfo',
        'params': {},
      }, useWallet: true);
      final result = r['result'] as Map<String, dynamic>? ?? r;
      return {
        'active': (result['mining_speed'] ?? 0) > 0,
        'speed': result['mining_speed'] ?? 0,
        'hashrate': result['mining_speed'] ?? 0,
        'threads': result['threads_count'] ?? 0,
      };
    } catch (_) {
      return {};
    }
  }

  Future<Map<String, dynamic>> getStatus() async {
    return await _get('/status');
  }

  /// Fetch raw ΗΞΔŦ metrics (supply, TWAP redemption price, treasury, CD
  /// yield) from the daemon's `/heat_metrics` endpoint.
  Future<Map<String, dynamic>> getHeatMetricsRaw() async {
    return await _get('/heat_metrics');
  }

  /// Scan blockchain for outputs belonging to our keys.
  ///
  /// **Security:** always targets the local backend (`127.0.0.1:walletPort`).
  /// Never sends view secrets to remote seed nodes.
  Future<Map<String, dynamic>> scanBalance({
    required String viewSecret,
    required String spendPublic,
    int startHeight = 0,
    int batchSize = 100,
  }) async {
    if (viewSecret.isEmpty || spendPublic.isEmpty) {
      throw FuegoRpcException('Missing keys for scan_balance');
    }
    // Force loopback — ignore configured remote host for key-bearing calls
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: walletPort,
      path: '/scan_balance',
    );
    _log('[daemon] POST $uri (scan_balance, local-only)');
    final resp = await _http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'view_secret': viewSecret,
            'spend_public': spendPublic,
            'start_height': startHeight,
            'batch_size': batchSize,
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) {
      throw FuegoRpcException('scan_balance HTTP ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  void dispose() => _http.close();
}

class FuegoRpcException implements Exception {
  final String message;
  const FuegoRpcException(this.message);
  @override
  String toString() => 'FuegoRpcException: $message';
}
