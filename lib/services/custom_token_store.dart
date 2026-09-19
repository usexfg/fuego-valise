import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/erc20_token.dart';

/// User-added ERC20 tokens persisted locally via SharedPreferences.
///
/// Custom tokens are indistinguishable from registry tokens at the service
/// layer — they are plain [Erc20Token]s merged into per-chain lists by
/// [forChain]. Registry entries always win on (chain,address) collision.
///
/// Every stored entry is [Erc20Kind.token]: a contract the user pasted in has
/// not been checked against an issuer, so it never joins the stable list.
class CustomTokenStore {
  CustomTokenStore._();
  static final CustomTokenStore instance = CustomTokenStore._();

  static const _prefsKey = 'erc20_custom_tokens_v1';

  List<Erc20Token> _customs = [];
  bool _loaded = false;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        _customs = list
            .map(
              (e) => Erc20Token(
                address: (e['address'] as String?) ?? '',
                symbol: (e['symbol'] as String?) ?? '?',
                name: (e['name'] as String?) ?? 'Unknown',
                decimals: (e['decimals'] as num?)?.toInt() ?? 18,
                chain:
                    EvmChainKey.fromKey((e['chain'] as String?) ?? '') ??
                    EvmChainKey.eth,
                kind: Erc20Kind.token,
              ),
            )
            .where((t) => t.address.isNotEmpty)
            .toList();
      }
    } catch (_) {
      _customs = [];
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(
        _customs
            .map(
              (t) => {
                'address': t.address,
                'symbol': t.symbol,
                'name': t.name,
                'decimals': t.decimals,
                'chain': t.chainKey,
              },
            )
            .toList(),
      ),
    );
  }

  /// All stored custom tokens.
  Future<List<Erc20Token>> all() async {
    await _ensureLoaded();
    return List.unmodifiable(_customs);
  }

  /// Custom tokens for one chain key.
  Future<List<Erc20Token>> customsFor(String chainKey) async {
    await _ensureLoaded();
    final k = chainKey.toLowerCase();
    return _customs.where((t) => t.chainKey == k).toList();
  }

  /// Registry entries + user entries for a chain, deduped by lowercase
  /// address with the registry taking precedence.
  ///
  /// [filter] selects the slice. [Erc20Filter.stables] returns registry
  /// stables only — a user-added contract is never one.
  Future<List<Erc20Token>> forChain(
    String chainKey, {
    Erc20Filter filter = Erc20Filter.all,
  }) async {
    final k = chainKey.toLowerCase();
    final registry = Erc20Registry.forChain(k, filter: filter);
    final customs = await customsFor(k);
    final seen = Erc20Registry.forChain(k).map((t) => t.lcAddress).toSet();
    final extra = customs
        .where((t) => !seen.contains(t.lcAddress) && filter.accepts(t.kind))
        .toList();
    return [...registry, ...extra];
  }

  Future<bool> exists(String chainKey, String address) async {
    final lc = address.toLowerCase();
    final tokens = await forChain(chainKey);
    return tokens.any((t) => t.lcAddress == lc);
  }

  Future<void> add(Erc20Token token) async {
    await _ensureLoaded();
    // Replace any prior custom at same (chain,address).
    _customs.removeWhere(
      (t) => t.chainKey == token.chainKey && t.lcAddress == token.lcAddress,
    );
    _customs.add(token);
    await _persist();
  }

  Future<void> remove(String chainKey, String address) async {
    await _ensureLoaded();
    final lc = address.toLowerCase();
    _customs.removeWhere(
      (t) => t.chainKey == chainKey.toLowerCase() && t.lcAddress == lc,
    );
    await _persist();
  }

  bool isRegistry(Erc20Token token) =>
      Erc20Registry.findByAddress(token.chainKey, token.address) != null;

  /// Drop the in-memory cache so the next read re-parses SharedPreferences.
  @visibleForTesting
  void resetForTest() {
    _customs = [];
    _loaded = false;
  }
}
