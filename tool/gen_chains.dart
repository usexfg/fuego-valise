// Chain registry generator.
//
// Reads chains.yaml (repo root — the single source of truth for chain
// metadata) and emits lib/models/chain_registry.g.dart.
//
// Usage:
//   dart run tool/gen_chains.dart          # (re)generate
//   dart run tool/gen_chains.dart --check  # verify file is up to date; exit 1 on drift
//
// No external dependencies: parses the simple flat block YAML subset used
// by chains.yaml directly ("- key:" starts an entry, indented "k: v" lines
// follow; strings may be single/double quoted; '#' comments stripped).
//
// The emitted source is run through `dart format` before it is written or
// compared. CI gates on `dart format --set-exit-if-changed lib/ test/`, and
// the generated file lives under lib/ — so unformatted output would either
// fail that gate or, once someone formatted it by hand, fail the --check
// golden here. Formatting on both paths keeps the two gates agreeing.

import 'dart:io';

const String yamlPath = 'chains.yaml';
const String outPath = 'lib/models/chain_registry.g.dart';

const Set<String> requiredFields = {
  'key', 'ticker', 'name', 'family', 'chainId', 'rpc',
  'gasToken', 'color', 'icon', 'tier', 'confirmBlocks',
};
const Set<String> allowedFamilies = {'evm', 'utxo', 'cryptonote', 'sol'};
const Set<String> allowedTiers = {'swap', 'wallet'};

void main(List<String> args) {
  final check = args.contains('--check');
  final src = File(yamlPath).readAsStringSync();
  final chains = parseChainsYaml(src);
  validate(chains);
  final code = dartFormat(render(chains));

  final outFile = File(outPath);
  if (!check) {
    outFile.writeAsStringSync(code);
    stdout.writeln('Wrote $outPath (${chains.length} chains).');
    return;
  }

  final existing = outFile.existsSync() ? outFile.readAsStringSync() : '';
  if (existing == code) {
    stdout.writeln('OK: $outPath is up to date (${chains.length} chains).');
    exit(0);
  }
  stderr.writeln('DRIFT: $outPath does not match chains.yaml.');
  stderr.writeln('Run: dart run tool/gen_chains.dart');
  _printDiffSummary(existing, code);
  exit(1);
}

/// Runs [source] through `dart format` and returns the result.
///
/// Fails loudly rather than returning the unformatted source: emitting
/// something the repo's format gate rejects only moves the failure to CI.
String dartFormat(String source) {
  final dir = Directory.systemTemp.createTempSync('gen_chains');
  try {
    final tmp = File('${dir.path}/chain_registry.g.dart')
      ..writeAsStringSync(source);
    final r = Process.runSync('dart', ['format', '--summary=none', tmp.path]);
    if (r.exitCode != 0) {
      stderr.writeln('dart format failed (exit ${r.exitCode}): ${r.stderr}');
      exit(1);
    }
    return tmp.readAsStringSync();
  } finally {
    dir.deleteSync(recursive: true);
  }
}

// ── Minimal YAML subset parser ────────────────────────────────────────

/// Parses the flat block format used by chains.yaml into ordered maps.
List<Map<String, String>> parseChainsYaml(String src) {
  final chains = <Map<String, String>>[];
  Map<String, String>? current;
  var inChainsBlock = false;

  for (final rawLine in src.split('\n')) {
    final line = rawLine;
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

    if (!inChainsBlock) {
      if (trimmed == 'chains:') inChainsBlock = true;
      continue;
    }

    if (trimmed.startsWith('- ')) {
      current = <String, String>{};
      chains.add(current);
      final inline = trimmed.substring(2).trim();
      if (inline.isNotEmpty) _addField(current, inline);
      continue;
    }

    if (current != null && trimmed.contains(':')) {
      // Indented "field: value" line inside the current entry.
      _addField(current, trimmed);
    }
  }
  return chains;
}

void _addField(Map<String, String> entry, String pair) {
  final colon = pair.indexOf(':');
  if (colon <= 0) throw FormatException('Malformed line: "$pair"');
  final field = pair.substring(0, colon).trim();
  entry[field] = _cleanValue(pair.substring(colon + 1).trim());
}

/// Strips surrounding quotes and trailing inline comments from a value.
String _cleanValue(String raw) {
  if (raw.length >= 2 && (raw.startsWith("'") || raw.startsWith('"'))) {
    final quote = raw[0];
    final end = raw.indexOf(quote, 1);
    if (end != -1) return raw.substring(1, end);
    throw FormatException('Unterminated quoted value: "$raw"');
  }
  // Unquoted: cut at first whitespace-preceded comment marker.
  final idx = raw.indexOf(' #');
  return (idx == -1 ? raw : raw.substring(0, idx)).trim();
}

// ── Validation ────────────────────────────────────────────────────────

void validate(List<Map<String, String>> chains) {
  if (chains.isEmpty) throw StateError('$yamlPath defines no chains.');
  final seen = <String>{};
  for (final c in chains) {
    for (final f in requiredFields) {
      if (!c.containsKey(f)) {
        throw StateError('Chain missing field "$f": ${c['key'] ?? c}');
      }
    }
    final key = c['key']!;
    if (!seen.add(key)) throw StateError('Duplicate chain key: $key');
    if (!allowedFamilies.contains(c['family'])) {
      throw StateError('Chain $key: unknown family "${c['family']}"');
    }
    if (!allowedTiers.contains(c['tier'])) {
      throw StateError('Chain $key: unknown tier "${c['tier']}"');
    }
    _parseInt(c, key, 'chainId');
    _parseInt(c, key, 'confirmBlocks');
    final color = c['color']!;
    if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)) {
      throw StateError('Chain $key: color must be "#RRGGBB", got "$color"');
    }
  }
}

