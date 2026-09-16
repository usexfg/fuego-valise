import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class Subaddress {
  final String address;
  final String label;
  final int index;
  final DateTime createdAt;

  const Subaddress({
    required this.address,
    required this.label,
    required this.index,
    required this.createdAt,
  });

  factory Subaddress.fromJson(Map<String, dynamic> json) {
    return Subaddress(
      address: json['address'] as String? ?? '',
      label: json['label'] as String? ?? '',
      index: json['index'] as int? ?? 0,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'address': address,
        'label': label,
        'index': index,
        'createdAt': createdAt.toIso8601String(),
      };

  String get addressShort {
    if (address.length <= 30) return address;
    return '${address.substring(0, 15)}...${address.substring(address.length - 10)}';
  }
}

class SubaddressStore {
  static const _fileName = 'subaddresses.json';
  List<Subaddress> _subaddresses = [];
  int _nextIndex = 1; // index 0 = master address

  List<Subaddress> get subaddresses => List.unmodifiable(_subaddresses);
  int get nextIndex => _nextIndex;

  Future<void> load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        _nextIndex = data['nextIndex'] as int? ?? 1;
        final list = data['subaddresses'] as List<dynamic>? ?? [];
        _subaddresses = list
            .map((e) => Subaddress.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('[subaddress] failed to load: $e');
      _subaddresses = [];
      _nextIndex = 1;
    }
  }

  Future<void> _save() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final dst = File('${dir.path}/$_fileName');
      final tmp = File('${dir.path}/$_fileName.tmp');
      await tmp.writeAsString(jsonEncode({
        'nextIndex': _nextIndex,
        'subaddresses': _subaddresses.map((s) => s.toJson()).toList(),
      }), flush: true);
      if (!Platform.isWindows) {
        try { await Process.run('chmod', ['600', tmp.path]); } catch (_) {}
      }
      await tmp.rename(dst.path);
    } catch (e) {
      debugPrint('[subaddress] failed to save: $e');
    }
  }

  Future<Subaddress> add({
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
      index: _nextIndex,
      createdAt: DateTime.now(),
    );
    _subaddresses.add(sub);
    _nextIndex++;
    await _save();
    return sub;
  }

  Future<void> remove(int index) async {
    _subaddresses.removeWhere((s) => s.index == index);
    await _save();
  }

  Future<void> updateLabel(int index, String label) async {
    final i = _subaddresses.indexWhere((s) => s.index == index);
    if (i != -1) {
      _subaddresses[i] = Subaddress(
        address: _subaddresses[i].address,
        label: label,
        index: _subaddresses[i].index,
        createdAt: _subaddresses[i].createdAt,
      );
      await _save();
    }
  }
}
