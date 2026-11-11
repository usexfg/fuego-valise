import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A swap configuration whose secrets are named references into xfg-swapd's
/// encrypted keystore (remediation R7): [config] holds "keystore:<name>"
/// strings, [secrets] the values to store under those names.
class SealedSwapConfig {
  final Map<String, dynamic> config;
  final Map<String, String> secrets;

  const SealedSwapConfig(this.config, this.secrets);
}

/// xfg-swapd keeps chain keys, RPC passwords and the XFG swap key in an
/// scrypt + AES-256-GCM keystore; swap_config.json only names them. The
/// passphrase lives in the OS keychain and reaches the daemon through its
/// environment, never on disk.
class SwapKeystore {
  static const String referencePrefix = 'keystore:';
  static const String passphraseEnvironment = 'XFG_SWAPD_KEYSTORE_PASSPHRASE';
  static const String _passphraseStorageKey = 'xfg_swapd_keystore_passphrase';
  static const int _passphraseBytes = 32;

  static const Set<String> _secretFields = {
    'sol_keypair',
    'xmr_spend_key',
    'xmr_view_key',
    'xfg_secret_key',
  };
  static const List<String> _secretSuffixes = ['_wif', '_rpc_pass'];

  final FlutterSecureStorage _storage;

  SwapKeystore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// The daemon substitutes keystore entries into JSON verbatim, so it
  /// accepts only printable ASCII without spaces, quotes or backslashes.
  static bool isPlainSecret(String secret) =>
      secret.isNotEmpty &&
      secret.codeUnits.every(
        (unit) =>
            unit >= 0x21 &&
            unit <= 0x7e &&
            unit != 0x22 && // "
            unit != 0x5c, // \
      );

  static bool _isSecretField(String key) =>
      _secretFields.contains(key) || _secretSuffixes.any(key.endsWith);

  /// Moves every secret of [config] into the returned [SealedSwapConfig.secrets]
  /// and leaves a reference in its place. Throws when a secret cannot be stored.
  static SealedSwapConfig seal(Map<String, dynamic> config) {
    final sealed = <String, dynamic>{};
    final secrets = <String, String>{};

    String reference(String name, Object? value) {
      final secret = value is String ? value : '';
      if (!isPlainSecret(secret)) {
        throw ArgumentError(
          '$name must be printable ASCII without spaces, quotes or backslashes',
        );
      }
      secrets[name] = secret;
      return '$referencePrefix$name';
    }

    for (final entry in config.entries) {
      if (entry.key == 'evm_chains' && entry.value is Map) {
        final chains = <String, dynamic>{};
        (entry.value as Map).forEach((chain, settings) {
          final copy = Map<String, dynamic>.from(settings as Map);
          if (copy.containsKey('private_key')) {
            copy['private_key'] = reference(
              'evm_${chain}_private_key',
              copy['private_key'],
            );
          }
          chains[chain as String] = copy;
        });
        sealed[entry.key] = chains;
      } else if (_isSecretField(entry.key)) {
        sealed[entry.key] = reference(entry.key, entry.value);
      } else {
        sealed[entry.key] = entry.value;
      }
    }
    return SealedSwapConfig(sealed, secrets);
  }

  /// The keystore passphrase, created on first use.
  Future<String> passphrase() async {
    final stored = await _storage.read(key: _passphraseStorageKey);
    if (stored != null && stored.isNotEmpty) return stored;
    final random = Random.secure();
    final bytes = List<int>.generate(
      _passphraseBytes,
      (_) => random.nextInt(256),
    );
    final created = base64Url.encode(bytes).replaceAll('=', '');
    await _storage.write(key: _passphraseStorageKey, value: created);
    return created;
  }

  /// Replaces the keystore at [path] with exactly [secrets], written by
  /// [swapdBinary] so the file format is the daemon's own. The new keystore
  /// is built beside the old one and moved over it only when complete.
  Future<void> write({
    required String swapdBinary,
    required String path,
    required Map<String, String> secrets,
  }) async {
    final environment = {passphraseEnvironment: await passphrase()};
    final staging = File('$path.new');
    if (staging.existsSync()) staging.deleteSync();
    try {
      for (final entry in secrets.entries) {
        final process = await Process.start(swapdBinary, [
          '--keystore-put',
          staging.path,
          entry.key,
        ], environment: environment);
        process.stdin.writeln(entry.value);
        await process.stdin.close();
        final stderrText = process.stderr.transform(utf8.decoder).join();
        await process.stdout.drain<void>();
        if (await process.exitCode != 0) {
          throw StateError(
            'xfg-swapd could not store ${entry.key}: ${(await stderrText).trim()}',
          );
        }
      }
      if (secrets.isNotEmpty) await staging.rename(path);
    } finally {
      if (staging.existsSync()) staging.deleteSync();
    }
  }
}
