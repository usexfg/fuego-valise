import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Dart EventBus mirroring the fuego-suite dashboard's unified daemon monitoring.
///
/// Polls all 3 daemons (fuegod, walletd, xfg-swapd) on independent timers,
/// broadcasts typed events to all listeners. Single source of truth for
/// daemon health, chain state, and swap status.
class DaemonEventBus {
  // ── Event types (matches fuego-suite dashboard) ─────────────────────────
  static const String eventHealth = 'health';
  static const String eventBlock = 'block';
  static const String eventHeat = 'heat_metric';
  static const String eventPool = 'pool_info';
  static const String eventSwap = 'swap_update';
  static const String eventSpv = 'spv_status';
  static const String eventOrderbook = 'orderbook';
  static const String eventError = 'error';

  // ── State ────────────────────────────────────────────────────────
  final StreamController<DaemonEvent> _controller =
      StreamController<DaemonEvent>.broadcast();
  Stream<DaemonEvent> get stream => _controller.stream;

  /// Current health snapshot — always最新 state.
  final ValueNotifier<DaemonHealthSnapshot> health =
      ValueNotifier(const DaemonHealthSnapshot());

  /// Latest block info from fuegod.
  final ValueNotifier<Map<String, dynamic>?> blockInfo =
      ValueNotifier(null);

  /// Latest HEAT metrics.
  final ValueNotifier<Map<String, dynamic>?> heatMetrics =
      ValueNotifier(null);

  /// Latest pool info.
  final ValueNotifier<Map<String, dynamic>?> poolInfo =
      ValueNotifier(null);

  // ── Timers ───────────────────────────────────────────────────────
  Timer? _fuegodTimer;
  Timer? _walletdTimer;
  Timer? _swapdTimer;

  // ── Config ───────────────────────────────────────────────────────
  String fuegodHost = '127.0.0.1';
  int fuegodPort = 18180;
  int walletdPort = 18189;
  int swapdPort = 18902;

  // ── Lifecycle ────────────────────────────────────────────────────

