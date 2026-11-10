import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:solana/base58.dart' as solana_base58;

import '../models/chain_registry.g.dart';
import 'evm_account_service.dart';
import 'swap_daemon_client.dart';

/// Manages xfg-swapd configuration and process lifecycle.
class SwapConfigService {
  static final Set<String> _evmSwapChains = kChains
      .where((chain) => chain.family == 'evm' && chain.tier == 'swap')
      .map((chain) => chain.key)
      .toSet();

  Process? _swapDaemon;
  String? _configPath;
  String? _swapdPath;
  Map<String, SwapChainConfig>? _lastChains;
  String? _lastNetwork;
  String? _lastXfgSecret;
  String? _runtimeConfigPath;

  Future<String> _dataDir() async {
    final dir = await getApplicationSupportDirectory();
    return dir.path;
  }

  Future<String> configPath() async {
    if (_configPath != null) return _configPath!;
    final dir = await _dataDir();
    _configPath = '$dir/swap_config.json';
    return _configPath!;
  }

  String configPathSync() {
    if (_configPath != null) return _configPath!;
    // Deliberately not system temp: this file holds chain private keys and
    // the XFG spend key. World-readable temp dirs are unacceptable.
    final dir = Directory(Platform.resolvedExecutable).parent.path;
    _configPath = '$dir/swap_config.json';
    return _configPath!;
  }

  String? findSwapdBinary() {
    if (_swapdPath != null && File(_swapdPath!).existsSync()) return _swapdPath;

    final exe = File(Platform.resolvedExecutable);
    final candidates = [
      '${exe.parent.path}/xfg-swapd',
      if (Platform.isMacOS)
        '${exe.parent.parent.parent.path}/Resources/bin/xfg-swapd',
      '${Directory.current.path}/build/release/src/xfg-swapd',
      '${Directory.current.path}/xfg-swapd',
    ];

    for (final path in candidates) {
      if (File(path).existsSync()) {
        _swapdPath = path;
        return path;
      }
    }
    return null;
  }

