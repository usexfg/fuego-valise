import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'daemon_event_bus.dart';
import 'security_service.dart';
import '../models/network_config.dart';

/// Unified process manager for all backend daemons.
///
/// Manages the unified daemon (fuegod + walletd + xfg-swapd in one process).
/// Default ports: fuegod=18180, walletd=18189, swapd=18902.
class DaemonManager {
  // ── Ports (configurable per network) ──────────────────────────────
  int fuegodPort;
  int walletdPort;
  int swapdPort;

  DaemonManager({
    NetworkConfig? config,
  }) : fuegodPort = config?.daemonRpcPort ?? 18180,
       walletdPort = config?.walletRpcPort ?? 18189,
       swapdPort = 18902;

  // ── Process handles ──────────────────────────────────────────────
  Process? _unified;
  Process? _fuegod;
  Process? _walletd;
  Process? _swapd;

  // ── External daemon detection (when user started daemons manually) ─
  bool _walletdExternallyRunning = false;
  bool _fuegodExternallyRunning = false;
  bool _swapdExternallyRunning = false;

  // ── Binary paths ─────────────────────────────────────────────────
  String? _fuegodBin;
  String? _walletdBin;
  String? _swapdBin;

  // ── State ────────────────────────────────────────────────────────
  final List<String> errors = [];
  final ValueNotifier<DaemonStatus> status = ValueNotifier(DaemonStatus());

  /// Mode of the last [startAll] — used to interpret walletd health
  /// (local mode requires an embedded fuegod; remote does not).
  bool _useLocalNode = true;

  /// True while [stopAll]/[stopSwapd] is tearing processes down — suppresses
  /// the xfg-swapd auto-restart so intentional stops don't respawn.
  bool _stopping = false;

  /// Bounded stderr buffer captured during unified daemon startup
  /// (release mode) so failures surface the real cause, not just the
  /// exit code (e.g. "Address already in use").
  StringBuffer? _unifiedExitLog;

  /// Unified event bus — single source of truth for daemon health.
  final DaemonEventBus eventBus = DaemonEventBus();

  /// Human-readable error from last `startAll()` call.
  String? _lastStartError;
  String? get lastStartError => _lastStartError;

  /// Detailed per-daemon startup error messages.
  final Map<String, String> daemonErrors = {};

  // ── Lifecycle ────────────────────────────────────────────────────

