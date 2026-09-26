import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/network_config.dart';
import 'daemon_manager.dart';
import 'fuego_rpc_service.dart';

/// How the wallet reaches the Fuego chain.
enum ConnectionMode {
  /// Embedded/local fuegod via fuego_walletd --local (desktop default).
  local,

  /// Local fuego_walletd proxy talking to a remote seed node (mobile default).
  remote,
}

/// Resolved endpoints after connection setup.
class ConnectionEndpoints {
  final ConnectionMode mode;
  final String walletHost;
  final int walletPort;
  final String chainHost;
  final int chainPort;
  final bool proxyRunning;
  final String? error;

  const ConnectionEndpoints({
    required this.mode,
    required this.walletHost,
    required this.walletPort,
    required this.chainHost,
    required this.chainPort,
    required this.proxyRunning,
    this.error,
  });

  /// Base URL for all wallet JSON-RPC (always the proxy when it is up).
  String get walletBaseUrl => 'http://$walletHost:$walletPort';

  /// Chain (fuegod) endpoint — local loopback in local mode, seed node in remote.
  String get chainBaseUrl => 'http://$chainHost:$chainPort';

  bool get ok => error == null && proxyRunning;
}

/// Single source of truth for local vs remote daemon connection.
///
/// Platform defaults:
/// - Desktop (macOS / Linux / Windows): [ConnectionMode.local]
/// - Mobile (iOS / Android): [ConnectionMode.remote]
///
/// Overrides (priority high → low):
/// 1. `FUEGO_USE_LOCAL_NODE` env (`1`/`true` or `0`/`false`)
/// 2. User preference in SharedPreferences
/// 3. Platform default
class NodeConnection {
  static const _prefsModeKey = 'node_connection_mode';
  static const _prefsHostKey = 'node_remote_host';
  static const _prefsPortKey = 'node_remote_port';
  static const prefsNetworkKey = 'node_network';

  final DaemonManager daemonManager;
  final FuegoRPCService rpcService;
  NetworkConfig _networkConfig;

  ConnectionMode _mode;
  String _remoteHost;
  int _remotePort;
  ConnectionEndpoints? _last;
  final List<void Function(ConnectionEndpoints)> _listeners = [];

  NodeConnection({
    required this.daemonManager,
    required this.rpcService,
    required NetworkConfig networkConfig,
    ConnectionMode? mode,
    String? remoteHost,
    int? remotePort,
  })  : _networkConfig = networkConfig,
        _mode = mode ?? platformDefaultMode(),
        _remoteHost = remoteHost ?? _defaultRemoteHost(networkConfig),
        _remotePort = remotePort ?? networkConfig.daemonRpcPort;

  NetworkConfig get networkConfig => _networkConfig;
  ConnectionMode get mode => _mode;
  String get remoteHost => _remoteHost;
  int get remotePort => _remotePort;
  ConnectionEndpoints? get lastEndpoints => _last;
  bool get useLocalNode => _mode == ConnectionMode.local;

  static bool get isDesktop =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  static bool get isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Desktop → local, mobile/web → remote.
  static ConnectionMode platformDefaultMode() {
    final env = Platform.environment['FUEGO_USE_LOCAL_NODE'];
    if (env != null) {
      final v = env.toLowerCase();
      if (v == '1' || v == 'true') return ConnectionMode.local;
      if (v == '0' || v == 'false') return ConnectionMode.remote;
    }
    return isDesktop ? ConnectionMode.local : ConnectionMode.remote;
  }

  static String _defaultRemoteHost(NetworkConfig config) {
    final env = Platform.environment['FUEGO_DAEMON_HOST'];
    if (env != null && env.isNotEmpty) return env;
    final seed = config.defaultSeedNode;
    if (seed.contains(':')) return seed.split(':').first;
    return seed.isNotEmpty ? seed : '207.244.247.64';
  }

  static int _defaultRemotePort(NetworkConfig config) {
    final env = Platform.environment['FUEGO_DAEMON_PORT'];
    if (env != null) {
      final p = int.tryParse(env);
      if (p != null) return p;
    }
    final seed = config.defaultSeedNode;
    if (seed.contains(':')) {
      final p = int.tryParse(seed.split(':').last);
      if (p != null) return p;
    }
    return config.daemonRpcPort;
  }

  void addListener(void Function(ConnectionEndpoints) cb) => _listeners.add(cb);
  void removeListener(void Function(ConnectionEndpoints) cb) =>
      _listeners.remove(cb);