  /// Start polling all daemons.
  ///
  /// [fuegodHost] is `127.0.0.1` in local mode, or the remote seed host
  /// when the wallet proxy is in remote mode.
  void start({
    String fuegodHost = '127.0.0.1',
    int fuegodPort = 18180,
    int walletdPort = 18189,
    int swapdPort = 18902,
  }) {
    stop();
    this.fuegodHost = fuegodHost;
    this.fuegodPort = fuegodPort;
    this.walletdPort = walletdPort;
    this.swapdPort = swapdPort;

    // Immediate first poll
    _pollFuegod();
    _pollWalletd();
    _pollSwapd();

    // Then on timers (matches fuego-suite dashboard intervals)
    _fuegodTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => _pollFuegod());
    _walletdTimer = Timer.periodic(
        const Duration(seconds: 10), (_) => _pollWalletd());
    _swapdTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => _pollSwapd());
  }

  /// Stop all polling.
  void stop() {
    _fuegodTimer?.cancel();
    _walletdTimer?.cancel();
    _swapdTimer?.cancel();
    _fuegodTimer = null;
    _walletdTimer = null;
    _swapdTimer = null;
  }

  void dispose() {
    stop();
    _controller.close();
    health.dispose();
    blockInfo.dispose();
    heatMetrics.dispose();
    poolInfo.dispose();
  }

  // ── Pollers (mirrors fuego-suite dashboard pollDaemon/pollWallet/pollSwapd) ──

  String get _fuegodBase => 'http://$fuegodHost:$fuegodPort';

  Future<void> _pollFuegod() async {
    try {
      // ── Unified mode: HTTP GET /health on walletdPort ──
      // Each branch creates its own HttpClient so a closed client
      // is never reused after an exception.
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
        final req = await client.getUrl(
            Uri.parse('http://127.0.0.1:$walletdPort/health'));
        final resp = await req.close().timeout(const Duration(seconds: 3));
        final body = await resp.transform(utf8.decoder).join();
        client.close(force: true);

        debugPrint('[EventBus] fuegod unified GET /health body=$body');

        if (resp.statusCode == 200) {
          final data = jsonDecode(body) as Map<String, dynamic>;
          // Rust walletd reports the embedded chain as `daemon` (newer
          // builds) or `fuego` (older builds). Accept both.
          final daemonOk = data.containsKey('daemon')
              ? data['daemon'] as bool? ?? false
              : (data.containsKey('fuego')
                  ? data['fuego'] as bool? ?? false
                  : null);
          if (daemonOk != null) {
            if (daemonOk) {
              blockInfo.value = data;
              _emit(eventBlock, data);
            }
            _updateHealth(fuegodOk: daemonOk,
                fuegodError: daemonOk ? null : 'daemon embedded in unified: offline');
            return;
          }
          debugPrint('[EventBus] fuegod unified GET /health 200 but no daemon key');
        }
      } catch (e) {
        debugPrint('[EventBus] fuegod unified GET /health failed: $e');
      }

      // ── Standalone architecture: direct getinfo on fuegod port ──
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
        final req = await client.getUrl(
            Uri.parse('$_fuegodBase/getinfo'));
        final resp = await req.close().timeout(const Duration(seconds: 3));
        final body = await resp.transform(utf8.decoder).join();
        client.close(force: true);

        debugPrint('[EventBus] fuegod standalone GET 200 body=$body');

        if (resp.statusCode == 200) {
          final data = jsonDecode(body) as Map<String, dynamic>;
          blockInfo.value = data;
          _emit(eventBlock, data);
          _updateHealth(fuegodOk: true);
        } else {
          _updateHealth(fuegodOk: false, fuegodError: 'HTTP ${resp.statusCode}');
        }
      } catch (e) {
        debugPrint('[EventBus] fuegod standalone GET failed: $e');
        _updateHealth(fuegodOk: false, fuegodError: 'Connection refused');
      }

      // HEAT metrics (matches fuego-suite pollDaemon line 195)
      try {
        final heatClient = HttpClient()
          ..connectionTimeout = const Duration(seconds: 3);
        final req = await heatClient.getUrl(
            Uri.parse('$_fuegodBase/heat_metrics'));
        final resp = await req.close().timeout(const Duration(seconds: 3));
        final body = await resp.transform(utf8.decoder).join();
        heatClient.close(force: true);

        if (resp.statusCode == 200) {
          final data = jsonDecode(body) as Map<String, dynamic>;
          heatMetrics.value = data;
          _emit(eventHeat, data);
        }
      } catch (_) {}

      // Pool info (matches fuego-suite pollDaemon line 200)
      try {
        final poolClient = HttpClient()
          ..connectionTimeout = const Duration(seconds: 3);
        final req = await poolClient.getUrl(
            Uri.parse('$_fuegodBase/amm_pool_info'));
        final resp = await req.close().timeout(const Duration(seconds: 3));
        final body = await resp.transform(utf8.decoder).join();
        poolClient.close(force: true);

        if (resp.statusCode == 200) {
          final data = jsonDecode(body) as Map<String, dynamic>;
          poolInfo.value = data;
          _emit(eventPool, data);
        }
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> _pollWalletd() async {
    try {
      // ── Direct HTTP GET /health (Rust proxy) ──
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
        final req = await client.getUrl(
            Uri.parse('http://127.0.0.1:$walletdPort/health'));
        final resp = await req.close().timeout(const Duration(seconds: 3));
        final body = await resp.transform(utf8.decoder).join();
        client.close(force: true);

        debugPrint('[EventBus] walletd GET /health body=$body');

        if (resp.statusCode == 200) {
          final data = jsonDecode(body) as Map<String, dynamic>;
          _updateHealth(walletdOk: true, walletdData: data);
          return;
        } else {
          _updateHealth(walletdOk: false, walletdError: 'HTTP ${resp.statusCode}');
          return;
        }
      } catch (e) {
        debugPrint('[EventBus] walletd GET /health failed: $e');
      }

      _updateHealth(walletdOk: false, walletdError: 'Connection refused');
    } catch (_) {}
  }

  Future<void> _pollSwapd() async {
    try {
      // ── Unified daemon: swapd health via GET /health on walletdPort ──
      bool healthHandled = false;
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
        final req = await client.getUrl(
            Uri.parse('http://127.0.0.1:$walletdPort/health'));
        final resp = await req.close().timeout(const Duration(seconds: 3));
        final body = await resp.transform(utf8.decoder).join();
        client.close(force: true);

        debugPrint('[EventBus] swapd unified GET /health body=$body');

        if (resp.statusCode == 200) {
          final data = jsonDecode(body) as Map<String, dynamic>;
          if (data.containsKey('swap')) {
            final swapOk = data['swap'] as bool? ?? false;
            _updateHealth(swapdOk: swapOk);
            if (swapOk) {
              _emit(eventSwap, data);
            }
            healthHandled = true;
          } else {
            debugPrint('[EventBus] swapd unified GET /health no "swap" key');
          }
        }
      } catch (e) {
        debugPrint('[EventBus] swapd unified GET /health failed: $e');
      }

      if (!healthHandled) {
        // ── Standalone xfg-swapd: GET /health (or /status) on swapdPort ──
        bool standaloneOk = false;
        for (final path in ['/health', '/status']) {
          try {
            final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
            final req = await client.getUrl(
                Uri.parse('http://127.0.0.1:$swapdPort$path'));
            final resp = await req.close().timeout(const Duration(seconds: 3));
            final body = await resp.transform(utf8.decoder).join();
            client.close(force: true);

            debugPrint('[EventBus] swapd standalone GET $path 200 body=$body');

            if (resp.statusCode == 200) {
              final data = jsonDecode(body) as Map<String, dynamic>;
              _updateHealth(swapdOk: true);
              _emit(eventSwap, data);
              standaloneOk = true;
              break;
            }
          } catch (e) {
            debugPrint('[EventBus] swapd standalone GET $path failed: $e');
          }
        }
        if (!standaloneOk) {
          _updateHealth(swapdOk: false, swapdError: 'Connection refused');
        }
      }

      // ── SPV status emit (Act 3): poll xfg-swapd list_swaps and emit eventSpv ──
      // Ensure broadcast controller exists (it does — _controller is broadcast).
      // Only emit when any non-terminal swap has a ctrLockTxId.
      try {
        await _pollAndEmitSpv();
      } catch (e) {
        debugPrint('[EventBus] spv poll failed: $e');
      }
    } catch (_) {}
  }

  Future<void> _pollAndEmitSpv() async {
    final List<Map<String, dynamic>> swaps = await _fetchSpvSwaps();
    if (swaps.isEmpty) {
      return;
    }
    final List<Map<String, dynamic>> filtered = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> raw in swaps) {
      final String state = _extractState(raw);
      if (_isTerminalState(state)) {
        continue;
      }
      final String? txid = _extractCtrLockTxId(raw);
      if (txid == null || txid.isEmpty) {
        continue;
      }
      final int confirmations = _extractInt(raw, ['confirmations', 'confirmations', 'confirmations']) ?? 0;
      final int requiredConfirmations = _extractInt(raw, ['requiredConfirmations', 'required_confirmations']) ?? 6;
      final int blockHeight = _extractInt(raw, ['blockHeight', 'block_height']) ?? 0;
      final bool spvVerified = _extractBool(raw, ['spvVerified', 'spv_verified']) ?? false;
      final String explorerUrl = _explorerUrlFor(raw, txid);
      final Map<String, dynamic> entry = <String, dynamic>{
        'swapId': _extractString(raw, ['swapId', 'swap_id']) ?? '',
        'confirmations': confirmations,
        'requiredConfirmations': requiredConfirmations,
        'spvVerified': spvVerified,
        'blockHeight': blockHeight,
        'explorerUrl': explorerUrl,
      };
      filtered.add(entry);
    }
    if (filtered.isEmpty) {
      return;
    }
    // Ensure controller still open for eventSpv.
    if (_controller.isClosed) {
      return;
    }
    final Map<String, dynamic> payload = <String, dynamic>{
      'swaps': filtered,
      'count': filtered.length,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
    _emit(eventSpv, payload);
    debugPrint('[EventBus] emitted $eventSpv with ${filtered.length} swap(s)');
  }

  Future<List<Map<String, dynamic>>> _fetchSpvSwaps() async {
    // Try standalone swapd JSON-RPC first, then unified walletd proxy if needed.
    final List<String> endpoints = <String>[
      'http://127.0.0.1:$swapdPort/',
      'http://127.0.0.1:$walletdPort/',
    ];
    for (final String url in endpoints) {
      try {
        final HttpClient client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
        final HttpClientRequest req = await client.postUrl(Uri.parse(url));
        req.headers.set('Content-Type', 'application/json');
        final String body = jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'list_swaps',
          'params': <String, dynamic>{},
        });
        req.add(utf8.encode(body));
        final HttpClientResponse resp = await req.close().timeout(const Duration(seconds: 3));
        final String respBody = await resp.transform(utf8.decoder).join();
        client.close(force: true);
        if (resp.statusCode != 200) {
          continue;
        }
        final Map<String, dynamic> decoded = jsonDecode(respBody) as Map<String, dynamic>;
        if (decoded.containsKey('error') && decoded['error'] != null) {
          continue;
        }
        final dynamic result = decoded['result'];
        if (result is Map<String, dynamic>) {
          final dynamic swapsDyn = result['swaps'];
          if (swapsDyn is List) {
            final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
            for (final dynamic item in swapsDyn) {
              if (item is Map<String, dynamic>) {
                out.add(item);
              } else if (item is Map) {
                out.add(Map<String, dynamic>.from(item));
              }
            }
            if (out.isNotEmpty || result.containsKey('swaps')) {
              return out;
            }
          }
        } else if (result is List) {
          final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
          for (final dynamic item in result) {
            if (item is Map<String, dynamic>) {
              out.add(item);
            }
          }
          return out;
        }
      } catch (_) {
        continue;
      }
    }
    return <Map<String, dynamic>>[];
  }

  String _extractState(Map<String, dynamic> raw) {
    final dynamic params = raw['params'];
    if (params is Map) {
      final dynamic s = params['state'] ?? params['stateName'];
      if (s is String && s.isNotEmpty) {
        return s;
      }
    }
    final dynamic direct = raw['state'] ?? raw['stateName'];
    if (direct is String && direct.isNotEmpty) {
      return direct;
    }
    if (direct is num) {
      return direct.toString();
    }
    return '';
  }

  String? _extractCtrLockTxId(Map<String, dynamic> raw) {
    final List<String> keys = <String>['ctrLockTxId', 'ctr_lock_txid', 'ctrLockTxid', 'ctrLockTxId'];
    final dynamic params = raw['params'];
    if (params is Map) {
      for (final String k in keys) {
        final dynamic v = params[k];
        if (v is String && v.isNotEmpty) {
          return v;
        }
      }
    }
    for (final String k in keys) {
      final dynamic v = raw[k];
      if (v is String && v.isNotEmpty) {
        return v;
      }
    }
    return null;
  }

  int? _extractInt(Map<String, dynamic> raw, List<String> keys) {
    final dynamic params = raw['params'];
    if (params is Map) {
      for (final String k in keys) {
        final dynamic v = params[k];
        if (v is num) {
          return v.toInt();
        }
      }
    }
    for (final String k in keys) {
      final dynamic v = raw[k];
      if (v is num) {
        return v.toInt();
      }
    }
    return null;
  }

  bool? _extractBool(Map<String, dynamic> raw, List<String> keys) {
    final dynamic params = raw['params'];
    if (params is Map) {
      for (final String k in keys) {
        final dynamic v = params[k];
        if (v is bool) {
          return v;
        }
      }
    }
    for (final String k in keys) {
      final dynamic v = raw[k];
      if (v is bool) {
        return v;
      }
    }
    return null;
  }

  String? _extractString(Map<String, dynamic> raw, List<String> keys) {
    final dynamic params = raw['params'];
    if (params is Map) {
      for (final String k in keys) {
        final dynamic v = params[k];
        if (v is String && v.isNotEmpty) {
          return v;
        }
      }
    }
    for (final String k in keys) {
      final dynamic v = raw[k];
      if (v is String && v.isNotEmpty) {
        return v;
      }
    }
    return null;
  }

  String _explorerUrlFor(Map<String, dynamic> raw, String txid) {
    final String? pairName = _extractPairName(raw);
    if (pairName == null || pairName.isEmpty) {
      return '';
    }
    // Minimal explorer map inline to avoid importing ChainInfo if not needed.
    const Map<String, String> explorerTx = <String, String>{
      'BTC': 'https://mempool.space/tx/{txid}',
      'LTC': 'https://litecoinspace.org/tx/{txid}',
      'BCH': 'https://blockchair.com/bitcoin-cash/transaction/{txid}',
      'KMD': 'https://kmdexplorer.io/tx/{txid}',
      'DCR': 'https://dcrdata.decred.org/tx/{txid}',
      'ETH': 'https://etherscan.io/tx/{txid}',
      'ARB': 'https://arbiscan.io/tx/{txid}',
      'BASE': 'https://basescan.org/tx/{txid}',
      'BNB': 'https://bscscan.com/tx/{txid}',
      'POLY': 'https://polygonscan.com/tx/{txid}',
      'SOL': 'https://solscan.io/tx/{txid}',
      'XMR': 'https://xmrchain.net/tx/{txid}',
    };
    final String? tmpl = explorerTx[pairName];
    if (tmpl == null) {
      return '';
    }
    return tmpl.replaceAll('{txid}', txid);
  }

  String? _extractPairName(Map<String, dynamic> raw) {
    final dynamic params = raw['params'];
    int? pairId;
    if (params is Map) {
      final dynamic v = params['pair'];
      if (v is num) {
        pairId = v.toInt();
      }
    }
    if (pairId == null) {
      final dynamic v = raw['pair'];
      if (v is num) {
        pairId = v.toInt();
      }
    }
    if (pairId == null) {
      return null;
    }
    const Map<int, String> names = <int, String>{
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
      11: 'POLYGON',
    };
    return names[pairId];
  }

  bool _isTerminalState(String state) {
    const Set<String> terminal = <String>{
      'ADAPTOR_XFG_SPENT',
      'ADAPTOR_REFUNDED',
      'AFK_CLAIMED',
      'AFK_REFUNDED',
      'FAILED',
      'XFG_REFUNDED',
      'XFG_CLAIMED',
      'CTR_CLAIMED',
      'CTR_REFUNDED',
    };
    if (terminal.contains(state)) {
      return true;
    }
    return false;
  }

  // ── Health state management ──────────────────────────────────────

  void _updateHealth({
    bool? fuegodOk,
    bool? walletdOk,
    bool? swapdOk,
    String? fuegodError,
    String? walletdError,
    String? swapdError,
    Map<String, dynamic>? walletdData,
  }) {
    final prev = health.value;
    health.value = DaemonHealthSnapshot(
      fuegodRunning: fuegodOk ?? prev.fuegodRunning,
      walletdRunning: walletdOk ?? prev.walletdRunning,
      swapdRunning: swapdOk ?? prev.swapdRunning,
      fuegodError: fuegodOk == false
          ? (fuegodError ?? prev.fuegodError)
          : (fuegodOk == true ? null : prev.fuegodError),
      walletdError: walletdOk == false
          ? (walletdError ?? prev.walletdError)
          : (walletdOk == true ? null : prev.walletdError),
      swapdError: swapdOk == false
          ? (swapdError ?? prev.swapdError)
          : (swapdOk == true ? null : prev.swapdError),
      walletdData: walletdData ?? prev.walletdData,
    );

    _emit(eventHealth, health.value.toJson());
  }

  // ── Event emission ───────────────────────────────────────────────

  void _emit(String type, Map<String, dynamic> payload) {
    if (_controller.isClosed) return;
    _controller.add(DaemonEvent(
      type: type,
      payload: payload,
      time: DateTime.now(),
    ));
  }
}

