import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../ffi/fuego_native.dart';
import 'security_service.dart';

/// A saved wallet on this device. Only public metadata — no secrets.
class WalletEntry {
  final String id;
  final String name;
  final String file;
  final int createdAt;
  final String address;

  const WalletEntry({
    required this.id,
    required this.name,
    required this.file,
    required this.createdAt,
    this.address = '',
  });

  WalletEntry copyWith({String? name, String? address, String? file}) =>
      WalletEntry(
        id: id,
        name: name ?? this.name,
        file: file ?? this.file,
        createdAt: createdAt,
        address: address ?? this.address,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'file': file,
    'createdAt': createdAt,
    'address': address,
  };

  factory WalletEntry.fromJson(Map<String, dynamic> j) => WalletEntry(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? 'Wallet',
    file: j['file'] as String? ?? '',
    createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
    address: j['address'] as String? ?? '',
  );
}

/// HD wallet vault via native FFI — multi-wallet edition.
///
/// Each wallet is stored as its own encrypted file (`fuego_vault_<id>.enc`)
/// tracked in a plain registry (`fuego_wallets.json`). Every wallet file is
/// encrypted with its OWN password — the app PIN never touches wallet
/// material. Biometric envelopes use a random device-bound key. Secrets are
/// only available after [unlockActive], [switchWallet] or
/// [unlockWithBiometricKey]. Never auto-creates an unlocked vault on cold
/// start.
class FuegoVaultService {
  static const _vaultFileName = 'fuego_vault.enc';
  static const _legacyVaultFileName = 'fuego_vault.bin';
  static const _metaFileName = 'fuego_vault.meta';
  static const _registryFileName = 'fuego_wallets.json';

  final SecurityService _security;
  FuegoNative? _native;
  Uint8List? _vaultBytes;
  String? _cachedAddress;
  String? _spendPublicKey;
  String? _viewSecretKey;
  bool _unlocked = false;
  bool _existsOnDisk = false;
  String? _activeId;
  List<WalletEntry> _wallets = [];

  FuegoVaultService({SecurityService? security})
      : _security = security ?? SecurityService();

  FuegoNative get _ffi {
    _native ??= FuegoNative();
    return _native!;
  }

  bool get isUnlocked => _unlocked && _vaultBytes != null;
  bool get existsOnDisk => _existsOnDisk;
  String get address => _unlocked ? (_cachedAddress ?? '') : '';
  Uint8List? get vaultBytes => _unlocked ? _vaultBytes : null;
  String? get spendPublicKey => _unlocked ? _spendPublicKey : null;
  String? get viewSecretKey => _unlocked ? _viewSecretKey : null;

  /// Saved wallets in creation order. Read-only view.
  List<WalletEntry> get wallets => List.unmodifiable(_wallets);
  String? get activeWalletId => _activeId;
  WalletEntry? get activeWallet {
    if (_activeId == null) return null;
    for (final w in _wallets) {
      if (w.id == _activeId) return w;
    }
    return null;
  }

  /// Probe disk only — does not load or generate secrets. Loads the wallet
  /// registry and migrates a legacy single-file vault if present.
  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    final regFile = File('${dir.path}/$_registryFileName');
    if (await regFile.exists()) {
      try {
        final data = json.decode(await regFile.readAsString())
            as Map<String, dynamic>;
        _activeId = data['active'] as String?;
        _wallets = (data['wallets'] as List<dynamic>? ?? [])
            .map((e) => WalletEntry.fromJson(e as Map<String, dynamic>))
            .where((e) => e.id.isNotEmpty && e.file.isNotEmpty)
            .toList();
      } catch (_) {
        _wallets = [];
        _activeId = null;
      }
    }

    // Migrate a pre-multi-wallet single-file vault into the registry.
    if (_wallets.isEmpty) {
      final enc = File('${dir.path}/$_vaultFileName');
      final legacy = File('${dir.path}/$_legacyVaultFileName');
      if (await enc.exists() || await legacy.exists()) {
        _wallets = [
          WalletEntry(
            id: 'legacy',
            name: 'Main Wallet',
            file: await enc.exists() ? _vaultFileName : _legacyVaultFileName,
            createdAt: 0,
          ),
        ];
        _activeId = 'legacy';
        await _saveRegistry();
      }
    }

