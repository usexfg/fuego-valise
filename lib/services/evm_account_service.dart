import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web3dart/web3dart.dart';

import '../models/chain_registry.g.dart';

/// Public metadata for one saved EVM account.
///
/// The private key is kept in platform secure storage and is never included
/// in this model or the on-disk registry.
class EvmAccount {
  final String id;
  final String name;
  final String chainKey;
  final String address;
  final int createdAt;

  const EvmAccount({
    required this.id,
    required this.name,
    required this.chainKey,
    required this.address,
    required this.createdAt,
  });

  EvmAccount copyWith({String? name, String? chainKey}) => EvmAccount(
        id: id,
        name: name ?? this.name,
        chainKey: chainKey ?? this.chainKey,
        address: address,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'chainKey': chainKey,
        'address': address,
        'createdAt': createdAt,
      };

  factory EvmAccount.fromJson(Map<String, dynamic> json) => EvmAccount(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? 'EVM Account',
        chainKey: (json['chainKey'] as String? ?? 'eth').toLowerCase(),
        address: json['address'] as String? ?? '',
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      );
}

/// Result returned when a key is first created or imported.
///
/// The secret is returned so the creation screen can show it once for
/// backup. It is deliberately absent from [EvmAccount].
class EvmAccountCredentials {
  final EvmAccount account;
  final String privateKeyHex;

  const EvmAccountCredentials({
    required this.account,
    required this.privateKeyHex,
  });
}

/// Stores multiple EVM accounts while keeping one account active at a time.
///
/// An EVM key is chain-agnostic: [EvmAccount.chainKey] records the user's
/// current viewing chain, while the same account address works on every EVM
/// entry in [kChains]. Metadata is a registry file; key material remains in
/// FlutterSecureStorage.
class EvmAccountService {
  static const _registryFileName = 'fuego_evm_accounts.json';
  static const _secretKeyPrefix = 'fuego_evm_key_';

  final FlutterSecureStorage _storage;
  final List<EvmAccount> _accounts = [];
  String? _activeId;
  bool _initialized = false;
  Future<void>? _initialization;

  EvmAccountService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  List<EvmAccount> get accounts => List.unmodifiable(_accounts);
  String? get activeId => _activeId;
  EvmAccount? get activeAccount {
    final id = _activeId;
    if (id == null) return null;
    for (final account in _accounts) {
      if (account.id == id) return account;
    }
    return null;
  }

  Future<void> init() {
    if (_initialized) return Future.value();
    return _initialization ??= _loadRegistry();
  }