int _parseInt(Map<String, String> c, String key, String field) {
  final v = int.tryParse(c[field]!);
  if (v == null || v < 0) {
    throw StateError('Chain $key: $field must be a non-negative int, got "${c[field]}"');
  }
  return v;
}

int _parseColor(String hex) => int.parse(hex.substring(1), radix: 16);

// ── Rendering ─────────────────────────────────────────────────────────

String render(List<Map<String, String>> chains) {
  final b = StringBuffer();
  b.writeln('// GENERATED FILE — from chains.yaml via tool/gen_chains.dart. DO NOT EDIT.');
  b.writeln();
  b.writeln('/// One chain\'s metadata, generated from [chains.yaml] at repo root.');
  b.writeln('/// Regenerate with: dart run tool/gen_chains.dart');
  b.writeln('class ChainEntry {');
  b.writeln('  final String key;');
  b.writeln('  final String ticker;');
  b.writeln('  final String name;');
  b.writeln('  final String family;');
  b.writeln('  final String rpc;');
  b.writeln('  final String gasToken;');
  b.writeln("  /// 'swap' (wired into xfg-swapd orderbook) or 'wallet' (ERC20 layer only).");
  b.writeln('  final String tier;');
  b.writeln('  final String icon;');
  b.writeln('  final int chainId;');
  b.writeln('  final int confirmBlocks;');
  b.writeln('  /// Brand color as 0xRRGGBB (no alpha byte).');
  b.writeln('  final int colorValue;');
  b.writeln();
  b.writeln('  const ChainEntry({');
  for (final f in const [
    'key', 'ticker', 'name', 'family', 'rpc', 'gasToken', 'tier',
    'icon', 'chainId', 'confirmBlocks', 'colorValue',
  ]) {
    b.writeln('    required this.$f,');
  }
  b.writeln('  });');
  b.writeln();
  b.writeln('  bool get isWalletTier => tier == \'wallet\';');
  b.writeln('}');
  b.writeln();

  // kChains in yaml order.
  b.writeln('const List<ChainEntry> kChains = [');
  for (final c in chains) {
    final fields = [
      "key: '${_dartStr(c['key']!)}'",
      "ticker: '${_dartStr(c['ticker']!)}'",
      "name: '${_dartStr(c['name']!)}'",
      "family: '${_dartStr(c['family']!)}'",
      "rpc: '${_dartStr(c['rpc']!)}'",
      "gasToken: '${_dartStr(c['gasToken']!)}'",
      "tier: '${_dartStr(c['tier']!)}'",
      "icon: '${_dartStr(c['icon']!)}'",
      'chainId: ${c['chainId']}',
      'confirmBlocks: ${c['confirmBlocks']}',
      'colorValue: 0x${_parseColor(c['color']!).toRadixString(16).padLeft(6, '0').toUpperCase()}',
    ];
    b.writeln('  ChainEntry(${fields.join(', ')}),');
  }
  b.writeln('];');
  b.writeln();
  b.writeln('final Map<String, ChainEntry> kChainByKey = {for (final c in kChains) c.key: c};');
  b.writeln();

  void emitMap(String name, String type, String Function(Map<String, String>) valueFor) {
    b.writeln('const Map<String, $type> $name = {');
    for (final c in chains) {
      b.writeln("  '${_dartStr(c['key']!)}': ${valueFor(c)},");
    }
    b.writeln('};');
    b.writeln();
  }

  emitMap('kChainIds', 'int', (c) => c['chainId']!);
  emitMap('kChainRpcs', 'String', (c) => "'${_dartStr(c['rpc']!)}'");
  emitMap('kChainNames', 'String', (c) => "'${_dartStr(c['name']!)}'");
  emitMap('kChainColors', 'int',
      (c) => '0x${_parseColor(c['color']!).toRadixString(16).padLeft(6, '0').toUpperCase()}');

  b.writeln('const Set<String> kWalletTierKeys = {');
  for (final c in chains.where((c) => c['tier'] == 'wallet')) {
    b.writeln("  '${_dartStr(c['key']!)}',");
  }
  b.writeln('};');
  return b.toString();
}

/// Escapes a string for a single-quoted Dart literal.
String _dartStr(String s) =>
    s.replaceAll('\\', r'\\').replaceAll("'", r"\'");

// ── Diagnostics ───────────────────────────────────────────────────────

void _printDiffSummary(String existing, String expected) {
  final a = existing.split('\n');
  final e = expected.split('\n');
  stdout.writeln('existing lines: ${a.length}, regenerated lines: ${e.length}');
  var shown = 0;
  final n = a.length < e.length ? a.length : e.length;
  for (var i = 0; i < n && shown < 10; i++) {
    if (a[i] != e[i]) {
      stdout.writeln('first difference at line ${i + 1}:');
      stdout.writeln('  - existing:   ${a[i]}');
      stdout.writeln('  + regenerated: ${e[i]}');
      shown++;
    }
  }
  if (shown == 0) {
    stdout.writeln('Lines agree up to the shorter length; files differ only in tail/length.');
  }
}