    if (_activeId == null || activeWallet == null) {
      _activeId = _wallets.isNotEmpty ? _wallets.first.id : null;
    }
    _existsOnDisk = _wallets.isNotEmpty;
  }

  Future<void> _saveRegistry() async {
    final dir = await getApplicationDocumentsDirectory();
    final data = {'active': _activeId, 'wallets': _wallets.map((w) => w.toJson()).toList()};
    final tmp = File('${dir.path}/$_registryFileName.tmp');
    final dst = File('${dir.path}/$_registryFileName');
    await tmp.writeAsString(json.encode(data), flush: true);
    if (!Platform.isWindows) {
      try { await Process.run('chmod', ['600', tmp.path]); } catch (_) {}
    }
    await tmp.rename(dst.path);
  }

  WalletEntry _requireEntry(String id) {
    for (final w in _wallets) {
      if (w.id == id) return w;
    }
    throw StateError('Wallet not found');
  }

  /// Create a NEW wallet file (does not replace existing wallets), encrypt
  /// with its own [password], set as active, and return the seed phrase.
  Future<String> createNew({
    required String password,
    String? mnemonic,
    String? name,
  }) async {
    final phrase = mnemonic ?? SecurityService.generateMnemonic();
    if (!SecurityService.validateMnemonic(phrase)) {
      throw ArgumentError('Invalid BIP39 mnemonic');
    }
    await _security.storeWalletSeed(phrase, password);

    final seed32 = SecurityService.mnemonicToVaultSeed(phrase);
    final bytes = _ffi.vaultFromSeed(seed32);
    if (bytes.isEmpty) {
      throw StateError('Failed to create vault from seed via FFI');
    }

    final id = _generateWalletId();
    final file = 'fuego_vault_$id.enc';
    await _persistEncrypted(file, bytes, password);
    await _loadInMemory(bytes);
    await _storeDerivedKeys(password);
    await ensureBiometricEnvelope();

    final entry = WalletEntry(
      id: id,
      name: name ?? 'Wallet ${_wallets.length + 1}',
      file: file,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      address: _cachedAddress ?? '',
    );
    _wallets = [..._wallets, entry];
    _activeId = id;
    _existsOnDisk = true;
    await _saveRegistry();
    return phrase;
  }

  /// Restore vault from BIP39 mnemonic (creates a new wallet file).
  Future<void> restoreFromMnemonic({
    required String mnemonic,
    required String password,
    String? name,
  }) async {
    if (!SecurityService.validateMnemonic(mnemonic)) {
      throw ArgumentError('Invalid BIP39 mnemonic');
    }
    await createNew(password: password, mnemonic: mnemonic.trim(), name: name);
  }

  /// Unlock the ACTIVE wallet's encrypted vault with its password.
  Future<bool> unlockActive(String password) async {
    final entry = activeWallet;
    if (entry == null) return false;

    final dir = await getApplicationDocumentsDirectory();
    final encFile = File('${dir.path}/${entry.file}');
    final legacy = File('${dir.path}/$_legacyVaultFileName');

    Uint8List plain;
    try {
      if (await encFile.exists()) {
        final payload = await encFile.readAsString();
        plain = await _security.decryptBytesWithPin(payload, password);
      } else if (entry.file == _legacyVaultFileName && await legacy.exists()) {
        // One-time migration of plaintext legacy vault
        plain = await legacy.readAsBytes();
        await _persistEncrypted(_vaultFileName, plain, password);
        try {
          await legacy.delete();
        } catch (_) {}
        _wallets = _wallets
            .map((w) => w.id == entry.id ? w.copyWith(file: _vaultFileName) : w)
            .toList();
        await _saveRegistry();
      } else {
        throw StateError('No vault file on disk');
      }
    } catch (e) {
      debugPrint('Vault unlock failed');
      return false;
    }

    await _loadInMemory(plain);
    await _updateEntryAddress(entry, password);
    return true;
  }

  /// Switch the active wallet to [id], decrypting it with that wallet's
  /// password. Keeps secure-storage seed/keys in sync with the new wallet.
  Future<bool> switchWallet(String id, String password) async {
    if (id == _activeId && isUnlocked) return true;
    final entry = _requireEntry(id);

    final dir = await getApplicationDocumentsDirectory();
    final encFile = File('${dir.path}/${entry.file}');
    if (!await encFile.exists()) {
      throw StateError('No vault file on disk for ${entry.name}');
    }
    final payload = await encFile.readAsString();
    final plain = await _security.decryptBytesWithPin(payload, password);

    await _loadInMemory(plain);
    _activeId = id;
    await _updateEntryAddress(entry, password);
    await _storeDerivedKeys(password);
    final seed = getSeed();
    if (seed != null) {
      await _security.storeWalletSeed(seed, password);
    }
    await ensureBiometricEnvelope();
    await _saveRegistry();
    return true;
  }

  /// Remove a saved wallet file. Refuses to remove the last wallet.
  /// If the removed wallet was active, locks the vault and marks the next
  /// wallet as active (it stays locked until unlocked with its password).
  Future<void> removeWallet(String id) async {
    if (_wallets.length <= 1) {
      throw StateError('Cannot remove the last wallet');
    }
    final entry = _requireEntry(id);

    final dir = await getApplicationDocumentsDirectory();
    for (final name in [entry.file, '${entry.file}.bio']) {
      final f = File('${dir.path}/$name');
      if (await f.exists()) {
        await f.delete();
      }
    }

    final wasActive = _activeId == id;
    _wallets = _wallets.where((w) => w.id != id).toList();
    if (wasActive) {
      lock();
      _activeId = _wallets.first.id;
    }
    await _saveRegistry();
  }

  /// Unlock using biometric-gated unwrap key (after [authenticateWithBiometrics]).
  Future<bool> unlockWithBiometricKey() async {
    final key = await _security.getVaultUnwrapKey();
    if (key == null) return false;

    final entry = activeWallet;
    if (entry == null) return false;

    final dir = await getApplicationDocumentsDirectory();
    final encFile = File('${dir.path}/${entry.file}');
    if (!await encFile.exists()) return false;

    final payload = await encFile.readAsString();
    // Payload is PIN-encrypted; for biometric we store a second envelope.
    final bioFile = File('${dir.path}/${entry.file}.bio');
    if (await bioFile.exists()) {
      final bioPayload = await bioFile.readAsString();
      final plain = await _security.decryptBytesWithKey(bioPayload, key);
      await _loadInMemory(plain);
      return true;
    }

    // Fallback: unwrap key is the PIN-derived data key — re-decrypt pin payload
    try {
      final decoded =
          json.decode(utf8.decode(base64Decode(payload))) as Map<String, dynamic>;
      // Reconstruct SecretKey path via raw AES with stored unwrap key
      final plain = await _security.decryptBytesWithKey(
        // rebuild rawkey-shaped blob from pin blob fields
        base64Encode(utf8.encode(json.encode({
          'v': 1,
          'iv': decoded['iv'],
          'data': decoded['data'],
          'mac': decoded['mac'],
          'mode': 'rawkey',
        }))),
        key,
      );
      await _loadInMemory(plain);
      return true;
    } catch (e) {
      debugPrint('Vault biometric unlock failed');
      return false;
    }
  }

  /// Wipe secrets from memory (does not delete disk) — zeroizes before deref.
  void lock() {
    try { _vaultBytes?.fillRange(0, _vaultBytes!.length, 0); } catch (_) {}
    // Strings cannot be zeroized in Dart — drop references and hint GC
    _vaultBytes = null;
    _cachedAddress = null;
    _spendPublicKey = null;
    _viewSecretKey = null;
    _unlocked = false;
  }

  /// Delete ALL wallet files and the registry from disk and clear secure
  /// wallet material.
  Future<void> wipe() async {
    lock();
    final dir = await getApplicationDocumentsDirectory();
    for (final entry in _wallets) {
      for (final name in [entry.file, '${entry.file}.bio']) {
        final f = File('${dir.path}/$name');
        if (await f.exists()) {
          await f.delete();
        }
      }
    }
    for (final name in [
      _vaultFileName,
      '$_vaultFileName.bio',
      _legacyVaultFileName,
      _metaFileName,
      _registryFileName,
    ]) {
      final f = File('${dir.path}/$name');
      if (await f.exists()) {
        await f.delete();
      }
    }
    await _security.clearWalletData();
    _wallets = [];
    _activeId = null;
    _existsOnDisk = false;
  }

  /// Mnemonic / seed hex — only when unlocked. Requires prior auth by caller.
  String? getSeed() {
    if (!isUnlocked || _vaultBytes == null) return null;
    return _ffi.vaultGetSeed(_vaultBytes!);
  }

  Map<String, dynamic> deriveKeypair(int index) {
    _requireUnlocked();
    return _ffi.vaultDeriveKeypair(_vaultBytes!, index);
  }

  String makeAddress(List<int> spendPub, List<int> viewPub) {
    return _ffi.makeAddress(spendPub, viewPub);
  }

  String generateKeyDerivation(List<int> key1, List<int> secret2) {
    _requireUnlocked();
    return _ffi.generateKeyDerivation(key1, secret2);
  }

  String generateKeyImage(List<int> pubkey, List<int> secret) {
    _requireUnlocked();
    return _ffi.generateKeyImage(pubkey, secret);
  }

  String underivePublicKey(
    List<int> derivation,
    int outputIndex,
    List<int> outputKey,
  ) {
    _requireUnlocked();
    return _ffi.underivePublicKey(derivation, outputIndex, outputKey);
  }

  String sign(List<int> secret, List<int> message) {
    _requireUnlocked();
    return _ffi.sign(secret, message);
  }

  bool verify(List<int> pubkey, List<int> message, List<int> signature) {
    return _ffi.verify(pubkey, message, signature);
  }

  String base58Encode(List<int> data) => _ffi.base58Encode(data);

  FuegoNative get ffi => _ffi;

  // ── Internals ────────────────────────────────────────────────────────

  void _requireUnlocked() {
    if (!isUnlocked || _vaultBytes == null) {
      throw StateError('Vault is locked');
    }
  }

  Future<void> _updateEntryAddress(WalletEntry entry, String pin) async {
    final addr = _cachedAddress ?? '';
    if (addr.isEmpty || entry.address == addr) return;
    _wallets = _wallets
        .map((w) => w.id == entry.id ? w.copyWith(address: addr) : w)
        .toList();
    await _saveRegistry();
  }

  Future<void> _persistEncrypted(
    String fileName,
    Uint8List plain,
    String password,
  ) async {
    final dir = await getApplicationDocumentsDirectory();
    final enc = await _security.encryptBytesWithPin(plain, password);
    final encFile = File('${dir.path}/$fileName');
    await encFile.writeAsString(enc, flush: true);
    if (!Platform.isWindows) try { await Process.run('chmod', ['600', encFile.path]); } catch (_) {}

    // Biometric re-entry envelope, ONLY when biometrics are enabled.
    //
    // This used to be unconditional. The envelope is encrypted with a
    // device-bound key held in secure storage with no biometric binding
    // (iOS accessibility is first_unlock_this_device; libsecret/DPAPI
    // elsewhere), so writing it for every wallet meant the vault could be
    // decrypted from disk + keychain without the PIN. The biometric prompt is
    // an in-app check and does not gate reading that key.
    final bioFile = File('${dir.path}/$fileName.bio');
    if (await _security.isBiometricEnabled()) {
      final bioKey = await _security.getOrCreateBioKey();
      final bio = await _security.encryptBytesWithKey(plain, bioKey);
      await bioFile.writeAsString(bio, flush: true);
      if (!Platform.isWindows) try { await Process.run('chmod', ['600', bioFile.path]); } catch (_) {}
    } else if (await bioFile.exists()) {
      // Biometrics were turned off after an envelope was written — remove the
      // PIN-free copy rather than leaving it behind.
      try { await bioFile.delete(); } catch (_) {}
    }
  }

  Future<void> _loadInMemory(Uint8List bytes) async {
    _vaultBytes = bytes;
    _cachedAddress = _ffi.vaultGetAddress(bytes, 0);
    final spendKp = _ffi.vaultDeriveKeypair(bytes, 0);
    _spendPublicKey = spendKp['public'] as String?;
    final viewKp = _ffi.vaultDeriveKeypair(bytes, 1);
    _viewSecretKey = viewKp['secret'] as String?;
    _unlocked = true;
    // Intentionally no logging of address/keys
  }

  Future<void> _storeDerivedKeys(String password) async {
    final spend = deriveKeypair(0);
    final view = deriveKeypair(1);
    final spendSecret = spend['secret'] as String? ?? '';
    final viewSecret = view['secret'] as String? ?? '';
    if (spendSecret.isEmpty || viewSecret.isEmpty) {
      throw StateError('Failed to derive vault keys');
    }
    await _security.storeWalletKeys(
      viewKey: viewSecret,
      spendKey: spendSecret,
      pin: password,
    );
  }

  /// Delete every `.bio` envelope on disk.
  ///
  /// Call when biometrics are switched off: clearing the unwrap key alone
  /// leaves a full PIN-free copy of each vault on disk.
  Future<void> purgeBiometricEnvelopes() async {
    final dir = await getApplicationDocumentsDirectory();
    for (final w in _wallets) {
      final f = File('${dir.path}/${w.file}.bio');
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
  }

  /// Ensure the device-bound biometric unwrap key exists and the active
  /// wallet's biometric envelope is current. Never derived from any wallet
  /// password or PIN. Safe to call after enabling biometrics.
  Future<void> ensureBiometricEnvelope() async {
    if (!await _security.isBiometricEnabled()) return;
    final bioKey = await _security.getOrCreateBioKey();

    // Refresh the active wallet's biometric envelope if we hold plaintext.
    final entry = activeWallet;
    final bytes = _vaultBytes;
    if (entry != null && bytes != null) {
      final dir = await getApplicationDocumentsDirectory();
      final bio = await _security.encryptBytesWithKey(bytes, bioKey);
      await File('${dir.path}/${entry.file}.bio')
          .writeAsString(bio, flush: true);
    }
  }

  static String _generateWalletId() {
    // 128-bit entropy + timestamp to avoid collisions, not predictable seq.
    final rnd = SecurityService.secureRandomBytes(16);
    final hex = rnd.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${DateTime.now().microsecondsSinceEpoch}_$hex';
  }
}