  Future<void> _loadRegistry() async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/$_registryFileName');
    try {
      final decoded = json.decode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        final entries = decoded['accounts'];
        if (entries is List<dynamic>) {
          _accounts
            ..clear()
            ..addAll(
              entries
                  .whereType<Map<String, dynamic>>()
                  .map(EvmAccount.fromJson)
                  .where(_isUsableAccount),
            );
        }
        _activeId = decoded['active'] as String?;
      }
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode != 2) rethrow;
    } on FormatException {
      _accounts.clear();
      _activeId = null;
    } on TypeError {
      _accounts.clear();
      _activeId = null;
    }

    if (activeAccount == null) {
      _activeId = _accounts.isEmpty ? null : _accounts.first.id;
    }
    _initialized = true;
  }

  Future<EvmAccountCredentials> createNew({
    required String name,
    required String chainKey,
  }) async {
    await init();
    final chain = _requireEvmChain(chainKey);
    final credentials = EthPrivateKey.createRandom(Random.secure());
    final privateKeyHex = _privateKeyHex(credentials);
    return _saveAccount(
      name: _accountName(name, chain),
      chainKey: chain.key,
      privateKeyHex: privateKeyHex,
    );
  }

  Future<EvmAccountCredentials> importExisting({
    required String name,
    required String chainKey,
    required String privateKeyHex,
  }) async {
    await init();
    final chain = _requireEvmChain(chainKey);
    final normalized = normalizePrivateKey(privateKeyHex);
    return _saveAccount(
      name: _accountName(name, chain),
      chainKey: chain.key,
      privateKeyHex: normalized,
    );
  }

  Future<EvmAccountCredentials> _saveAccount({
    required String name,
    required String chainKey,
    required String privateKeyHex,
  }) async {
    final id = _newId();
    final account = EvmAccount(
      id: id,
      name: name,
      chainKey: chainKey,
      address: deriveAddress(privateKeyHex),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final previousActive = _activeId;

    await _storage.write(
      key: _secretStorageKey(id),
      value: privateKeyHex,
    );
    _accounts.add(account);
    _activeId = id;
    try {
      await _saveRegistry();
    } catch (_) {
      _accounts.removeWhere((entry) => entry.id == id);
      _activeId = previousActive;
      await _storage.delete(key: _secretStorageKey(id));
      rethrow;
    }
    return EvmAccountCredentials(
      account: account,
      privateKeyHex: privateKeyHex,
    );
  }

  Future<String?> getPrivateKey([String? id]) async {
    await init();
    final accountId = id ?? _activeId;
    if (accountId == null) return null;
    _requireAccount(accountId);
    return _storage.read(key: _secretStorageKey(accountId));
  }

  Future<String?> getActivePrivateKey() => getPrivateKey();

  Future<void> setActive(String id) async {
    await init();
    _requireAccount(id);
    final previousActive = _activeId;
    _activeId = id;
    try {
      await _saveRegistry();
    } catch (_) {
      _activeId = previousActive;
      rethrow;
    }
  }

  Future<void> updateChain({
    required String id,
    required String chainKey,
  }) async {
    await init();
    final chain = _requireEvmChain(chainKey);
    final index = _accounts.indexWhere((account) => account.id == id);
    if (index == -1) throw StateError('EVM account not found');
    final previous = _accounts[index];
    _accounts[index] = _accounts[index].copyWith(chainKey: chain.key);
    try {
      await _saveRegistry();
    } catch (_) {
      _accounts[index] = previous;
      rethrow;
    }
  }

  Future<void> remove(String id) async {
    await init();
    final index = _accounts.indexWhere((account) => account.id == id);
    if (index == -1) throw StateError('EVM account not found');
    final removed = _accounts[index];
    final oldActive = _activeId;
    final secret = await _storage.read(key: _secretStorageKey(id));

    await _storage.delete(key: _secretStorageKey(id));
    _accounts.removeAt(index);
    if (_activeId == id) {
      _activeId = _accounts.isEmpty ? null : _accounts.first.id;
    }
    try {
      await _saveRegistry();
    } catch (_) {
      _accounts.insert(index, removed);
      _activeId = oldActive;
      if (secret != null) {
        await _storage.write(key: _secretStorageKey(id), value: secret);
      }
      rethrow;
    }
  }

  Future<void> _saveRegistry() async {
    final directory = await getApplicationDocumentsDirectory();
    final destination = File('${directory.path}/$_registryFileName');
    final temporary = File('${destination.path}.tmp');
    final data = {
      'active': _activeId,
      'accounts': _accounts.map((account) => account.toJson()).toList(),
    };
    await temporary.writeAsString(json.encode(data), flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', temporary.path]);
    }
    await temporary.rename(destination.path);
  }

  EvmAccount _requireAccount(String id) {
    for (final account in _accounts) {
      if (account.id == id) return account;
    }
    throw StateError('EVM account not found');
  }

  static bool _isUsableAccount(EvmAccount account) =>
      account.id.isNotEmpty &&
      account.address.isNotEmpty &&
      kChainByKey[account.chainKey]?.family == 'evm';

  static ChainEntry _requireEvmChain(String chainKey) {
    final normalized = chainKey.trim().toLowerCase();
    final chain = kChainByKey[normalized];
    if (chain == null || chain.family != 'evm') {
      throw ArgumentError('Unsupported EVM chain: $chainKey');
    }
    return chain;
  }

  static String _accountName(String name, ChainEntry chain) {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '${chain.name} Account' : trimmed;
  }

  static String _secretStorageKey(String id) => '$_secretKeyPrefix$id';

  static String _newId() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final entropy = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${DateTime.now().microsecondsSinceEpoch}_$entropy';
  }

  static String _privateKeyHex(EthPrivateKey credentials) => credentials
      .privateKey
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join()
      .padLeft(64, '0');

  static String normalizePrivateKey(String privateKey) {
    final trimmed = privateKey.trim();
    final clean = trimmed.startsWith('0x') || trimmed.startsWith('0X')
        ? trimmed.substring(2)
        : trimmed;
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(clean)) {
      throw ArgumentError('EVM private key must be 64 hexadecimal characters');
    }
    try {
      EthPrivateKey.fromHex(clean).address;
    } catch (_) {
      throw ArgumentError('Invalid EVM private key');
    }
    return clean.toLowerCase();
  }

  static String deriveAddress(String privateKey) {
    final normalized = normalizePrivateKey(privateKey);
    return EthPrivateKey.fromHex(normalized).address.hexEip55;
  }
}