  /// Kill any process occupying [port], then return the freed port.
  /// Returns error message if port is occupied and cannot be freed.
  Future<String?> _freePort(int port) async {
    final pid = await _findPidOnPort(port);
    if (pid == null) return null;

    debugPrint('[daemon] Port $port in use by PID $pid — killing');
    final killed = await _killPid(pid);
    if (!killed) return 'Port $port is occupied by PID $pid and could not be killed';

    // Wait for port to be released
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (await _findPidOnPort(port) == null) return null;
    }
    return 'Port $port was occupied by PID $pid — killed but port not yet released';
  }

  /// Find PID of process listening on [port].
  Future<int?> _findPidOnPort(int port) async {
    try {
      if (Platform.isMacOS || Platform.isLinux) {
        final result = await Process.run('lsof', ['-ti', ':$port', '-sTCP:LISTEN']);
        final output = (result.stdout as String).trim();
        if (output.isNotEmpty) {
          final pid = int.tryParse(output.split('\n').first);
          if (pid != null && pid > 0) return pid;
        }
      } else if (Platform.isWindows) {
        final result = await Process.run('netstat', ['-ano']);
        final lines = (result.stdout as String).split('\n');
        for (final line in lines) {
          if (line.contains(':$port') && line.contains('LISTENING')) {
            final parts = line.trim().split(RegExp(r'\s+'));
            if (parts.isNotEmpty) {
              final pid = int.tryParse(parts.last);
              if (pid != null && pid > 0) return pid;
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Kill a process by PID.
  Future<bool> _killPid(int pid) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('taskkill', ['/F', '/PID', pid.toString()]);
        return result.exitCode == 0;
      } else {
        Process.killPid(pid, ProcessSignal.sigkill);
        // Wait briefly and verify
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return !Process.killPid(pid); // returns false if process is gone
      }
    } catch (_) {
      return false;
    }
  }

  // ── Binary discovery ─────────────────────────────────────────────

  String? _findUnifiedBinary() {
    final exe = File(Platform.resolvedExecutable);
    final candidates = [
      '${exe.parent.path}/unified',
      if (Platform.isMacOS) '${exe.parent.parent.parent.path}/Resources/bin/unified',
      '${Directory.current.path}/fuego-suite/build/src/unified',
      '${Directory.current.path}/fuego-suite/build/release/src/unified',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  String? _findFuegodBinary() {
    if (_fuegodBin != null && File(_fuegodBin!).existsSync()) return _fuegodBin;
    final exe = File(Platform.resolvedExecutable);
    final candidates = [
      '${exe.parent.path}/fuegod',
      if (Platform.isMacOS) '${exe.parent.parent.parent.path}/Resources/bin/fuegod',
      '${Directory.current.path}/rust-fuego-wallet/target/release/fuegod',
      '${Directory.current.path}/rust-fuego-wallet/target/debug/fuegod',
      '${Directory.current.path}/xfgo/build/src/fuegod',
      '${Directory.current.path}/fuego-suite/build/src/fuegod',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) {
        _fuegodBin = path;
        return path;
      }
    }
    return null;
  }

  String? _findWalletdBinary() {
    if (_walletdBin != null && File(_walletdBin!).existsSync()) return _walletdBin;
    final exe = File(Platform.resolvedExecutable);
    final candidates = [
      '${exe.parent.path}/fuego_walletd',
      if (Platform.isMacOS) '${exe.parent.parent.parent.path}/Resources/bin/fuego_walletd',
      // Prefer release over debug for correct --local / port defaults.
      '${Directory.current.path}/rust-fuego-wallet/target/release/fuego_walletd',
      '${Directory.current.path}/rust-fuego-wallet/target/debug/fuego_walletd',
      '${Directory.current.path}/fuego-suite/build/src/walletd',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) {
        _walletdBin = path;
        return path;
      }
    }
    return null;
  }

  String? _findSwapdBinary() {
    if (_swapdBin != null && File(_swapdBin!).existsSync()) return _swapdBin;
    final exe = File(Platform.resolvedExecutable);
    final candidates = [
      '${exe.parent.path}/xfg-swapd',
      if (Platform.isMacOS) '${exe.parent.parent.parent.path}/Resources/bin/xfg-swapd',
      '${Directory.current.path}/xfgo/swapxfg/xfg-swapd',
      '${Directory.current.path}/xfgo/build/release/bin/xfg-swapd',
      '${Directory.current.path}/build/release/src/xfg-swapd',
      '${Directory.current.path}/xfg-swapd',
      '${Directory.current.path}/fuego-suite/build/src/xfg-swapd',
      '${Directory.current.path}/fuego-suite/build/release/src/xfg-swapd',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) {
        _swapdBin = path;
        return path;
      }
    }
    return null;
  }

  /// True when binary is the Go swapxfg headless control API (not C++ --service).
  bool _isGoSwapd(String binary) {
    final name = p.basename(binary).toLowerCase();
    if (name == 'swapxfg') return true;
    // Built Go binary is often named xfg-swapd but rejects --service.
    return binary.contains('${p.separator}swapxfg${p.separator}');
  }

  // ── Health checks ────────────────────────────────────────────────

  Future<bool> _checkHealth(String url, {Duration timeout = const Duration(seconds: 3)}) async {
    final result = await _checkHealthDetailed(url, timeout: timeout);
    return result.ok;
  }

  Future<_HealthResult> _checkHealthDetailed(String url, {Duration timeout = const Duration(seconds: 3)}) async {
    try {
      final client = HttpClient()..connectionTimeout = timeout;
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close().timeout(timeout);
      await resp.drain<void>();
      client.close(force: true);
      if (resp.statusCode == 200) return _HealthResult.ok();
      return _HealthResult.error('HTTP ${resp.statusCode}');
    } on SocketException catch (e) {
      if (e.osError?.errorCode == 61 || e.message.contains('Connection refused')) {
        return _HealthResult.error('Connection refused');
      }
      if (e.osError?.errorCode == 60 || e.message.contains('ETIMEDOUT') || e.message.contains('timed out')) {
        return _HealthResult.error('Connection timed out');
      }
      return _HealthResult.error(e.message.length > 80 ? '${e.message.substring(0, 77)}...' : e.message);
    } on TimeoutException {
      return _HealthResult.error('Connection timed out');
    } catch (e) {
      final msg = e.toString();
      return _HealthResult.error(msg.length > 80 ? '${msg.substring(0, 77)}...' : msg);
    }
  }

  Future<void> _updateStatus() async {
    final walletdHealth = await _checkHealthDetailed(
      'http://127.0.0.1:$walletdPort/health',
    );
    // Prefer /health; some builds only expose JSON-RPC.
    final walletdOk = walletdHealth.ok ||
        (await _checkHealthDetailed(
          'http://127.0.0.1:$walletdPort/json_rpc',
        ))
            .ok;

    final fuegodHealth = await _checkHealthDetailed(
      'http://127.0.0.1:$fuegodPort/getinfo',
    );
    final swapdHealth = await _checkHealthDetailed(
      'http://127.0.0.1:$swapdPort/health',
    );

    final fuegodOk = fuegodHealth.ok;
    final swapdOk = swapdHealth.ok;

    // Proxy (walletd/unified) is the critical process. Embedded fuegod is
    // managed by --local and may not expose 18180 until fully synced.
    final proxyAlive = _unified != null || _walletd != null || _walletdExternallyRunning;
    final proxyHealthy = proxyAlive && walletdOk;

    // Local mode: the chain IS the embedded fuegod — it must answer on the
    // fuegod port. Remote mode: chain is the seed node, walletd healthy is
    // enough.
    final chainOk = _useLocalNode ? fuegodOk : true;

    status.value = DaemonStatus(
      fuegodRunning: (_fuegod != null && fuegodOk) ||
          (_unified != null && proxyHealthy) ||
          (_walletd != null && proxyHealthy && chainOk) ||
          (_walletdExternallyRunning && fuegodOk) ||
          _fuegodExternallyRunning,
      walletdRunning: proxyHealthy || _walletdExternallyRunning,
      swapdRunning: (_swapd != null || _unified != null || _swapdExternallyRunning) && swapdOk,
      fuegodError: daemonErrors['fuegod'] ??
          ((_fuegod != null || (_useLocalNode && _walletd != null)) && !fuegodOk
              ? fuegodHealth.error
              : null),
      walletdError: daemonErrors['walletd'] ??
          (proxyAlive && !walletdOk ? walletdHealth.error : null),
      swapdError: daemonErrors['swapd'] ??
          ((_swapd != null || _swapdExternallyRunning) && !swapdOk ? swapdHealth.error : null),
    );
  }

  // ── Start all daemons ────────────────────────────────────────────

  /// Start backend daemons.
  ///
  /// **Local mode** (`useLocalNode: true`):
  ///   fuego_walletd serve --local  (embeds/spawns fuegod itself)
  ///
  /// **Remote mode** (`useLocalNode: false`):
  ///   fuego_walletd serve --daemon-host [daemonHost] --daemon-port [daemonPort]
  ///   Does NOT start a local fuegod — the proxy talks to the remote seed node.
  ///
  /// Swap daemon:
  /// - Go headless (`xfgo/swapxfg/xfg-swapd --headless`) when that binary is found
  /// - else C++ style `--swap-config … --service` when [swapConfigPath] is set
  ///
  /// Returns error message if the wallet proxy fails, null on success.
  Future<String?> startAll({
    bool useLocalNode = true,
    bool useTestnet = false,
    String? swapConfigPath,
    String daemonHost = '127.0.0.1',
    int daemonPort = 18180,
    bool startSwapd = true,
  }) async {
    errors.clear();
    daemonErrors.clear();
    _lastStartError = null;
    _walletdExternallyRunning = false;
    _fuegodExternallyRunning = false;
    _swapdExternallyRunning = false;
    _useLocalNode = useLocalNode;
    debugPrint('[daemon] === Starting daemons ===');
    debugPrint('[daemon] Mode: ${useLocalNode ? "LOCAL" : "REMOTE"}');
    debugPrint('[daemon] Chain target: $daemonHost:$daemonPort');
    debugPrint('[daemon] Testnet: $useTestnet');
    await _updateStatus();

    String? walletdErr;
    String? swapdErr;

    // ── 0. Try unified daemon first (desktop bundles) ──
    final unifiedBin = _findUnifiedBinary();
    if (unifiedBin != null) {
      debugPrint('[daemon] Found unified daemon: $unifiedBin');
      try {
        walletdErr = await _startUnified(
          unifiedBin,
          useLocalNode: useLocalNode,
          useTestnet: useTestnet,
          daemonHost: daemonHost,
          daemonPort: daemonPort,
        );
      } catch (e) {
        walletdErr = e.toString();
        debugPrint('[daemon] Unified daemon crashed: $e');
      }
      if (walletdErr == null) {
        debugPrint('[daemon] Unified daemon started OK on port $walletdPort');
      } else {
        debugPrint('[daemon] Unified daemon failed ($walletdErr), falling back...');
      }
    } else {
      debugPrint('[daemon] Unified daemon binary not found — using fuego_walletd');
    }

    // ── 1. Never spawn a separate fuegod here ──
    // Local:  fuego_walletd --local owns embedded fuegod.
    // Remote: chain is the remote seed node — local fuegod would fight ports
    //         and break the remote path (this was the inverted-logic bug).

    // ── 2. fuego_walletd (wallet JSON-RPC proxy — required) ──
    if (walletdErr != null || unifiedBin == null) {
      walletdErr = await _startWalletd(
        useLocalNode: useLocalNode,
        useTestnet: useTestnet,
        daemonHost: useLocalNode ? '127.0.0.1' : daemonHost,
        daemonPort: useLocalNode ? fuegodPort : daemonPort,
      );
      if (walletdErr != null) {
        errors.add('fuego_walletd: $walletdErr');
        daemonErrors['walletd'] = walletdErr;
        _lastStartError = 'walletd: $walletdErr';
      }
    }

    // ── 3. xfg-swapd (required for full stack; soft-fail with error recorded) ──
    if (startSwapd) {
      final chainHost = useLocalNode ? '127.0.0.1' : daemonHost;
      final chainPort = useLocalNode ? fuegodPort : daemonPort;
      swapdErr = await _startSwapd(
        configPath: swapConfigPath,
        chainHost: chainHost,
        chainPort: chainPort,
        walletPort: walletdPort,
        useTestnet: useTestnet,
      );
      if (swapdErr != null) {
        errors.add('xfg-swapd: $swapdErr');
        daemonErrors['swapd'] = swapdErr;
        debugPrint('[daemon] xfg-swapd failed (non-fatal): $swapdErr');
      }
    }

    await _updateStatus();

    // Always start event bus so externally-started daemons are detected
    eventBus.start(
      fuegodPort: useLocalNode ? fuegodPort : daemonPort,
      walletdPort: walletdPort,
      swapdPort: swapdPort,
      fuegodHost: useLocalNode ? '127.0.0.1' : daemonHost,
    );

    return walletdErr;
  }

  Future<String?> _startFuegod({bool useTestnet = false}) async {
    // Detect externally-started fuegod
    final alreadyRunning = await _checkHealth(
      'http://127.0.0.1:$fuegodPort/getinfo',
      timeout: const Duration(seconds: 2),
    );
    if (alreadyRunning) {
      _fuegodExternallyRunning = true;
      debugPrint('[daemon] fuegod already running on port $fuegodPort');
      return null;
    }

    final binary = _findFuegodBinary();
    if (binary == null) return 'fuegod binary not found';

    // Kill stale process on port
    final portErr = await _freePort(fuegodPort);
    if (portErr != null) return portErr;

    final dataDir = '${Directory.current.path}/fuegod_data';
    await Directory(dataDir).create(recursive: true);

    final args = [
      '--data-dir', dataDir,
      '--rpc-bind-port', fuegodPort.toString(),
      '--rpc-bind-ip', '127.0.0.1',
      '--log-level', '1',
      // Headless: no TTY on stdin when spawned from the GUI.
      '--no-console',
    ];
    if (useTestnet) args.add('--testnet');

    try {
      debugPrint('[daemon] Starting fuegod: $binary');
      _fuegod = await Process.start(binary, args);
      _fuegod!.stdout.drain<void>();
      _fuegod!.stderr.drain<void>();
      _fuegod!.exitCode.then((code) {
        debugPrint('[daemon] fuegod exited with code $code');
        _fuegod = null;
      });
    } catch (e) {
      return 'Failed to spawn: $e';
    }

    // Wait for ready
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (await _checkHealth('http://127.0.0.1:$fuegodPort/getinfo', timeout: const Duration(seconds: 2))) {
        debugPrint('[daemon] fuegod ready on port $fuegodPort');
        return null;
      }
    }
    return 'fuegod not ready after 60s';
  }

  Future<String?> _startWalletd({
    bool useLocalNode = true,
    bool useTestnet = false,
    String daemonHost = '127.0.0.1',
    int daemonPort = 18180,
  }) async {
    final binary = _findWalletdBinary();
    if (binary == null) {
      return 'fuego_walletd binary not found '
          '(searched app bundle + rust-fuego-wallet/target/{release,debug})';
    }

    // Detect externally-started walletd
    final alreadyRunning = await _probeJsonRpcReady(walletdPort) ||
        await _checkHealth('http://127.0.0.1:$walletdPort/health', timeout: const Duration(seconds: 2));
    if (alreadyRunning) {
      // In local mode the walletd must be running with an embedded fuegod.
      // A stale walletd from a previous app instance (older binary, remote
      // args, or a dead embedded daemon) answers /health with fuego:false
      // and leaves the chain port 18180 dead — killing the whole stack
      // (swapd, mining, balances). Verify the embedded daemon before reuse.
      if (useLocalNode && !await _walletdEmbeddedFuegodOk(walletdPort)) {
        debugPrint('[daemon] walletd on $walletdPort is stale '
            '(embedded fuegod offline) — killing and restarting');
        final killErr = await _freePort(walletdPort);
        if (killErr != null) return killErr;
      } else {
        _walletdExternallyRunning = true;
        debugPrint('[daemon] fuego_walletd already running on port $walletdPort');
        return null;
      }
    }

    final portErr = await _freePort(walletdPort);
    if (portErr != null) return portErr;

    // In local mode the Rust backend spawns fuegod on daemonPort (18180).
    // A stale fuegod from a previous app instance would otherwise block it
    // or get silently reused with stale data.
    if (useLocalNode) {
      final chainPortErr = await _freePort(daemonPort);
      if (chainPortErr != null) return chainPortErr;
    }

    // clap: -P/--port global, then serve subcommand flags
    final args = <String>[
      '-P', walletdPort.toString(),
      'serve',
      '--daemon-host', daemonHost,
      '--daemon-port', daemonPort.toString(),
    ];
    if (useTestnet) args.add('--testnet');
    if (useLocalNode) args.add('--local');

    try {
      debugPrint('[daemon] Starting fuego_walletd: $binary ${args.join(' ')}');
      _walletd = await Process.start(binary, args);
      if (kDebugMode) {
        _walletd!.stdout
            .transform<String>(utf8.decoder)
            .listen((l) => debugPrint('[walletd:out] $l'));
        _walletd!.stderr
            .transform<String>(utf8.decoder)
            .listen((l) => debugPrint('[walletd:err] $l'));
      } else {
        _walletd!.stdout.drain<void>();
        _walletd!.stderr.drain<void>();
      }
      _walletd!.exitCode.then((code) {
        debugPrint('[daemon] fuego_walletd exited with code $code');
        _walletd = null;
        daemonErrors['walletd'] = 'exited with code $code';
      });
    } catch (e) {
      return 'Failed to spawn: $e';
    }

    // Local --local can take a long time (download/start fuegod + sync).
    // Remote proxy is usually up within a few seconds.
    final maxAttempts = useLocalNode ? 90 : 45;
    for (var i = 0; i < maxAttempts; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));

      // Process died early
      if (_walletd == null) {
        return daemonErrors['walletd'] ?? 'fuego_walletd exited during startup';
      }

      if (await _checkHealth(
        'http://127.0.0.1:$walletdPort/health',
        timeout: const Duration(seconds: 2),
      )) {
        debugPrint('[daemon] fuego_walletd ready on port $walletdPort (health)');
        return null;
      }

      // Some builds only answer on /json_rpc
      if (await _probeJsonRpcReady(walletdPort)) {
        debugPrint('[daemon] fuego_walletd ready on port $walletdPort (json_rpc)');
        return null;
      }

      if (i % 10 == 0) {
        debugPrint('[daemon] waiting for fuego_walletd… attempt ${i + 1}/$maxAttempts');
      }
    }
    return 'fuego_walletd not ready after ${maxAttempts * 2}s';
  }

  /// True when a walletd on [port] reports a healthy embedded fuegod
  /// (`daemon:true` / `fuego:true` in GET /health). False when the health
  /// body is missing the keys or reports the embedded chain offline —
  /// used to detect stale walletd processes in local mode.
  Future<bool> _walletdEmbeddedFuegodOk(int port) async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/health'));
      final resp = await req.close().timeout(const Duration(seconds: 2));
      final body = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      if (resp.statusCode != 200) return false;
      final data = jsonDecode(body);
      if (data is Map<String, dynamic>) {
        final daemon = data['daemon'];
        if (daemon is bool) return daemon;
        final fuego = data['fuego'];
        if (fuego is bool) return fuego;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _probeJsonRpcReady(int port) async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/json_rpc'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'getinfo',
        'params': <String, dynamic>{},
      }));
      final resp = await req.close().timeout(const Duration(seconds: 2));
      await resp.drain<void>();
      client.close(force: true);
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _startUnified(
    String binary, {
    bool useLocalNode = true,
    bool useTestnet = false,
    String daemonHost = '127.0.0.1',
    int daemonPort = 18180,
  }) async {
    debugPrint('[daemon] _startUnified: binary=$binary');

    // Detect externally-started unified daemon
    final alreadyRunning = await _probeJsonRpcReady(walletdPort) ||
        await _checkHealth('http://127.0.0.1:$walletdPort/health', timeout: const Duration(seconds: 2));
    if (alreadyRunning) {
      _walletdExternallyRunning = true;
      _fuegodExternallyRunning = true;
      debugPrint('[daemon] Unified daemon already running on port $walletdPort');
      return null;
    }

    // Kill stale processes on ports the unified daemon binds: wallet proxy
    // (18189), embedded fuegod RPC (18180), and P2P (10808). Leftover
    // daemons from a previous app instance (e.g. a translocated copy of the
    // app) hold these and make the new instance die with "Address already
    // in use" → exit code 1.
    for (final port in [walletdPort, daemonPort, 10808]) {
      final portErr = await _freePort(port);
      if (portErr != null) {
        debugPrint('[daemon] Port $port error: $portErr');
        return portErr;
      }
    }

     // Unified daemon needs --container-file and --container-password
     final security = SecurityService();
     final appDir = await getApplicationSupportDirectory();
     final walletDir = p.join(appDir.path, 'wallet');
     await Directory(walletDir).create(recursive: true);
     final containerFile = p.join(walletDir, 'fuego_wallet');
     String? containerPassword;
     try {
       containerPassword = await security.getOrCreateWalletdPassword();
       debugPrint('[daemon] Got wallet password from Keychain');
     } catch (e) {
       debugPrint('[daemon] Keychain unavailable ($e), starting without container password');
     }

      // Generate container if it doesn't exist yet
      final containerExists = await File(containerFile).exists();
      if (!containerExists) {
        debugPrint('[daemon] Container not found at $containerFile — generating...');
        final genArgs = <String>[
          '--generate-container',
          '--container-file', containerFile,
        ];
        if (containerPassword != null) {
          genArgs.add('--container-password');
          genArgs.add(containerPassword);
        }
        if (useTestnet) genArgs.add('--testnet');
        debugPrint('[daemon] unified generate-container args: $genArgs');
        final genProc = await Process.run(binary, genArgs);
        debugPrint('[daemon] generate-container exit code: ${genProc.exitCode}');
        if (genProc.exitCode != 0) {
          final err = genProc.stderr.toString().trim();
          debugPrint('[daemon] generate-container stderr: $err');
          return 'Failed to generate wallet container: $err';
        }
        debugPrint('[daemon] Wallet container generated at $containerFile');
      }

      final args = <String>[
        '--bind-port', walletdPort.toString(),
        '--container-file', containerFile,
      ];
      if (containerPassword != null) {
        args.add('--container-password');
        args.add(containerPassword);
      }
      if (useLocalNode) {
        args.add('--local');
      } else {
        args.addAll(['--daemon-host', daemonHost, '--daemon-port', daemonPort.toString()]);
      }
      if (useTestnet) args.add('--testnet');

      debugPrint('[daemon] unified args: $args');

    try {
      debugPrint('[daemon] Spawning unified daemon...');
      _unified = await Process.start(binary, args);
      debugPrint('[daemon] unified process started (PID ${_unified!.pid})');
      if (kDebugMode) {
        _unified!.stdout.transform<String>(utf8.decoder).listen((l) => debugPrint('[unified:out] $l'));
        _unified!.stderr.transform<String>(utf8.decoder).listen((l) => debugPrint('[unified:err] $l'));
      } else {
        // Keep a bounded buffer so startup failures surface the real
        // cause (e.g. "Address already in use") instead of just exit code 1.
        final buffer = StringBuffer();
        _unified!.stdout.transform<String>(utf8.decoder).listen((l) {
          if (buffer.length < 8192) buffer.write(l);
        });
        _unified!.stderr.transform<String>(utf8.decoder).listen((l) {
          if (buffer.length < 8192) buffer.write(l);
        });
        _unifiedExitLog = buffer;
      }
      _unified!.exitCode.then((code) {
        debugPrint('[daemon] unified daemon exited with code $code');
        final logTail = _unifiedExitLog?.toString().trim();
        daemonErrors['unified'] = logTail != null && logTail.isNotEmpty
            ? 'exited with code $code — $logTail'
            : 'exited with code $code';
        _unified = null;
        _updateStatus();
      });
    } catch (e) {
      return 'Failed to spawn: $e';
    }

    // Wait for ready — unified daemon exposes /json_rpc with getHealth
    // Blockchain rescan + wallet scan can take up to ~150s on mainnet
    debugPrint('[daemon] Waiting for unified daemon on port $walletdPort...');
    for (var i = 0; i < 90; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));

      // Process died — don't keep polling a corpse for 180s.
      if (_unified == null) {
        debugPrint('[daemon] unified daemon exited during startup');
        return daemonErrors['unified'] ?? 'unified daemon exited during startup';
      }

      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
        final req = await client.getUrl(
            Uri.parse('http://127.0.0.1:$walletdPort/health'));
        final resp = await req.close().timeout(const Duration(seconds: 2));
        await resp.drain<void>();
        client.close(force: true);
        if (resp.statusCode == 200) {
          debugPrint('[daemon] unified daemon healthy on port $walletdPort (attempt ${i + 1})');
          return null;
        } else {
          debugPrint('[daemon] health check attempt ${i + 1}: HTTP ${resp.statusCode}');
        }
      } catch (e) {
        if (i % 10 == 0) {
          debugPrint('[daemon] health check attempt ${i + 1}: $e');
        }
      }
    }
    debugPrint('[daemon] unified daemon not ready after 180s');
    return 'unified daemon not ready after 180s';
  }

  Future<String?> _startSwapd({
    String? configPath,
    String chainHost = '127.0.0.1',
    int chainPort = 18180,
    int walletPort = 18189,
    bool useTestnet = false,
  }) async {
    // Detect externally-started swapd
    final alreadyRunning = await _probeJsonRpcReady(swapdPort) ||
        await _checkHealth('http://127.0.0.1:$swapdPort/health', timeout: const Duration(seconds: 2));
    if (alreadyRunning) {
      _swapdExternallyRunning = true;
      debugPrint('[daemon] xfg-swapd already running on port $swapdPort');
      return null;
    }

    final binary = _findSwapdBinary();
    if (binary == null) return 'xfg-swapd binary not found';

    final portErr = await _freePort(swapdPort);
    if (portErr != null) return portErr;

    final List<String> args;
    final goHeadless = _isGoSwapd(binary);
    if (goHeadless) {
      // Go swapxfg headless control API (--headless-port, default probe 18902)
      args = [
        '--headless',
        '--headless-port',
        swapdPort.toString(),
        '--daemon',
        'http://$chainHost:$chainPort',
        '--wallet',
        'http://127.0.0.1:$walletPort',
        '--no-bridge',
        '--no-bch',
      ];
      // Do not pass bare --testnet: it overrides --daemon/--wallet to hard-coded ports.
    } else if (configPath != null && File(configPath).existsSync()) {
      args = ['--swap-config', configPath, '--service'];
    } else {
      return 'xfg-swapd needs Go headless binary (xfgo/swapxfg/xfg-swapd) '
          'or a C++ --swap-config file';
    }

    try {
      debugPrint('[daemon] Starting xfg-swapd: $binary ${args.join(' ')}');
      _swapd = await Process.start(binary, args);
      if (kDebugMode) {
        _swapd!.stdout
            .transform<String>(utf8.decoder)
            .listen((l) => debugPrint('[swapd:out] $l'));
        _swapd!.stderr
            .transform<String>(utf8.decoder)
            .listen((l) => debugPrint('[swapd:err] $l'));
      } else {
        _swapd!.stdout.drain<void>();
        _swapd!.stderr.drain<void>();
      }
      _swapd!.exitCode.then((code) {
        debugPrint('[daemon] xfg-swapd exited with code $code');
        _swapd = null;
        // Crash-only auto-restart: the swap daemon occasionally dies when a
        // dependency (wallet proxy) bounces mid-handshake. Intentional stops
        // set [_stopping] and never respawn here.
        if (!_stopping && code != 0) {
          Future<void>.delayed(const Duration(seconds: 3), () async {
            if (_stopping || _swapd != null || !anyRunning) return;
            debugPrint('[daemon] restarting xfg-swapd after crash');
            final binary = _findSwapdBinary();
            if (binary == null) return;
            try {
              final goHeadless = _isGoSwapd(binary);
              final args = goHeadless
                  ? [
                      '--headless',
                      '--headless-port', swapdPort.toString(),
                      '--daemon', 'http://127.0.0.1:$fuegodPort',
                      '--wallet', 'http://127.0.0.1:$walletdPort',
                      '--no-bridge',
                      '--no-bch',
                    ]
                  : <String>['--service'];
              _swapd = await Process.start(binary, args);
              _swapd!.stdout.drain<void>();
              _swapd!.stderr.drain<void>();
              _swapd!.exitCode.then((c) {
                debugPrint('[daemon] xfg-swapd exited with code $c');
                _swapd = null;
              });
            } catch (e) {
              debugPrint('[daemon] xfg-swapd restart failed: $e');
            }
          });
        }
      });
    } catch (e) {
      return 'Failed to spawn: $e';
    }

    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (_swapd == null) {
        return daemonErrors['swapd'] ?? 'xfg-swapd exited during startup';
      }
      // Prefer /health; Go headless also serves /status
      if (await _checkHealth(
            'http://127.0.0.1:$swapdPort/health',
            timeout: const Duration(seconds: 2),
          ) ||
          await _checkHealth(
            'http://127.0.0.1:$swapdPort/status',
            timeout: const Duration(seconds: 2),
          )) {
        debugPrint('[daemon] xfg-swapd ready on port $swapdPort');
        return null;
      }
    }
    return 'xfg-swapd not ready after 20s';
  }

  // ── Stop all daemons ─────────────────────────────────────────────

  Future<void> stopAll() async {
    _stopping = true;
    eventBus.stop();
    await _stopProcess(_unified, 'unified');
    _unified = null;
    await _stopProcess(_swapd, 'xfg-swapd');
    _swapd = null;
    await _stopProcess(_walletd, 'fuego_walletd');
    _walletd = null;
    await _stopProcess(_fuegod, 'fuegod');
    _fuegod = null;
    _stopping = false;
    _updateStatus();
  }

  Future<void> stopSwapd() async {
    _stopping = true;
    await _stopProcess(_swapd, 'xfg-swapd');
    _swapd = null;
    _stopping = false;
    _updateStatus();
  }

  Future<void> _stopProcess(Process? process, String name) async {
    if (process == null) return;
    try {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (_) {}
    debugPrint('[daemon] $name stopped');
  }

  // ── Convenience getters ──────────────────────────────────────────

  bool get unifiedRunning => _unified != null;
  bool get fuegodRunning =>
      _unified != null ||
      _fuegod != null ||
      (_walletd != null && status.value.fuegodRunning) ||
      _fuegodExternallyRunning;
  /// True when the local wallet proxy process handle is alive.
  bool get walletdRunning =>
      _unified != null || _walletd != null || _walletdExternallyRunning;
  bool get swapdRunning =>
      _unified != null || _swapd != null || _swapdExternallyRunning;

  bool get allRunning => walletdRunning;
  bool get anyRunning =>
      _unified != null || _walletd != null || _fuegod != null || _swapd != null ||
      _walletdExternallyRunning || _fuegodExternallyRunning || _swapdExternallyRunning;
}

