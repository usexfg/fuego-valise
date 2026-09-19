import 'package:shared_preferences/shared_preferences.dart';

/// Which CDs the user has opted into automatic renewal for, persisted
/// locally via SharedPreferences.
///
/// Renewal is a wallet feature: the chain has no auto-roll (Blockchain.cpp
/// gates it behind a v13 TODO and never populates its CommitmentIndex), so
/// the opt-in lives here rather than on-chain. That makes it per-install —
/// restoring the same wallet elsewhere starts with renewal off, and the CDs
/// themselves are unaffected either way.
///
/// CD ids are deposit transaction hashes. A renewal spends the old CD and
/// creates a new one with a new id, so [prune] drops ids that no longer
/// appear in the wallet's CD list.
class CdAutoRenewStore {
  CdAutoRenewStore({SharedPreferences? prefs}) : _injected = prefs;

  static const _prefsKey = 'cd_auto_renew_ids_v1';

  final SharedPreferences? _injected;

  Future<SharedPreferences> get _prefs async =>
      _injected ?? await SharedPreferences.getInstance();

  Future<Set<String>> load() async {
    try {
      final prefs = await _prefs;
      return (prefs.getStringList(_prefsKey) ?? const []).toSet();
    } catch (_) {
      // A storage failure must not block the CD screen; renewal simply
      // stays off until it can be read.
      return <String>{};
    }
  }

  Future<void> save(Set<String> cdIds) async {
    try {
      final prefs = await _prefs;
      await prefs.setStringList(_prefsKey, cdIds.toList());
    } catch (_) {
      // Ignored: losing the opt-in is recoverable, and surfacing a storage
      // error here would block the toggle.
    }
  }

  /// Drop opt-ins for CDs that no longer exist, so the set cannot grow
  /// without bound as CDs are claimed and rolled.
  Future<Set<String>> prune(Set<String> liveCdIds) async {
    final stored = await load();
    final kept = stored.intersection(liveCdIds);
    if (kept.length != stored.length) {
      await save(kept);
    }
    return kept;
  }
}
