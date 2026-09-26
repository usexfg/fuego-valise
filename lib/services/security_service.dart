import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Secure storage + PIN / biometric auth. Secrets never fall back to plaintext prefs.
class SecurityService {
  static const _pinKey = 'wallet_pin_hash';
  static const _seedKey = 'wallet_seed_enc';
  static const _keysKey = 'wallet_keys_enc';
  static const _biometricKey = 'biometric_enabled';
  static const _vaultUnwrapKey = 'vault_unwrap_key';
  static const _encSaltKey = 'wallet_enc_salt';
  static const _failedAttemptsKey = 'pin_failed_attempts';
  static const _lockUntilKey = 'pin_lock_until_ms';
  static const _walletdPasswordKey = 'walletd_container_password';

  /// Max consecutive failed PIN attempts before temporary lockout.
  static const int maxFailedAttempts = 8;

  /// Lockout duration after max failures.
  static const Duration lockoutDuration = Duration(minutes: 15);

  /// KDF params — bumped for OWASP 2023 (PBKDF2-HMAC-SHA256 310k; 600k preferred).
  /// `v` in payload tracks version for re-encrypt on unlock if old iteration count.
  static const int _kPbkdf2IterationsV1 = 310000;
  static const int _kPbkdf2Bits = 256;
  static const int _kSaltBytes = 16;
  static const int _kPinSaltBytes = 32;

  static FlutterSecureStorage? _secureStorage;
  static Future<FlutterSecureStorage>? _storageFuture;
  static bool _initFailed = false;

  final LocalAuthentication _localAuth = LocalAuthentication();

  static Future<FlutterSecureStorage> _storage() {
    if (_initFailed) {
      throw StateError(
        'Secure storage unavailable. Wallet secrets cannot be stored or read.',
      );
    }
    if (_secureStorage != null) return Future.value(_secureStorage!);
    return _storageFuture ??= _initStorage();
  }