/// Typed event from the daemon event bus.
class DaemonEvent {
  final String type;
  final Map<String, dynamic> payload;
  final DateTime time;

  const DaemonEvent({
    required this.type,
    required this.payload,
    required this.time,
  });
}

/// Snapshot of all daemon health states.
class DaemonHealthSnapshot {
  final bool fuegodRunning;
  final bool walletdRunning;
  final bool swapdRunning;
  final String? fuegodError;
  final String? walletdError;
  final String? swapdError;
  final Map<String, dynamic>? walletdData;

  const DaemonHealthSnapshot({
    this.fuegodRunning = false,
    this.walletdRunning = false,
    this.swapdRunning = false,
    this.fuegodError,
    this.walletdError,
    this.swapdError,
    this.walletdData,
  });

  bool get allHealthy => fuegodRunning && walletdRunning && swapdRunning;
  bool get anyRunning => fuegodRunning || walletdRunning || swapdRunning;

  String get displayText {
    final parts = <String>[];
    if (!fuegodRunning) parts.add('Node: ${fuegodError ?? "offline"}');
    if (!walletdRunning) parts.add('Wallet: ${walletdError ?? "offline"}');
    if (!swapdRunning) parts.add('Swap: ${swapdError ?? "offline"}');
    if (parts.isEmpty) return 'All daemons running';
    return parts.join(' \u2022 ');
  }

  Map<String, dynamic> toJson() => {
        'daemon': fuegodRunning,
        'wallet': walletdRunning,
        'swapd': swapdRunning,
        if (fuegodError != null) 'daemon_error': fuegodError,
        if (walletdError != null) 'wallet_error': walletdError,
        if (swapdError != null) 'swapd_error': swapdError,
      };
}