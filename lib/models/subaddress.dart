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

  const Subaddress({
    required this.address,
    required this.label,
    required this.index,
    required this.createdAt,
    this.legacy = false,
  });

  factory Subaddress.fromJson(Map<String, dynamic> json, {bool legacyDefault = false}) {
    return Subaddress(
      address: json['address'] as String? ?? '',
      label: json['label'] as String? ?? '',
      index: json['index'] as int? ?? 0,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
      legacy: json['legacy'] as bool? ?? legacyDefault,
    );
  }

  Map<String, dynamic> toJson() => {
        'address': address,
        'label': label,
        'index': index,
        'createdAt': createdAt.toIso8601String(),
        'legacy': legacy,
      };

  Subaddress copyWith({String? label}) => Subaddress(
        address: address,
        label: label ?? this.label,
        index: index,
        createdAt: createdAt,
        legacy: legacy,
      );

  String get addressShort {
    if (address.length <= 30) return address;
    return '${address.substring(0, 15)}...${address.substring(address.length - 10)}';
  }
}

class SubaddressStore {
  static const _fileName = 'subaddresses.json';

  /// 2: indices and addresses come from fuego_walletd (fuego-suite scheme).
  /// Files without a version hold only old-scheme entries.
  static const _version = 2;

  List<Subaddress> _subaddresses = [];

  /// Whether the backend has been told to scan the legacy entries.
  bool _legacyRegistered = false;

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
        final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final isOld = (data['version'] as int? ?? 1) < _version;
        final list = data['subaddresses'] as List<dynamic>? ?? [];
        _subaddresses = list
            .map((e) => Subaddress.fromJson(e as Map<String, dynamic>, legacyDefault: isOld))
            .toList();
        _legacyRegistered = data['legacyRegistered'] as bool? ?? false;
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
      await tmp.writeAsString(jsonEncode({
        'version': _version,
        'legacyRegistered': _legacyRegistered,
        'subaddresses': _subaddresses.map((s) => s.toJson()).toList(),
      }), flush: true);
      // Mobile app sandboxes are already private, and iOS forbids spawning processes.
      if (Platform.isLinux || Platform.isMacOS) {
        try { await Process.run('chmod', ['600', tmp.path]); } catch (_) {}
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
    );
    _subaddresses.removeWhere((s) => !s.legacy && s.index == index);
    _subaddresses.add(sub);
    await _save();
    return sub;
  }

  Future<void> markLegacyRegistered() async {
    _legacyRegistered = true;
    await _save();
  }

  /// Hides a sub-address from the list. Legacy entries stay until their funds
  /// are swept, since they are the only record of which old keys to scan.
  Future<void> remove(int index, {bool legacy = false}) async {
    _subaddresses.removeWhere((s) => s.index == index && s.legacy == legacy);
    await _save();
  }

  Future<void> updateLabel(int index, String label, {bool legacy = false}) async {
    final i = _subaddresses.indexWhere((s) => s.index == index && s.legacy == legacy);
    if (i != -1) {
      _subaddresses[i] = _subaddresses[i].copyWith(label: label);
      await _save();
    }
  }
}