  static Future<String> controlTokenPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/xfg-swapd.rpc-token';
  }

  static Future<void> _requireOwnerOnly(File file) async {
    if (kIsWeb || Platform.isWindows) {
      throw UnsupportedError(
        'xfg-swapd credentials require a verified owner-only filesystem',
      );
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('xfg-swapd credential path must be a regular file');
    }
    final metadata = await file.stat();
    if (metadata.type != FileSystemEntityType.file ||
        (metadata.mode & 0x1ff) != 0x180) {
      throw StateError('xfg-swapd credential file must be owner-only');
    }
  }

  static Future<void> _setOwnerOnly(File file) async {
    final result = await Process.run('chmod', ['600', file.path]);
    if (result.exitCode != 0) {
      throw StateError('could not set xfg-swapd credential permissions');
    }
    await _requireOwnerOnly(file);
  }

  static Future<void> _writeOwnerOnlyFile(
    String destination,
    String contents,
  ) async {
    if (kIsWeb || Platform.isWindows) {
      throw UnsupportedError(
        'xfg-swapd credentials require a verified owner-only filesystem',
      );
    }
    final directory = File(destination).parent;
    await directory.create(recursive: true);
    final random = Random.secure();
    File? temporary;
    for (var attempt = 0; attempt < 8; attempt++) {
      final suffix = random.nextInt(1 << 32).toRadixString(16);
      final candidate = File('$destination.tmp.$suffix');
      try {
        await candidate.create(exclusive: true);
        temporary = candidate;
        break;
      } on FileSystemException {
        continue;
      }
    }
    if (temporary == null) {
      throw StateError('could not create xfg-swapd credential file');
    }

    var renamed = false;
    try {
      await _setOwnerOnly(temporary);
      await temporary.writeAsString(contents, flush: true);
      await _setOwnerOnly(temporary);
      await temporary.rename(destination);
      renamed = true;
      await _requireOwnerOnly(File(destination));
    } catch (_) {
      if (!renamed && await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    }
  }

  static Future<void> _createOwnerOnlyFile(
    String destination,
    String contents,
  ) async {
    if (kIsWeb || Platform.isWindows) {
      throw UnsupportedError(
        'xfg-swapd credentials require a verified owner-only filesystem',
      );
    }
    final file = File(destination);
    await file.parent.create(recursive: true);
    await file.create(exclusive: true);
    await _setOwnerOnly(file);
    await file.writeAsString(contents, flush: true);
    await _requireOwnerOnly(file);
  }

  static String _newControlToken() {
    final random = Random.secure();
    return List<String>.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static Future<String> readControlToken() async {
    final path = await controlTokenPath();
    final file = File(path);
    await _requireOwnerOnly(file);
    return SwapDaemonClient.validateControlToken(await file.readAsString());
  }

  static Future<String> ensureControlTokenFile() async {
    final path = await controlTokenPath();
    final file = File(path);
    if (await file.exists()) {
      await _requireOwnerOnly(file);
      SwapDaemonClient.validateControlToken(await file.readAsString());
      return path;
    }
    try {
      await _createOwnerOnlyFile(path, _newControlToken());
    } on FileSystemException {
      await _requireOwnerOnly(file);
      SwapDaemonClient.validateControlToken(await file.readAsString());
    }
    return path;
  }

  Future<String> generateConfig({
    required Map<String, SwapChainConfig> chains,
    required String network,
    String? xfgSecretKey,
  }) async {
    _lastChains = chains;
    _lastNetwork = network;
    _lastXfgSecret = xfgSecretKey;
    final config = stripSecrets(buildConfig(
      chains: chains,
      network: network,
      xfgSecretKey: xfgSecretKey,
    ));
    final path = await configPath();
    await _writeOwnerOnlyFile(
      path,
      const JsonEncoder.withIndent('  ').convert(config),
    );
    return path;
  }

  /// Full config for a single launch. Owner-only, not the persisted file.
  /// Caller deletes it after xfg-swapd has read it.
  Future<String> writeRuntimeConfig({
    required Map<String, SwapChainConfig> chains,
    required String network,
    String? xfgSecretKey,
  }) async {
    final config = buildConfig(
      chains: chains,
      network: network,
      xfgSecretKey: xfgSecretKey,
    );
    final dir = await _dataDir();
    final path = '$dir/swap_config.runtime.json';
    // Drop any residue from a prior crash before writing a new runtime file.
    try { await File(path).delete(); } catch (_) {}
    await _writeOwnerOnlyFile(
      path,
      const JsonEncoder.withIndent('  ').convert(config),
    );
    return path;
  }

  static const _secretKeys = {
    'private_key',
    'sol_keypair',
    'xfg_secret_key',
    'xmr_spend_key',
    'xmr_view_key',
  };

  static bool _isSecretKey(String key) =>
      _secretKeys.contains(key) || key.endsWith('_wif');

  /// Remove raw private keys. Addresses, RPCs, registries, and modes stay.
  static Map<String, dynamic> stripSecrets(Map<String, dynamic> config) {
    final out = <String, dynamic>{};
    for (final entry in config.entries) {
      if (_isSecretKey(entry.key)) continue;
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        out[entry.key] = stripSecrets(value);
      } else if (value is Map) {
        out[entry.key] = stripSecrets(Map<String, dynamic>.from(value));
      } else {
        out[entry.key] = value;
      }
    }
    return out;
  }

  static Map<String, dynamic> buildConfig({
    required Map<String, SwapChainConfig> chains,
    required String network,
    String? xfgSecretKey,
  }) {
    if (network != 'mainnet' && network != 'testnet') {
      throw ArgumentError.value(
        network,
        'network',
        'must be mainnet or testnet',
      );
    }
    final config = <String, dynamic>{'network': network};
    final evmChains = <String, dynamic>{};

    for (final entry in chains.entries) {
      final chain = entry.key.toLowerCase();
      final cfg = entry.value;
      final credential = cfg.wif.trim();
      if (credential.isEmpty) continue;

      if (_evmSwapChains.contains(chain)) {
        final rpcUrl = cfg.rpcUrl?.trim() ?? '';
        final registry = cfg.htlcRegistry?.trim() ?? '';
        final ptlcRegistry = cfg.ptlcRegistry?.trim() ?? '';
        final chainId = cfg.chainId;
        final uri = Uri.tryParse(rpcUrl);
        if (uri == null ||
            uri.host.isEmpty ||
            (uri.scheme != 'http' && uri.scheme != 'https')) {
          throw ArgumentError('$chain requires an HTTP(S) RPC URL');
        }
        if (chainId == null || chainId <= 0) {
          throw ArgumentError('$chain requires an explicit chain ID');
        }
        if (network == 'mainnet' && chainId != kChainIds[chain]) {
          throw ArgumentError(
            '$chain chain ID does not match the mainnet catalog',
          );
        }
        if (!_isEvmAddress(registry)) {
          throw ArgumentError(
            '$chain requires a deployed HTLC registry address',
          );
        }
        if (ptlcRegistry.isNotEmpty && !_isEvmAddress(ptlcRegistry)) {
          throw ArgumentError('$chain PTLC registry address is invalid');
        }
        final privateKey = EvmAccountService.normalizePrivateKey(credential);
        evmChains[chain] = <String, dynamic>{
          'rpc_url': rpcUrl,
          'private_key': privateKey,
          'address': EvmAccountService.deriveAddress(privateKey),
          'htlc_registry': registry,
          if (ptlcRegistry.isNotEmpty) 'ptlc_registry': ptlcRegistry,
          'chain_id': chainId,
        };
        continue;
      }

      if (network == 'testnet') {
        throw ArgumentError(
          '$chain is not executable on testnet; configure a supported EVM deployment instead',
        );
      }

      if (chain == 'xmr') {
        final daemonHost = cfg.xmrDaemonHost?.trim() ?? '';
        final walletHost = cfg.xmrWalletHost?.trim() ?? '';
        final viewKey = cfg.xmrViewKey?.trim() ?? '';
        if (daemonHost.isEmpty || walletHost.isEmpty) {
          throw ArgumentError('XMR requires daemon and wallet RPC hosts');
        }
        if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(credential) ||
            !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(viewKey)) {
          throw ArgumentError('XMR requires 64-character spend and view keys');
        }
        config['xmr_daemon_host'] = daemonHost;
        config['xmr_wallet_host'] = walletHost;
        config['xmr_spend_key'] = credential;
        config['xmr_view_key'] = viewKey;
        continue;
      }

      if (chain == 'sol') {
        final rpcUrl = cfg.rpcUrl?.trim() ?? '';
        final programId = cfg.solProgramId?.trim() ?? '';
        final uri = Uri.tryParse(rpcUrl);
        if (uri == null ||
            uri.host.isEmpty ||
            uri.scheme != 'http' ||
            !isLocalSolanaRpcHost(uri.host)) {
          throw ArgumentError('SOL requires a local HTTP RPC at 127.0.0.1');
        }
        if (!_isSolanaBase58(programId, 32)) {
          throw ArgumentError('SOL requires a 32-byte base58 program ID');
        }
        if (!_isSolanaBase58(credential, 64)) {
          throw ArgumentError('SOL requires a 64-byte base58 keypair');
        }
        config['sol_rpc_host'] = uri.host;
        config['sol_rpc_port'] = uri.hasPort ? uri.port : 80;
        config['sol_program_id'] = programId;
        config['sol_keypair'] = credential;
        continue;
      }

      config['${chain}_mode'] = 'spv';
      config['${chain}_wif'] = credential;
      for (var index = 0; index < cfg.servers.length && index < 16; index++) {
        config['${chain}_spv_server_$index'] = cfg.servers[index];
      }
      if (cfg.minServers != null) {
        config['${chain}_spv_min_servers'] = cfg.minServers!;
      }
      if (cfg.checkpointHeight != null && cfg.checkpointHeight! > 0) {
        config['${chain}_spv_checkpoint_height'] = cfg.checkpointHeight!;
      }
      if (cfg.checkpointHash != null && cfg.checkpointHash!.isNotEmpty) {
        config['${chain}_spv_checkpoint_hash'] = cfg.checkpointHash!;
      }
    }

    if (evmChains.isNotEmpty) config['evm_chains'] = evmChains;
    if (xfgSecretKey != null && xfgSecretKey.isNotEmpty) {
      if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(xfgSecretKey)) {
        throw ArgumentError('XFG secret key must be 64 hexadecimal characters');
      }
      config['xfg_secret_key'] = xfgSecretKey;
    }
    return config;
  }

  static bool _isEvmAddress(String value) =>
      RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(value);

  static bool isLocalSolanaRpcHost(String host) => host == '127.0.0.1';

  static bool _isSolanaBase58(String value, int expectedLength) {
    if (!RegExp(r'^[1-9A-HJ-NP-Za-km-z]+$').hasMatch(value)) return false;
    try {
      return solana_base58.base58decode(value).length == expectedLength;
    } on FormatException {
      return false;
    }
  }

  static String? validateWif(String wif, String chain) {
    if (wif.isEmpty) return 'WIF is required';
    if (wif.length == 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(wif))
      return null;
    if (wif.length < 50 || wif.length > 60) return 'Invalid WIF length';
    if (!RegExp(
      r'^[123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz]+$',
    ).hasMatch(wif)) {
      return 'WIF contains invalid Base58 characters';
    }
    switch (chain.toLowerCase()) {
      case 'btc':
      case 'bch':
        if (!wif.startsWith('5') &&
            !wif.startsWith('K') &&
            !wif.startsWith('L'))
          return 'Must start with 5, K, or L';
        break;
      case 'ltc':
        if (!wif.startsWith('6') && !wif.startsWith('T'))
          return 'Must start with 6 or T';
        break;
      case 'kmd':
        if (!wif.startsWith('7') && !wif.startsWith('U'))
          return 'Must start with 7 or U';
        break;
    }
    return null;
  }

  Future<bool> startDaemon({
    String? configPath,
    Map<String, SwapChainConfig>? chains,
    String? network,
    String? xfgSecretKey,
    bool testnet = false,
  }) async {
    final binary = findSwapdBinary();
    if (binary == null) return false;
    String? runtimePath;
    final String cfgPath;
    final launchChains = chains ?? _lastChains;
    final launchNetwork = network ?? _lastNetwork;
    final launchXfg = xfgSecretKey ?? _lastXfgSecret;
    if (launchChains != null && launchNetwork != null) {
      runtimePath = await writeRuntimeConfig(
        chains: launchChains,
        network: launchNetwork,
        xfgSecretKey: launchXfg,
      );
      cfgPath = runtimePath;
    } else {
      cfgPath = configPath ?? await this.configPath();
    }
    if (!File(cfgPath).existsSync()) return false;
    try {
      final tokenPath = await ensureControlTokenFile();
      final arguments = <String>[
        '--swap-config',
        cfgPath,
        '--rpc-token-file',
        tokenPath,
        if (testnet) '--testnet',
        '--service',
      ];
      _swapDaemon = await Process.start(binary, arguments);
      final exitedImmediately = await Future.any<int?>([
        _swapDaemon!.exitCode,
        Future<int?>.delayed(const Duration(milliseconds: 300), () => null),
      ]);
      if (exitedImmediately != null) {
        _swapDaemon = null;
        if (runtimePath != null) {
          try { await File(runtimePath).delete(); } catch (_) {}
        }
        return false;
      }
      _runtimeConfigPath = runtimePath;
      unawaited(_swapDaemon!.stdout.drain<void>());
      unawaited(_swapDaemon!.stderr.drain<void>());
      unawaited(
        _swapDaemon!.exitCode.then((code) {
          debugPrint('[swapd] Exited with code $code');
          _swapDaemon = null;
        }),
      );
      return true;
    } catch (e) {
      debugPrint('[swapd] Failed to start: $e');
      return false;
    }
  }

  Future<void> stopDaemon() async {
    final runtime = _runtimeConfigPath;
    _runtimeConfigPath = null;
    if (runtime != null) {
      try { await File(runtime).delete(); } catch (_) {}
    }
    final p = _swapDaemon;
    _swapDaemon = null;
    if (p == null) return;
    try {
      p.kill(ProcessSignal.sigterm);
      await p.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          p.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (_) {}
  }

  bool get isRunning => _swapDaemon != null && _swapDaemon!.pid > 0;

  static String addressFromWif(String wif, String chain) =>
      '(derive from $chain WIF)';
}

