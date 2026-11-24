import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class Subaddress {
  final String address;
  final String label;
  final int index;
  final DateTime createdAt;

  /// Created before the fuego-suite scheme: an independent keypair (vault keys
  /// index and index + 1) that the wallet backend only finds with a separate
  /// scan, and whose keys overlap other addresses. Never hand these out again;
  /// funds on them are swept to the main address.
  final bool legacy;

  /// Derivation scheme walletd used: [funsaScheme] (own view key, unlinkable)
  /// or [sublimeScheme] (shares the wallet's view key, so any two are linkable).
  final int scheme;

  static const int sublimeScheme = 1;
  static const int funsaScheme = 2;

  bool get linkable => !legacy && scheme == sublimeScheme;

  const Subaddress({
    required this.address,
    required this.label,
    required this.index,
    required this.createdAt,
    this.legacy = false,
    this.scheme = sublimeScheme,
  });

  factory Subaddress.fromJson(
    Map<String, dynamic> json, {
    bool legacyDefault = false,
  }) {
    return Subaddress(
      address: json['address'] as String? ?? '',
      label: json['label'] as String? ?? '',
      index: json['index'] as int? ?? 0,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
      legacy: json['legacy'] as bool? ?? legacyDefault,
      scheme: json['scheme'] as int? ?? sublimeScheme,
    );
  }

  Map<String, dynamic> toJson() => {
    'address': address,
    'label': label,
    'index': index,
    'createdAt': createdAt.toIso8601String(),
    'legacy': legacy,
    'scheme': scheme,
  };

  Subaddress copyWith({String? label}) => Subaddress(
    address: address,
    label: label ?? this.label,
    index: index,
    createdAt: createdAt,
    legacy: legacy,
    scheme: scheme,
  );

  /// Same backend slot: kind, scheme and index (indices restart per scheme).
  bool sameSlot(Subaddress other) =>
      legacy == other.legacy && scheme == other.scheme && index == other.index;

  String get addressShort {
    if (address.length <= 30) return address;
    return '${address.substring(0, 15)}...${address.substring(address.length - 10)}';
  }
}

/// One sub-address as walletd lists it.
typedef BackendSubaddress = ({int scheme, int index, String address});

/// Reads one `get_subaddresses` list. Entries from a walletd older than funsa
/// carry no version: those are Sublime sub-addresses.
List<BackendSubaddress> backendSubaddresses(Object? entries) => [
  if (entries is List<dynamic>)
    for (final e in entries)
      if (e is Map<String, dynamic> &&
          e['index'] is int &&
          e['address'] is String)
        (
          scheme: e['version'] as int? ?? Subaddress.sublimeScheme,
          index: e['index'] as int,
          address: e['address'] as String,
        ),
];

class SubaddressStore {
  static const _fileName = 'subaddresses.json';

  /// 2: indices and addresses come from fuego_walletd (fuego-suite scheme).
  /// 3: entries carry their derivation scheme; v2 entries are all Sublime.
  /// Files without a version hold only old-scheme entries.
  static const _version = 3;

  List<Subaddress> _subaddresses = [];

  /// Whether the backend has been told to scan the legacy entries.
  bool _legacyRegistered = false;

  /// Labels by address, so they survive [reconcile].
  Map<String, String> _labels = {};

  /// Addresses the user removed from the list; [reconcile] keeps them out.
  Set<String> _hidden = {};