  void _notify(ConnectionEndpoints ep) {
    _last = ep;
    for (final cb in List.of(_listeners)) {
      try {
        cb(ep);
      } catch (e) {
        debugPrint('[node] listener error: $e');
      }
    }
  }

  /// Load user preference (if any). Env still wins over prefs for mode.
  Future<void> loadPreferences() async {
    final env = Platform.environment['FUEGO_USE_LOCAL_NODE'];
    final prefs = await SharedPreferences.getInstance();

    if (env == null) {
      final stored = prefs.getString(_prefsModeKey);
      if (stored == 'local') {
        _mode = ConnectionMode.local;
      } else if (stored == 'remote') {
        _mode = ConnectionMode.remote;
      } else {
        _mode = platformDefaultMode();
      }
    } else {
      _mode = platformDefaultMode();
    }

    final host = prefs.getString(_prefsHostKey);
    if (host != null && host.isNotEmpty) {
      _remoteHost = host;
    } else {
      _remoteHost = _defaultRemoteHost(networkConfig);
    }

    final port = prefs.getInt(_prefsPortKey);
    if (port != null && port > 0) {
      _remotePort = port;
    } else {
      _remotePort = _defaultRemotePort(networkConfig);
    }

    debugPrint(
      '[node] prefs loaded mode=$_mode host=$_remoteHost:$_remotePort '
      '(platformDefault=${platformDefaultMode()})',
    );
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsModeKey,
      _mode == ConnectionMode.local ? 'local' : 'remote',
    );
    await prefs.setString(_prefsHostKey, _remoteHost);
    await prefs.setInt(_prefsPortKey, _remotePort);
  }

  /// Ordered seed candidates: preferred remote first, then NetworkConfig list.
  List<({String host, int port})> _seedCandidates() {
    final seen = <String>{};
    final out = <({String host, int port})>[];

    void add(String host, int port) {
      final key = '$host:$port';
      if (host.isEmpty || seen.contains(key)) return;
      seen.add(key);
      out.add((host: host, port: port));
    }

    add(_remoteHost, _remotePort);
    for (final seed in networkConfig.seedNodes) {
      if (seed.contains(':')) {
        final parts = seed.split(':');
        final p = int.tryParse(parts.last) ?? networkConfig.daemonRpcPort;
        add(parts.first, p);
      } else {
        add(seed, networkConfig.daemonRpcPort);
      }
    }
    return out;
  }

  /// Probe whether a seed node answers getinfo with a daemon-shaped body
  /// (3s timeout).
  Future<bool> _probeSeed(String host, int port) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(Uri.parse('http://$host:$port/getinfo'));
      final resp = await req.close().timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) return false;
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 3));
      if (body.length > 65536) return false; // cap probe body
      Object? decoded;
      try {
        decoded = jsonDecode(body);
      } catch (_) {
        decoded = null;
      }
      if (decoded is Map &&
          (decoded.containsKey('height') ||
              decoded.containsKey('status') ||
              decoded.containsKey('version'))) {
        return true;
      }
      return body.contains('"status"');
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Probe all seed candidates in parallel; pick the first reachable one in
  /// preference order. When every probe fails (probes are flaky — a timeout
  /// does not prove the node is down), fall back to the preferred seed so
  /// remote mode still attempts a real connection instead of dead-ending.
  Future<({String host, int port})> _resolveReachableSeed() async {
    final candidates = _seedCandidates();
    final results = await Future.wait(
      candidates.map((c) async {
        debugPrint('[node] probing seed ${c.host}:${c.port}…');
        final reachable = await _probeSeed(c.host, c.port);
        return (candidate: c, reachable: reachable);
      }),
    );
    for (final r in results) {
      if (r.reachable) {
        debugPrint(
          '[node] seed reachable: ${r.candidate.host}:${r.candidate.port}',
        );
        return r.candidate;
      }
    }
    debugPrint(
      '[node] no seed answered probe — using preferred $_remoteHost:$_remotePort',
    );
    return (host: _remoteHost, port: _remotePort);
  }

  /// Start daemons for the current mode and point [rpcService] at the wallet proxy.
  ///
  /// Always prefers a local `fuego_walletd` HTTP proxy on 127.0.0.1:walletPort.
  /// Local mode adds `--local` (embedded fuegod). Remote mode points the proxy
  /// at a reachable seed from [NetworkConfig.seedNodes].
  Future<ConnectionEndpoints> connect({bool useTestnet = false}) async {
    debugPrint('[node] === connect mode=$_mode testnet=$useTestnet ===');

    await daemonManager.stopAll();

    final walletPort = networkConfig.walletRpcPort;
    final local = _mode == ConnectionMode.local;

    if (!local) {
      final seed = await _resolveReachableSeed();
      _remoteHost = seed.host;
      _remotePort = seed.port;
    }

    final chainHost = local ? '127.0.0.1' : _remoteHost;
    final chainPort = local ? networkConfig.daemonRpcPort : _remotePort;

    final startErr = await daemonManager.startAll(
      useLocalNode: local,
      useTestnet: useTestnet,
      daemonHost: local ? '127.0.0.1' : _remoteHost,
      daemonPort: local ? networkConfig.daemonRpcPort : _remotePort,
      startSwapd: true,
    );

    if (startErr == null && daemonManager.walletdRunning) {
      // Wallet JSON-RPC always hits the local proxy.
      rpcService.updateNode('127.0.0.1', port: walletPort);
      final ep = ConnectionEndpoints(
        mode: _mode,
        walletHost: '127.0.0.1',
        walletPort: walletPort,
        chainHost: chainHost,
        chainPort: chainPort,
        proxyRunning: true,
      );
      debugPrint('[node] proxy up → ${ep.walletBaseUrl} (chain ${ep.chainBaseUrl})');
      _notify(ep);
      return ep;
    }

    // Proxy failed. Fallbacks:
    // 1) Desktop local → try remote proxy automatically
    // 2) Otherwise → direct remote chain (read-only / degraded)
    if (local && isDesktop) {
      debugPrint('[node] local failed ($startErr) — auto-fallback to remote proxy');
      final fallback = await _connectRemoteProxy(
        useTestnet: useTestnet,
        priorError: startErr,
      );
      if (fallback.proxyRunning) return fallback;
    }

    // Degraded: point RPC at the wallet proxy endpoint so wallet calls fail
    // cleanly with connection refused instead of "method not found" against
    // the raw chain daemon.
    rpcService.updateNode('127.0.0.1', port: walletPort);
    final ep = ConnectionEndpoints(
      mode: ConnectionMode.remote,
      walletHost: _remoteHost,
      walletPort: _remotePort,
      chainHost: _remoteHost,
      chainPort: _remotePort,
      proxyRunning: false,
      error: startErr ??
          'Wallet proxy unavailable. Connected to chain node only '
              '($_remoteHost:$_remotePort). Wallet ops require fuego_walletd.',
    );
    debugPrint('[node] degraded remote chain-only: ${ep.chainBaseUrl}');
    _notify(ep);
    return ep;
  }

  Future<ConnectionEndpoints> _connectRemoteProxy({
    required bool useTestnet,
    String? priorError,
  }) async {
    final walletPort = networkConfig.walletRpcPort;
    final seed = await _resolveReachableSeed();
    _remoteHost = seed.host;
    _remotePort = seed.port;

    final startErr = await daemonManager.startAll(
      useLocalNode: false,
      useTestnet: useTestnet,
      daemonHost: _remoteHost,
      daemonPort: _remotePort,
      startSwapd: true,
    );

    if (startErr == null && daemonManager.walletdRunning) {
      _mode = ConnectionMode.remote;
      rpcService.updateNode('127.0.0.1', port: walletPort);
      final ep = ConnectionEndpoints(
        mode: ConnectionMode.remote,
        walletHost: '127.0.0.1',
        walletPort: walletPort,
        chainHost: _remoteHost,
        chainPort: _remotePort,
        proxyRunning: true,
        error: priorError != null
            ? 'Local node failed ($priorError); using remote $_remoteHost:$_remotePort'
            : null,
      );
      await _savePreferences();
      _notify(ep);
      return ep;
    }

    return ConnectionEndpoints(
      mode: ConnectionMode.remote,
      walletHost: _remoteHost,
      walletPort: _remotePort,
      chainHost: _remoteHost,
      chainPort: _remotePort,
      proxyRunning: false,
      error: startErr ?? priorError ?? 'Failed to start wallet proxy',
    );
  }

  /// User switches to built-in local node.
  Future<ConnectionEndpoints> switchToLocal({bool useTestnet = false}) async {
    _mode = ConnectionMode.local;
    await _savePreferences();
    return connect(useTestnet: useTestnet);
  }

  /// User switches to a remote seed node (still prefers local proxy).
  Future<ConnectionEndpoints> switchToRemote({
    required String host,
    int? port,
    bool useTestnet = false,
  }) async {
    final h = host.trim();
    if (h.isEmpty) {
      return ConnectionEndpoints(
        mode: ConnectionMode.remote,
        walletHost: _remoteHost,
        walletPort: _remotePort,
        chainHost: _remoteHost,
        chainPort: _remotePort,
        proxyRunning: false,
        error: 'Remote host is empty',
      );
    }

    // Accept "host:port" or bare host — validated to prevent SSRF (ADV-01)
    String newHost;
    int newPort = port ?? _remotePort;
    if (h.contains(':') && !h.startsWith('[')) {
      final parts = h.split(':');
      if (parts.length != 2) {
        return ConnectionEndpoints(
          mode: ConnectionMode.remote, walletHost: _remoteHost, walletPort: _remotePort,
          chainHost: _remoteHost, chainPort: _remotePort, proxyRunning: false,
          error: 'Invalid host:port format',
        );
      }
      newHost = parts.first.trim();
      final parsed = int.tryParse(parts.last.trim());
      if (parsed == null || parsed < 1 || parsed > 65535) {
        return ConnectionEndpoints(
          mode: ConnectionMode.remote, walletHost: _remoteHost, walletPort: _remotePort,
          chainHost: _remoteHost, chainPort: _remotePort, proxyRunning: false,
          error: 'Invalid port (1-65535)',
        );
      }
      newPort = parsed;
    } else {
      newHost = h;
      if (port != null) {
        if (port < 1 || port > 65535) {
          return ConnectionEndpoints(
            mode: ConnectionMode.remote, walletHost: _remoteHost, walletPort: _remotePort,
            chainHost: _remoteHost, chainPort: _remotePort, proxyRunning: false,
            error: 'Invalid port (1-65535)',
          );
        }
        newPort = port;
      }
    }
    if (!_isValidRemoteHost(newHost)) {
      return ConnectionEndpoints(
        mode: ConnectionMode.remote, walletHost: _remoteHost, walletPort: _remotePort,
        chainHost: _remoteHost, chainPort: _remotePort, proxyRunning: false,
        error: 'Invalid or blocked host (SSRF guard)',
      );
    }
    _remoteHost = newHost;
    _remotePort = newPort;

    _mode = ConnectionMode.remote;
    await _savePreferences();
    return connect(useTestnet: useTestnet);
  }

  /// Switches mainnet/testnet at runtime: retargets ports and seeds, persists
  /// the choice for the next launch, then reconnects.
  Future<ConnectionEndpoints> switchNetwork(NetworkConfig config) async {
    _networkConfig = config;
    daemonManager.fuegodPort = config.daemonRpcPort;
    daemonManager.walletdPort = config.walletRpcPort;
    rpcService.updateNetworkConfig(config);
    _remoteHost = _defaultRemoteHost(config);
    _remotePort = _defaultRemotePort(config);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsNetworkKey, config.isTestnet ? 'testnet' : 'mainnet');
    await _savePreferences();
    return connect(useTestnet: config.isTestnet);
  }

  /// SSRF guard: allow DNS names + IPv4/IPv6, block link-local/metadata and obvious bad patterns.
  static bool _isValidRemoteHost(String host) {
    final h = host.trim();
    if (h.isEmpty || h.length > 253) return false;
    if (h.contains(' ') || h.contains('\t') || h.contains('\n') || h.contains('/')) return false;
    // Block link-local/cloud metadata and loopback tricks
    if (h.startsWith('169.254.') || h == '0.0.0.0' || h == '::' || h == '::1') return false;
    if (h.startsWith('169.254.') || h.contains('metadata.google.internal')) return false;
    // IPv4
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h)) {
      final parts = h.split('.').map(int.tryParse).toList();
      if (parts.any((p) => p == null || p < 0 || p > 255)) return false;
      // Already blocked 0.0.0.0 and 169.254 above; allow private for testnet
      return true;
    }
    // DNS name
    if (!RegExp(r'^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,61}[a-zA-Z0-9])?$').hasMatch(h)) return false;
    if (h.contains('..') || h.startsWith('-') || h.startsWith('.')) return false;
    return true;
  }

  Future<void> disconnect() async {
    await daemonManager.stopAll();
    _last = null;
  }
}