class SwapChainConfig {
  final String wif;
  final List<String> servers;
  final int? minServers;
  final int? checkpointHeight;
  final String? checkpointHash;
  final String? rpcUrl;
  final int? chainId;
  final String? htlcRegistry;
  final String? ptlcRegistry;
  final String? solProgramId;
  final String? xmrDaemonHost;
  final String? xmrWalletHost;
  final String? xmrViewKey;

  const SwapChainConfig({
    required this.wif,
    this.servers = const [],
    this.minServers,
    this.checkpointHeight,
    this.checkpointHash,
    this.rpcUrl,
    this.chainId,
    this.htlcRegistry,
    this.ptlcRegistry,
    this.solProgramId,
    this.xmrDaemonHost,
    this.xmrWalletHost,
    this.xmrViewKey,
  });

  Map<String, dynamic> toJson() => {
    'wif': wif,
    if (servers.isNotEmpty) 'servers': servers,
    if (minServers != null) 'minServers': minServers,
    if (checkpointHeight != null) 'checkpointHeight': checkpointHeight,
    if (checkpointHash != null) 'checkpointHash': checkpointHash,
    if (rpcUrl != null) 'rpcUrl': rpcUrl,
    if (chainId != null) 'chainId': chainId,
    if (htlcRegistry != null) 'htlcRegistry': htlcRegistry,
    if (ptlcRegistry != null) 'ptlcRegistry': ptlcRegistry,
    if (solProgramId != null) 'solProgramId': solProgramId,
    if (xmrDaemonHost != null) 'xmrDaemonHost': xmrDaemonHost,
    if (xmrWalletHost != null) 'xmrWalletHost': xmrWalletHost,
    if (xmrViewKey != null) 'xmrViewKey': xmrViewKey,
  };

  factory SwapChainConfig.fromJson(Map<String, dynamic> j) => SwapChainConfig(
    wif: j['wif'] as String? ?? '',
    servers:
        (j['servers'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
        [],
    minServers: j['minServers'] as int?,
    checkpointHeight: j['checkpointHeight'] as int?,
    checkpointHash: j['checkpointHash'] as String?,
    rpcUrl: j['rpcUrl'] as String?,
    chainId: j['chainId'] as int?,
    htlcRegistry: j['htlcRegistry'] as String?,
    ptlcRegistry: j['ptlcRegistry'] as String?,
    solProgramId: j['solProgramId'] as String?,
    xmrDaemonHost: j['xmrDaemonHost'] as String?,
    xmrWalletHost: j['xmrWalletHost'] as String?,
    xmrViewKey: j['xmrViewKey'] as String?,
  );
}