  static Future<FlutterSecureStorage> _initStorage() async {
    try {
      const storage = FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      );
      await storage.read(key: '__probe__');
      _secureStorage = storage;
      return storage;
    } catch (e) {
      _initFailed = true;
      debugPrint('SecurityService: secure storage unavailable (fail-closed)');
      throw StateError(
        'Secure storage unavailable. Wallet secrets cannot be stored or read.',
      );
    }
  }

  static Future<String?> _read(String key) async {
    final s = await _storage();
    return s.read(key: key);
  }

  static Future<void> _write(String key, String value) async {
    final s = await _storage();
    await s.write(key: key, value: value);
  }

  static Future<void> _delete(String key) async {
    final s = await _storage();
    await s.delete(key: key);
  }

  // ── DEX taker identity ──
  // The Ed25519 keypair published as takerPubKey in /requestswap. Persisted
  // so a restart between requesting a fill and driving the AFK swap does
  // not strand the identity (the maker pre-binds the published key).
  static const _takerSwapKey = 'dex_taker_swap_secret';

  static Future<String?> readTakerSwapSecret() => _read(_takerSwapKey);

  static Future<void> writeTakerSwapSecret(String secretHex) =>
      _write(_takerSwapKey, secretHex);

  // ── DEX maker identity ──
  // The keypair that signs /submitswap and /cancelswap offers (CryptoNote
  // Schnorr signatures over the offer hash). Persisted so offers posted in
  // one session can be cancelled in another.
  static const _makerSwapKey = 'dex_maker_swap_secret';

  static Future<String?> readMakerSwapSecret() => _read(_makerSwapKey);

  static Future<void> writeMakerSwapSecret(String secretHex) =>
      _write(_makerSwapKey, secretHex);

  // ── PIN ──────────────────────────────────────────────────────────────

  Future<bool> setPIN(String pin) async {
    _assertValidPin(pin);
    final salt = _secureRandomBytes(_kPinSaltBytes);
    final hashedPin = await _hashPIN(pin, salt);
    await _write(_pinKey, '${base64Encode(salt)}:$hashedPin');
    await _write(_failedAttemptsKey, '0');
    await _delete(_lockUntilKey);
    if (await _read(_encSaltKey) == null) {
      await _write(_encSaltKey, base64Encode(_secureRandomBytes(16)));
    }
    return true;
  }

  Future<bool> verifyPIN(String pin) async {
    if (await isLockedOut()) return false;
    try {
      final stored = await _read(_pinKey);
      if (stored == null) return false;

      final parts = stored.split(':');
      if (parts.length != 2) return false;

      final salt = base64Decode(parts[0]);
      final storedHash = parts[1];
      final inputHash = await _hashPIN(pin, salt);

      final ok = _constantTimeEquals(storedHash, inputHash);
      if (ok) {
        await _write(_failedAttemptsKey, '0');
        await _delete(_lockUntilKey);
      } else {
        await _registerFailedAttempt();
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasPIN() async {
    try {
      final pin = await _read(_pinKey);
      return pin != null && pin.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> removePIN() async {
    await _delete(_pinKey);
    return true;
  }

  Future<int> failedAttempts() async {
    final v = await _read(_failedAttemptsKey);
    return int.tryParse(v ?? '0') ?? 0;
  }

  Future<bool> isLockedOut() async {
    final until = await _read(_lockUntilKey);
    if (until == null) return false;
    final ms = int.tryParse(until) ?? 0;
    if (DateTime.now().millisecondsSinceEpoch >= ms) {
      await _delete(_lockUntilKey);
      return false;
    }
    return true;
  }

  Future<Duration?> lockoutRemaining() async {
    final until = await _read(_lockUntilKey);
    if (until == null) return null;
    final rem = (int.tryParse(until) ?? 0) - DateTime.now().millisecondsSinceEpoch;
    if (rem <= 0) return null;
    return Duration(milliseconds: rem);
  }

  Future<void> _registerFailedAttempt() async {
    final n = (await failedAttempts()) + 1;
    await _write(_failedAttemptsKey, n.toString());
    if (n >= maxFailedAttempts) {
      final until =
          DateTime.now().add(lockoutDuration).millisecondsSinceEpoch;
      await _write(_lockUntilKey, until.toString());
      await _write(_failedAttemptsKey, '0');
    }
  }

  /// Clear stale lockout state from a previous session/install.
  /// Lockouts are session-level protection, not permanent.
  Future<void> clearStaleLockout() async {
    await _delete(_lockUntilKey);
    await _delete(_failedAttemptsKey);
  }

  // ── Biometrics ───────────────────────────────────────────────────────

  Future<bool> isBiometricAvailable() async {
    try {
      final isAvailable = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      return isAvailable && isDeviceSupported;
    } catch (_) {
      return false;
    }
  }

  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } catch (_) {
      return [];
    }
  }

  Future<bool> authenticateWithBiometrics({
    String reason = 'Please authenticate to access your wallet',
    bool biometricOnly = true,
  }) async {
    try {
      return await _localAuth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          biometricOnly: biometricOnly,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> setBiometricEnabled(bool enabled) async {
    await _write(_biometricKey, enabled.toString());
    if (!enabled) {
      await _delete(_vaultUnwrapKey);
    }
  }

  Future<bool> isBiometricEnabled() async {
    final enabled = await _read(_biometricKey);
    return enabled == 'true';
  }

  /// After PIN unlock, store vault unwrap material for biometric re-entry.
  Future<void> storeVaultUnwrapKey(List<int> keyBytes) async {
    await _write(_vaultUnwrapKey, base64Encode(keyBytes));
  }

  Future<List<int>?> getVaultUnwrapKey() async {
    final v = await _read(_vaultUnwrapKey);
    if (v == null || v.isEmpty) return null;
    return base64Decode(v);
  }

  /// Random device-bound key for biometric vault envelopes. Created once
  /// and reused; never derived from any PIN/password.
  Future<List<int>> getOrCreateBioKey() async {
    final existing = await getVaultUnwrapKey();
    if (existing != null && existing.isNotEmpty) return existing;
    final key = _secureRandomBytes(32);
    await storeVaultUnwrapKey(key);
    return key;
  }

  Future<void> clearVaultUnwrapKey() async {
    await _delete(_vaultUnwrapKey);
  }

  // ── Wallet seed / keys (PIN-encrypted) ───────────────────────────────

  Future<bool> storeWalletSeed(String mnemonic, String pin) async {
    if (!validateMnemonic(mnemonic)) {
      throw ArgumentError('Invalid BIP39 mnemonic');
    }
    final encrypted = await encryptString(mnemonic.trim(), pin);
    await _write(_seedKey, encrypted);
    return true;
  }

  Future<String?> getWalletSeed(String pin) async {
    final encrypted = await _read(_seedKey);
    if (encrypted == null) return null;
    return decryptString(encrypted, pin);
  }

  Future<bool> storeWalletKeys({
    required String viewKey,
    required String spendKey,
    required String pin,
  }) async {
    if (_looksLikePlaceholder(viewKey) || _looksLikePlaceholder(spendKey)) {
      throw StateError('Refusing to store placeholder keys');
    }
    if (viewKey.isEmpty || spendKey.isEmpty) {
      throw ArgumentError('Keys must be non-empty');
    }
    final keysJson = json.encode({
      'viewKey': viewKey,
      'spendKey': spendKey,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    final encrypted = await encryptString(keysJson, pin);
    await _write(_keysKey, encrypted);
    return true;
  }

  Future<Map<String, String>?> getWalletKeys(String pin) async {
    final encrypted = await _read(_keysKey);
    if (encrypted == null) return null;
    final decrypted = await decryptString(encrypted, pin);
    final keysData = json.decode(decrypted) as Map<String, dynamic>;
    final viewKey = keysData['viewKey'] as String? ?? '';
    final spendKey = keysData['spendKey'] as String? ?? '';
    if (_looksLikePlaceholder(viewKey) || _looksLikePlaceholder(spendKey)) {
      throw StateError('Stored keys are placeholders; re-create the wallet');
    }
    return {'viewKey': viewKey, 'spendKey': spendKey};
  }

  Future<bool> hasWalletData() async {
    try {
      final seed = await _read(_seedKey);
      final keys = await _read(_keysKey);
      return (seed != null && seed.isNotEmpty) ||
          (keys != null && keys.isNotEmpty);
    } catch (_) {
      return false;
    }
  }

  Future<void> clearWalletData() async {
    await _delete(_seedKey);
    await _delete(_keysKey);
    await _delete(_pinKey);
    await _delete(_biometricKey);
    await _delete(_vaultUnwrapKey);
    await _delete(_encSaltKey);
    await _delete(_failedAttemptsKey);
    await _delete(_lockUntilKey);
    await _delete(_walletdPasswordKey);
  }

  // ── Walletd container password (random, stored securely) ─────────────

  Future<String> getOrCreateWalletdPassword() async {
    try {
      final existing = await _read(_walletdPasswordKey);
      if (existing != null && existing.isNotEmpty) return existing;
    } catch (_) {}
    final password = base64UrlEncode(_secureRandomBytes(32));
    // Persist so the same password is reused on next start (container was
    // created with this password — a different one on next call breaks it).
    await _write(_walletdPasswordKey, password);
    return password;
  }

  // ── Encrypt / decrypt helpers ────────────────────────────────────────

  Future<String> encryptString(String data, String pin) async {
    return _encryptBytes(utf8.encode(data), pin);
  }

  Future<String> decryptString(String encryptedData, String pin) async {
    final plain = await _decryptBytes(encryptedData, pin);
    return utf8.decode(plain);
  }

  Future<String> encryptBytesWithPin(List<int> data, String pin) async {
    return _encryptBytes(data, pin);
  }

  Future<Uint8List> decryptBytesWithPin(
    String encryptedData,
    String pin,
  ) async {
    return _decryptBytes(encryptedData, pin);
  }

  Future<String> encryptBytesWithKey(List<int> data, List<int> keyBytes) async {
    final algorithm = AesCbc.with256bits(macAlgorithm: Hmac.sha256());
    final secretKey = SecretKey(keyBytes);
    final encrypted = await algorithm.encrypt(data, secretKey: secretKey);
    final result = {
      'v': 1,
      'iv': base64Encode(encrypted.nonce),
      'data': base64Encode(encrypted.cipherText),
      'mac': base64Encode(encrypted.mac.bytes),
      'mode': 'rawkey',
    };
    return base64Encode(utf8.encode(json.encode(result)));
  }

  Future<Uint8List> decryptBytesWithKey(
    String encryptedData,
    List<int> keyBytes,
  ) async {
    final algorithm = AesCbc.with256bits(macAlgorithm: Hmac.sha256());
    final secretKey = SecretKey(keyBytes);
    final decoded = json.decode(utf8.decode(base64Decode(encryptedData)))
        as Map<String, dynamic>;
    final secretBox = SecretBox(
      base64Decode(decoded['data'] as String),
      nonce: base64Decode(decoded['iv'] as String),
      mac: Mac(base64Decode(decoded['mac'] as String)),
    );
    final decrypted = await algorithm.decrypt(secretBox, secretKey: secretKey);
    return Uint8List.fromList(decrypted);
  }

  Future<SecretKey> deriveDataKeyFromPIN(String pin) async {
    final saltB64 = await _read(_encSaltKey);
    if (saltB64 == null) {
      throw StateError('Encryption salt missing — set PIN before encrypting');
    }
    final salt = base64Decode(saltB64);
    final algorithm = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _kPbkdf2IterationsV1,
      bits: _kPbkdf2Bits,
    );
    final pinBytes = utf8.encode(pin);
    try {
      return await algorithm.deriveKey(
        secretKey: SecretKey(pinBytes),
        nonce: salt,
      );
    } finally {
      // Best-effort zeroize PIN bytes copy
      for (var i = 0; i < pinBytes.length; i++) pinBytes[i] = 0;
    }
  }

  Future<List<int>> extractDataKeyBytes(String pin) async {
    final key = await deriveDataKeyFromPIN(pin);
    return key.extractBytes();
  }

  Future<String> _encryptBytes(List<int> data, String pin) async {
    // Per-encrypt fresh salt (prevents global reuse); also persists as current global for legacy fallback
    final freshSalt = _secureRandomBytes(_kSaltBytes);
    final freshSaltB64 = base64Encode(freshSalt);
    await _write(_encSaltKey, freshSaltB64);
    final algorithm = AesCbc.with256bits(macAlgorithm: Hmac.sha256());
    final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: _kPbkdf2IterationsV1, bits: _kPbkdf2Bits);
    final pinBytes = utf8.encode(pin);
    SecretKey? secretKey;
    try {
      secretKey = await kdf.deriveKey(secretKey: SecretKey(pinBytes), nonce: freshSalt);
      final encrypted = await algorithm.encrypt(data, secretKey: secretKey);
      final result = {
        'v': 1,
        'salt': freshSaltB64,
        'iv': base64Encode(encrypted.nonce),
        'data': base64Encode(encrypted.cipherText),
        'mac': base64Encode(encrypted.mac.bytes),
        'mode': 'pin',
      };
      return base64Encode(utf8.encode(json.encode(result)));
    } finally {
      for (var i = 0; i < pinBytes.length; i++) pinBytes[i] = 0;
      if (secretKey != null) try { final b = await secretKey.extractBytes(); b.fillRange(0, b.length, 0); } catch (_) {}
      freshSalt.fillRange(0, freshSalt.length, 0);
    }
  }

  Future<Uint8List> _decryptBytes(String encryptedData, String pin) async {
    final decoded = json.decode(utf8.decode(base64Decode(encryptedData)))
        as Map<String, dynamic>;
    final saltB64 = decoded['salt'] as String?;
    // Do NOT overwrite global _encSaltKey from payload — attacker-controlled salt injection (ADV-08)
    // Use payload salt directly for this decrypt only; persist only if global missing and payload looks valid
    String? effectiveSaltB64 = saltB64;
    if (effectiveSaltB64 == null) {
      effectiveSaltB64 = await _read(_encSaltKey);
      if (effectiveSaltB64 == null) throw StateError('Missing salt for decrypt');
    }
    // Derive with payload salt without mutating global state
    final salt = base64Decode(effectiveSaltB64);
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _kPbkdf2IterationsV1,
      bits: _kPbkdf2Bits,
    );
    final pinBytes = utf8.encode(pin);
    SecretKey? secretKey;
    try {
      secretKey = await kdf.deriveKey(secretKey: SecretKey(pinBytes), nonce: salt);
      final secretBox = SecretBox(
        base64Decode(decoded['data'] as String),
        nonce: base64Decode(decoded['iv'] as String),
        mac: Mac(base64Decode(decoded['mac'] as String)),
      );
      final aead = AesCbc.with256bits(macAlgorithm: Hmac.sha256());
      final decrypted = await aead.decrypt(secretBox, secretKey: secretKey);
      return Uint8List.fromList(decrypted);
    } finally {
      for (var i = 0; i < pinBytes.length; i++) { pinBytes[i] = 0; }
      if (secretKey != null) try { final b = await secretKey.extractBytes(); b.fillRange(0, b.length, 0); } catch (_) {}
    }
  }

  Future<String> _hashPIN(String pin, List<int> salt) async {
    final algorithm = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _kPbkdf2IterationsV1,
      bits: _kPbkdf2Bits,
    );
    final pinBytes = utf8.encode(pin);
    SecretKey? secretKey;
    try {
      secretKey = await algorithm.deriveKey(
        secretKey: SecretKey(pinBytes),
        nonce: salt,
      );
      final keyBytes = await secretKey.extractBytes();
      try {
        return base64Encode(keyBytes);
      } finally {
        keyBytes.fillRange(0, keyBytes.length, 0);
      }
    } finally {
      for (var i = 0; i < pinBytes.length; i++) pinBytes[i] = 0;
    }
  }

  // ── Mnemonic (real BIP39) ────────────────────────────────────────────

  /// 24-word BIP39 mnemonic (256-bit entropy) via `Random.secure()`.
  static String generateMnemonic({int strength = 256}) {
    if (strength != 128 &&
        strength != 160 &&
        strength != 192 &&
        strength != 224 &&
        strength != 256) {
      throw ArgumentError('strength must be 128/160/192/224/256');
    }
    return bip39.generateMnemonic(strength: strength);
  }

  static bool validateMnemonic(String mnemonic) {
    final trimmed = mnemonic.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (trimmed.isEmpty) return false;
    try {
      return bip39.validateMnemonic(trimmed);
    } catch (_) {
      return false;
    }
  }

  /// BIP39 seed (64 bytes) → 32-byte vault seed (SHA-256 of full seed).
  static Uint8List mnemonicToVaultSeed(
    String mnemonic, {
    String passphrase = '',
  }) {
    if (!validateMnemonic(mnemonic)) {
      throw ArgumentError('Invalid BIP39 mnemonic');
    }
    final seed = bip39.mnemonicToSeed(mnemonic.trim(), passphrase: passphrase);
    return Uint8List.fromList(crypto.sha256.convert(seed).bytes);
  }

  static Uint8List secureRandomBytes(int length) => _secureRandomBytes(length);

  static Uint8List _secureRandomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => rng.nextInt(256)),
    );
  }

  static bool _constantTimeEquals(String a, String b) {
    final aBytes = utf8.encode(a);
    final bBytes = utf8.encode(b);
    // Constant-time even on length mismatch (no early return)
    final maxLen = aBytes.length > bBytes.length ? aBytes.length : bBytes.length;
    var diff = aBytes.length ^ bBytes.length;
    for (var i = 0; i < maxLen; i++) {
      final ai = i < aBytes.length ? aBytes[i] : 0;
      final bi = i < bBytes.length ? bBytes[i] : 0;
      diff |= ai ^ bi;
    }
    // Zeroize temp buffers
    aBytes.fillRange(0, aBytes.length, 0);
    bBytes.fillRange(0, bBytes.length, 0);
    return diff == 0;
  }

  static bool _looksLikePlaceholder(String value) {
    final lower = value.toLowerCase();
    return lower.contains('placeholder') ||
        lower.contains('todo') ||
        lower.startsWith('view_key_') ||
        lower.startsWith('spend_key_') ||
        lower.startsWith('restored_view_key') ||
        lower.startsWith('restored_spend_key');
  }

  static void _assertValidPin(String pin) {
    if (pin.length < 6 || pin.length > 12) {
      throw ArgumentError('PIN must be 6–12 digits (4-digit PINs are brute-forceable)');
    }
    if (!RegExp(r'^\d+$').hasMatch(pin)) {
      throw ArgumentError('PIN must be numeric');
    }
    // Reject trivial PINs
    if (RegExp(r'^(\d)\1+$').hasMatch(pin) || pin == '123456' || pin == '123456789' || pin == '0123456789') {
      throw ArgumentError('PIN is too weak — avoid repeated or sequential digits');
    }
  }
}

enum AuthenticationMethod {
  pin,
  biometric,
  both,
}

class AuthenticationResult {
  final bool success;
  final AuthenticationMethod? method;
  final String? error;

  const AuthenticationResult({
    required this.success,
    this.method,
    this.error,
  });

  factory AuthenticationResult.success(AuthenticationMethod method) {
    return AuthenticationResult(success: true, method: method);
  }

  factory AuthenticationResult.failure(String error) {
    return AuthenticationResult(success: false, error: error);
  }
}