/// Snapshot of daemon health status.
class DaemonStatus {
  final bool fuegodRunning;
  final bool walletdRunning;
  final bool swapdRunning;
  final String? fuegodError;
  final String? walletdError;
  final String? swapdError;

  const DaemonStatus({
    this.fuegodRunning = false,
    this.walletdRunning = false,
    this.swapdRunning = false,
    this.fuegodError,
    this.walletdError,
    this.swapdError,
  });

  bool get hasErrors => fuegodError != null || walletdError != null || swapdError != null;
  bool get allHealthy => fuegodRunning && walletdRunning && swapdRunning;

  /// Human-readable status summary for UI display.
  String get displayText {
    final parts = <String>[];
    if (!fuegodRunning) parts.add('Node: ${fuegodError ?? "offline"}');
    if (!walletdRunning) parts.add('Wallet: ${walletdError ?? "offline"}');
    if (!swapdRunning) parts.add('Swap: ${swapdError ?? "offline"}');
    return parts.join(' \u2022 ');
  }

  String? get summary {
    final running = [if (fuegodRunning) 'fuegod', if (walletdRunning) 'walletd', if (swapdRunning) 'swapd'];
    final stopped = [if (!fuegodRunning) 'fuegod', if (!walletdRunning) 'walletd', if (!swapdRunning) 'swapd'];
    if (running.isEmpty) return 'All daemons stopped';
    if (stopped.isEmpty) return 'All daemons running';
    return '${running.join(", ")} running, ${stopped.join(", ")} stopped';
  }
}

class _HealthResult {
  final bool ok;
  final String? error;
  _HealthResult.ok() : ok = true, error = null;
  _HealthResult.error(this.error) : ok = false;
}