  List<Subaddress> get subaddresses => List.unmodifiable(_subaddresses);
  List<Subaddress> get legacy => _subaddresses.where((s) => s.legacy).toList();
  bool get legacyRegistered => _legacyRegistered;

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final version = data['version'] as int? ?? 1;
        final isOld = version < _version;
        final heldOnlyOldSchemeKeys = version < 2;
        final list = data['subaddresses'] as List<dynamic>? ?? [];
        _subaddresses = list
            .map(
              (e) => Subaddress.fromJson(
                e as Map<String, dynamic>,
                legacyDefault: heldOnlyOldSchemeKeys,
              ),
            )
            .toList();
        _legacyRegistered = data['legacyRegistered'] as bool? ?? false;
        _labels = (data['labels'] as Map<String, dynamic>? ?? const {}).map(
          (k, v) => MapEntry(k, v as String? ?? ''),
        );
        _hidden = (data['hidden'] as List<dynamic>? ?? const [])
            .cast<String>()
            .toSet();
        for (final s in _subaddresses) {
          if (s.label.isNotEmpty) _labels.putIfAbsent(s.address, () => s.label);
        }
        if (isOld) await _save();
      }
    } catch (e) {
      debugPrint('[subaddress] failed to load: $e');
      _subaddresses = [];
    }
  }

  Future<void> _save() async {
    try {
      final dst = await _file();
      final tmp = File('${dst.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'version': _version,
          'legacyRegistered': _legacyRegistered,
          'subaddresses': _subaddresses.map((s) => s.toJson()).toList(),
          'labels': _labels,
          'hidden': _hidden.toList(),
        }),
        flush: true,
      );
      // Mobile app sandboxes are already private, and iOS forbids spawning processes.
      if (Platform.isLinux || Platform.isMacOS) {
        try {
          await Process.run('chmod', ['600', tmp.path]);
        } catch (_) {}
      }
      await tmp.rename(dst.path);
    } catch (e) {
      debugPrint('[subaddress] failed to save: $e');
    }
  }

  /// Records a sub-address handed out by the backend.
  Future<Subaddress> add({
    required int index,
    required String address,
    required String label,
    required int scheme,
  }) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty || trimmed.length < 90) {
      throw ArgumentError('Invalid address');
    }
    if (label.length > 64) throw ArgumentError('Label too long');
    final sub = Subaddress(
      address: trimmed,
      label: label.trim(),
      index: index,
      createdAt: DateTime.now(),
      scheme: scheme,
    );
    _subaddresses.removeWhere((s) => s.sameSlot(sub));
    _subaddresses.add(sub);
    if (sub.label.isNotEmpty) _labels[sub.address] = sub.label;
    await _save();
    return sub;
  }

  /// Replaces the non-legacy entries with the sub-addresses the backend holds
  /// for the open wallet. The backend derives them from the wallet's seed, so an
  /// entry it does not list belongs to another key (another wallet, or the key an
  /// older walletd generated for itself) and must not be handed out.
  Future<void> reconcile(List<BackendSubaddress> fromBackend) async {
    final byAddress = {for (final s in _subaddresses) s.address: s};
    final current = <Subaddress>[
      for (final (:scheme, :index, :address) in fromBackend)
        if (!_hidden.contains(address))
          Subaddress(
            address: address,
            label: _labels[address] ?? '',
            index: index,
            createdAt: byAddress[address]?.createdAt ?? DateTime.now(),
            scheme: scheme,
          ),
    ];
    final next = [..._subaddresses.where((s) => s.legacy), ...current];
    if (listEquals(
      next
          .map(
            (s) =>
                '${s.legacy}:${s.scheme}:${s.index}:${s.address}:${s.label}',
          )
          .toList(),
      _subaddresses
          .map(
            (s) =>
                '${s.legacy}:${s.scheme}:${s.index}:${s.address}:${s.label}',
          )
          .toList(),
    )) {
      return;
    }
    _subaddresses = next;
    await _save();
  }

  Future<void> markLegacyRegistered() async {
    _legacyRegistered = true;
    await _save();
  }

  /// Hides a sub-address from the list. Legacy entries stay until their funds
  /// are swept, since they are the only record of which old keys to scan.
  Future<void> remove(Subaddress sub) async {
    for (final s in _subaddresses.where((s) => s.sameSlot(sub))) {
      if (!s.legacy) _hidden.add(s.address);
    }
    _subaddresses.removeWhere((s) => s.sameSlot(sub));
    await _save();
  }

  Future<void> updateLabel(Subaddress sub, String label) async {
    final i = _subaddresses.indexWhere((s) => s.sameSlot(sub));
    if (i != -1) {
      _subaddresses[i] = _subaddresses[i].copyWith(label: label);
      _labels[_subaddresses[i].address] = label;
      await _save();
    }
  }
}
