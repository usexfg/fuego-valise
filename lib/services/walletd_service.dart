import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'security_service.dart';

class WalletdService {
  Process? _process;
  String? _walletDir;
  String? _walletFile;
  bool _running = false;
  int _walletdPid = 0;
  final SecurityService _security = SecurityService();

  bool get isRunning => _running;
  int get rpcPort => 18189;

  Future<void> start({
    String daemonHost = '207.244.247.64',
    int daemonPort = 18180,
  }) async {
    if (_running) return;

    try {
      _walletDir = await _getWalletDir();
      _walletFile = p.join(_walletDir!, 'fuego_wallet');

      // Copy binary to writable location if needed
      final binary = await _prepareBinary();
      final containerPassword = await _security.getOrCreateWalletdPassword();

      // Generate wallet if it doesn't exist
      if (!await File(_walletFile!).exists()) {
        await _generateWallet(binary, containerPassword);
      }

      // Start walletd
      if (kDebugMode) debugPrint('WalletdService: starting');
      _process = await Process.start(binary, [
        '--daemon-address',
        daemonHost,
        '--daemon-port',
        daemonPort.toString(),
        '--container-file',
        _walletFile!,
        '--container-password',
        containerPassword,
        '--bind-port',
        rpcPort.toString(),
        '--bind-address',
        '127.0.0.1',
        '--log-level',
        '2',
      ]);

      _walletdPid = _process!.pid;
      debugPrint('WalletdService: PID=$_walletdPid');

      _process!.stdout.transform(utf8.decoder).listen((line) {
        debugPrint('[walletd] $line');
      });

      _process!.stderr.transform(utf8.decoder).listen((line) {
        debugPrint('[walletd:err] $line');
      });

      _process!.exitCode.then((code) {
        debugPrint('WalletdService: exited with code $code');
        _running = false;
      });

      _running = true;

      // Wait for RPC to be ready
      await _waitForReady();
      debugPrint('WalletdService: ready on port $rpcPort');
    } catch (e) {
      debugPrint('WalletdService: FAILED to start: $e');
      _running = false;
      rethrow;
    }
  }

  Future<void> stop() async {
    if (_process != null) {
      debugPrint('WalletdService: stopping PID=$_walletdPid');
      _process!.kill(ProcessSignal.sigterm);
      await _process!.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _process!.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      _process = null;
    }
    _running = false;
    debugPrint('WalletdService: stopped');
  }

  Future<String> _prepareBinary() async {
    // Binary lives next to the wallet data in Application Support
    final appDir = await getApplicationSupportDirectory();
    final binDir = Directory(p.join(appDir.path, 'bin'));
    await binDir.create(recursive: true);
    final target = File(p.join(binDir.path, 'walletd'));

    if (!await target.exists()) {
      // Copy from source
      final source = _findSourceBinary();
      if (source == null) throw Exception('walletd source binary not found');
      debugPrint('WalletdService: copying $source -> ${target.path}');
      await File(source).copy(target.path);
    }

    // Ensure executable
    await Process.run('chmod', ['+x', target.path]);
    return target.path;
  }

  String? _findSourceBinary() {
    // Relative to project root (dev mode)
    final devPaths = [
      p.join(Directory.current.path, 'macos', 'bin', 'walletd'),
    ];
    for (final path in devPaths) {
      if (File(path).existsSync()) return path;
    }

    // In app bundle
    try {
      final appDir = Directory.current.path;
      final resources = p.join(
        appDir,
        'macos',
        'Runner',
        'Resources',
        'bin',
        'walletd',
      );
      if (File(resources).existsSync()) return resources;
    } catch (_) {}

    // Try to find via executable path
    try {
      final exe = Platform.resolvedExecutable;
      final appDir = p.dirname(p.dirname(exe));
      final resources = p.join(appDir, 'Resources', 'bin', 'walletd');
      if (File(resources).existsSync()) return resources;
    } catch (_) {}

    return null;
  }

  Future<void> _generateWallet(String binary, String password) async {
    if (kDebugMode) debugPrint('WalletdService: generating wallet container');
    final result = await Process.run(binary, [
      '--generate-container',
      '--container-file',
      _walletFile!,
      '--container-password',
      password,
      '--daemon-address',
      '127.0.0.1',
      '--daemon-port',
      '18180',
    ]);

    if (result.exitCode != 0) {
      throw Exception('Failed to generate wallet container');
    }
  }

  Future<String> _getWalletDir() async {
    final dir = await getApplicationSupportDirectory();
    final walletDir = p.join(dir.path, 'wallet');
    await Directory(walletDir).create(recursive: true);
    return walletDir;
  }

  Future<void> _waitForReady({int maxAttempts = 30}) async {
    for (var i = 0; i < maxAttempts; i++) {
      try {
        final client = HttpClient();
        // Local HTTP only — no TLS cert bypass needed
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:$rpcPort/json_rpc'),
        );
        final resp = await req.close().timeout(const Duration(seconds: 2));
        final body = await resp.transform(utf8.decoder).join();
        client.close(force: true);
        if (resp.statusCode == 200 && body.contains('result')) {
          return;
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 1));
    }
    throw Exception('walletd failed to start within ${maxAttempts}s');
  }
}
