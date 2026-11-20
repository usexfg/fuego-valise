// Network catalog generator.
//
// Protocol identity is the pinned fuego-suite SwapPair uint8. This tool
// parses that pin and joins it to chains.yaml. It does not invent ids.
//
//   dart run tool/gen_networks.dart
//   dart run tool/gen_networks.dart --check
//
// Outputs:
//   lib/models/network_catalog.g.dart
//   rust-fuego-wallet/fuego-sdk/fuego-sdk/src/swap_pair_generated.rs
//   docs/networks.backlog.md

import 'dart:io';

const suiteEnum = 'fuego-suite/src/SwapDaemon/SwapTypes.h';
const suiteStrings = 'fuego-suite/src/SwapDaemon/SwapTypes.cpp';
const suiteTimelock = 'fuego-suite/src/SwapDaemon/SwapTimelock.cpp';
const suiteOracle = 'fuego-suite/src/SwapDaemon/PriceOracle.cpp';
const suiteDaemon = 'fuego-suite/src/SwapDaemon/SwapDaemon.cpp';
const yamlPath = 'chains.yaml';

const dartOut = 'lib/models/network_catalog.g.dart';
const rustOut =
    'rust-fuego-wallet/fuego-sdk/fuego-sdk/src/swap_pair_generated.rs';
const backlogOut = 'docs/networks.backlog.md';

const activations = {
  'ready',
  'needs_wallet_wiring',
  'staged_in_suite',
  'wallet_only',
};
const families = {'evm', 'utxo', 'cryptonote', 'sol', 'other'};

/// Serde-stable names for the original Rust enum. Do not rename these.
const rustNameOverride = {
  'SOL': 'XfgSol',
  'ETH': 'XfgEth',
  'XMR': 'XfgXmr',
  'BCH': 'XfgBch',
  'ARB': 'XfgArb',
  'BASE': 'XfgBase',
  'KMD_SPV': 'XfgKmd',
  'BNB': 'XfgBnb',
  'DCR': 'XfgDcr',
  'BTC': 'XfgBtc',
  'LTC': 'XfgLtc',
  'POLYGON': 'XfgPoly',
};

const chainTypeByWire = {
  'SOL': 'Solana',
  'ETH': 'Ethereum',
  'XMR': 'Monero',
  'BCH': 'BitcoinCash',
  'ARB': 'Arbitrum',
  'BASE': 'Base',
  'KMD_SPV': 'Komodo',
  'BNB': 'Bnb',
  'DCR': 'Decred',
  'BTC': 'Bitcoin',
  'LTC': 'Litecoin',
  'POLYGON': 'Polygon',
};

class PinPair {
  PinPair({
    required this.enumName,
    required this.id,
    required this.wireName,
    required this.aliases,
    required this.msPerBlock,
    required this.divisor,
    required this.suiteStatus,
  });

  final String enumName;
  final int id;
  final String wireName;
  final List<String> aliases;
  final int msPerBlock;
  final String divisor;
  final String suiteStatus; // registers | staged
}

class Overlay {
  Overlay(this.fields);
  final Map<String, String> fields;
  String get key => fields['key']!;
  String get ticker => fields['ticker']!;
  String get name => fields['name']!;
  String get family => fields['family']!;
  String get activation => fields['activation']!;
  String? get swapPairId => fields['swap_pair_id'];
  String? get enumName => fields['enum_name'];
  String get note => fields['note'] ?? '';
}

void main(List<String> args) {
  final check = args.contains('--check');
  final pin = loadPin();
  final overlays = loadOverlays();
  final rows = join(pin, overlays);
  final dart = dartFormat(renderDart(rows));
  final rust = renderRust(rows);
  final backlog = renderBacklog(rows, pinSha());

  if (check) {
    _check(dartOut, dart);
    _check(rustOut, rust);
    _check(backlogOut, backlog);
    stdout.writeln(
      'OK: network catalog matches the pin '
      '(${rows.where((r) => r.swapPairId != null).length} pair ids, '
      '${rows.where((r) => r.activation == 'ready').length} ready).',
    );
    return;
  }

  File(dartOut).writeAsStringSync(dart);
  File(rustOut).writeAsStringSync(rust);
  File(backlogOut).parent.createSync(recursive: true);
  File(backlogOut).writeAsStringSync(backlog);
  stdout.writeln('Wrote $dartOut, $rustOut, $backlogOut.');
}

void _check(String path, String expected) {
  final existing = File(path).existsSync() ? File(path).readAsStringSync() : '';
  if (existing == expected) return;
  stderr.writeln('DRIFT: $path');
  stderr.writeln('Run: dart run tool/gen_networks.dart');
  exit(1);
}

// ── Pin ───────────────────────────────────────────────────────────────

List<PinPair> loadPin() {
  final header = File(suiteEnum).readAsStringSync();
  final strings = File(suiteStrings).readAsStringSync();
  final timelock = File(suiteTimelock).readAsStringSync();
  final oracle = File(suiteOracle).readAsStringSync();
  final daemon = File(suiteDaemon).readAsStringSync();

  final enumBody = _extractEnum(header);
  final arms = <String, int>{};
  for (final m in RegExp(r'(\w+)\s*=\s*(\d+)').allMatches(enumBody)) {
    final name = m.group(1)!;
    final id = int.parse(m.group(2)!);
    if (arms.containsKey(name)) {
      throw StateError('Duplicate SwapPair arm $name');
    }
    if (arms.containsValue(id)) {
      throw StateError('Duplicate SwapPair id $id');
    }
    arms[name] = id;
  }
  if (arms.isEmpty) throw StateError('No SwapPair arms in $suiteEnum');

  final wire = _caseStrings(_functionBody(strings, 'swapPairToString'));
  final aliases = _fromStringAliases(
    _functionBody(strings, 'swapPairFromString'),
  );
  final blocks = _caseInts(_functionBody(timelock, 'msPerBlock'));
  final divisors = _caseExprs(_functionBody(oracle, 'ctrDivisor'));

  final pairs = <PinPair>[];
  final sorted = arms.entries.toList()
    ..sort((a, b) => a.value.compareTo(b.value));
  for (final arm in sorted) {
    final name = arm.key;
    final missing = <String>[];
    if (!wire.containsKey(name)) missing.add('swapPairToString');
    if (!blocks.containsKey(name)) missing.add('msPerBlock');
    if (!divisors.containsKey(name)) missing.add('ctrDivisor');
    final registered = daemon.contains('registerChain(SwapPair::$name');
    final staged = _stagedMention(daemon, wire[name]);
    if (!registered && !staged) {
      missing.add('registerChain or staged refusal in SwapDaemon.cpp');
    }
    if (missing.isNotEmpty) {
      throw StateError('SwapPair::$name is missing: ${missing.join(', ')}');
    }
    pairs.add(
      PinPair(
        enumName: name,
        id: arm.value,
        wireName: wire[name]!,
        aliases: aliases[name] ?? const [],
        msPerBlock: blocks[name]!,
        divisor: divisors[name]!,
        suiteStatus: registered ? 'registers' : 'staged',
      ),
    );
  }
  return pairs;
}

String _extractEnum(String header) {
  final start = header.indexOf('enum class SwapPair');
  if (start < 0) throw StateError('SwapPair enum not found');
  final brace = header.indexOf('{', start);
  final end = header.indexOf('};', brace);
  if (brace < 0 || end < 0) throw StateError('SwapPair enum is not closed');
  return header.substring(brace + 1, end);
}

String _functionBody(String src, String name) {
  final sig = RegExp('$name\\s*\\(');
  final m = sig.firstMatch(src);
  if (m == null) throw StateError('function $name not found');
  final brace = src.indexOf('{', m.end);
  if (brace < 0) throw StateError('function $name has no body');
  var depth = 0;
  for (var i = brace; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) return src.substring(brace + 1, i);
    }
  }
  throw StateError('function $name body does not close');
}

Map<String, String> _caseStrings(String body) {
  final out = <String, String>{};
  final re = RegExp(r'case\s+SwapPair::(\w+)\s*:\s*return\s+"([^"]+)"');
  for (final m in re.allMatches(body)) {
    out[m.group(1)!] = m.group(2)!;
  }
  return out;
}

Map<String, int> _caseInts(String body) {
  final out = <String, int>{};
  final re = RegExp(r'case\s+SwapPair::(\w+)\s*:\s*return\s+(\d+)\s*;');
  for (final m in re.allMatches(body)) {
    out[m.group(1)!] = int.parse(m.group(2)!);
  }
  return out;
}

Map<String, String> _caseExprs(String body) {
  final out = <String, String>{};
  final re = RegExp(r'case\s+SwapPair::(\w+)\s*:\s*return\s+([^;]+);');
  for (final m in re.allMatches(body)) {
    out[m.group(1)!] = m.group(2)!.trim();
  }
  return out;
}

Map<String, List<String>> _fromStringAliases(String body) {
  final out = <String, List<String>>{};
  final re = RegExp(
    r'iequal\(\s*p\s*,\s*"([^"]+)"\s*,\s*n\s*\)[\s\S]*?SwapPair::(\w+)',
  );
  for (final m in re.allMatches(body)) {
    out.putIfAbsent(m.group(2)!, () => []).add(m.group(1)!);
  }
  return out;
}

bool _stagedMention(String daemon, String? wireName) {
  if (wireName == null) return false;
  const needle = 'not yet registered';
  var start = 0;
  final word = RegExp('\\b${RegExp.escape(wireName)}\\b');
  while (true) {
    final i = daemon.indexOf(needle, start);
    if (i < 0) return false;
    final from = i - 500 < 0 ? 0 : i - 500;
    if (word.hasMatch(daemon.substring(from, i))) return true;
    start = i + needle.length;
  }
}

// ── YAML ──────────────────────────────────────────────────────────────

List<Overlay> loadOverlays() {
  final src = File(yamlPath).readAsStringSync();
  final sections = _parseSections(src);
  final rows = <Overlay>[];
  for (final section in ['chains', 'networks']) {
    for (final raw in sections[section] ?? const <Map<String, String>>[]) {
      rows.add(Overlay(raw));
    }
  }
  if (rows.isEmpty) throw StateError('$yamlPath has no chain or network rows');
  return rows;
}

Map<String, List<Map<String, String>>> _parseSections(String src) {
  final sections = <String, List<Map<String, String>>>{};
  String? section;
  Map<String, String>? current;
  for (final line in src.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final top = !line.startsWith(' ') && !line.startsWith('\t');
    if (top && trimmed.endsWith(':') && !trimmed.startsWith('-')) {
      section = trimmed.substring(0, trimmed.length - 1);
      sections.putIfAbsent(section, () => []);
      current = null;
      continue;
    }
    if (section == null) continue;
    if (trimmed.startsWith('- ')) {
      current = {};
      sections[section]!.add(current);
      final inline = trimmed.substring(2).trim();
      if (inline.isNotEmpty) _addField(current, inline);
      continue;
    }
    if (current != null && trimmed.contains(':')) _addField(current, trimmed);
  }
  return sections;
}

void _addField(Map<String, String> entry, String pair) {
  final colon = pair.indexOf(':');
  if (colon <= 0) throw FormatException('Malformed line: "$pair"');
  entry[pair.substring(0, colon).trim()] = _cleanValue(
    pair.substring(colon + 1).trim(),
  );
}

String _cleanValue(String raw) {
  if (raw.length >= 2 && (raw.startsWith("'") || raw.startsWith('"'))) {
    final quote = raw[0];
    final end = raw.indexOf(quote, 1);
    if (end != -1) return raw.substring(1, end);
    throw FormatException('Unterminated quoted value: "$raw"');
  }
  final idx = raw.indexOf(' #');
  return (idx == -1 ? raw : raw.substring(0, idx)).trim();
}

// ── Join ──────────────────────────────────────────────────────────────

class Row {
  Row({required this.overlay, required this.pin});

  final Overlay overlay;
  final PinPair? pin;

  int? get swapPairId => pin?.id;
  String get activation => overlay.activation;
  String get ticker => overlay.ticker;
  String get key => overlay.key;
  String get family => overlay.family;
  String? get enumName => overlay.enumName;
  bool get cppAcceptsTicker {
    final p = pin;
    if (p == null) return false;
    return p.aliases.map((a) => a.toUpperCase()).contains(ticker.toUpperCase());
  }
}

List<Row> join(List<PinPair> pin, List<Overlay> overlays) {
  final byId = <int, Overlay>{};
  final tickers = <String>{};
  final keys = <String>{};
  final enumNames = <String>{};
  for (final o in overlays) {
    if (!keys.add(o.key)) throw StateError('Duplicate network key ${o.key}');
    if (!tickers.add(o.ticker)) {
      throw StateError('Duplicate display ticker ${o.ticker}');
    }
    if (!families.contains(o.family)) {
      throw StateError('${o.key}: unknown family ${o.family}');
    }
    if (!activations.contains(o.activation)) {
      throw StateError('${o.key}: unknown activation ${o.activation}');
    }
    final idRaw = o.swapPairId;
    if (idRaw == null || idRaw.isEmpty) {
      if (o.activation != 'wallet_only') {
        throw StateError(
          '${o.key}: activation ${o.activation} requires swap_pair_id',
        );
      }
      continue;
    }
    final id = int.tryParse(idRaw);
    if (id == null) {
      throw StateError('${o.key}: swap_pair_id is not an int');
    }
    if (byId.containsKey(id)) {
      throw StateError(
        'Duplicate swap_pair_id $id (${byId[id]!.key} and ${o.key})',
      );
    }
    byId[id] = o;
  }

  final pinById = {for (final p in pin) p.id: p};
  for (final id in byId.keys) {
    if (!pinById.containsKey(id)) {
      throw StateError('swap_pair_id $id is not in the pinned SwapPair enum');
    }
  }
  for (final p in pin) {
    if (!byId.containsKey(p.id)) {
      throw StateError(
        'Pinned SwapPair::${p.enumName} (${p.id}) has no chains.yaml row',
      );
    }
    final o = byId[p.id]!;
    if (o.activation == 'ready' && p.suiteStatus != 'registers') {
      throw StateError(
        '${o.key}: activation ready but suite ${p.suiteStatus} '
        '(SwapPair::${p.enumName})',
      );
    }
    if (o.activation == 'staged_in_suite' && p.suiteStatus != 'staged') {
      throw StateError(
        '${o.key}: activation staged_in_suite but suite ${p.suiteStatus}',
      );
    }
    if (o.activation == 'needs_wallet_wiring' &&
        p.suiteStatus != 'registers') {
      throw StateError(
        '${o.key}: needs_wallet_wiring but suite will not register ${p.enumName}',
      );
    }
    if (o.activation == 'wallet_only') {
      throw StateError('${o.key}: wallet_only row must not carry swap_pair_id');
    }
    if (o.activation == 'ready') {
      final name = o.enumName;
      if (name == null || !RegExp(r'^[a-z][A-Za-z0-9]*$').hasMatch(name)) {
        throw StateError('${o.key}: ready row needs a dart enum_name');
      }
      if (!enumNames.add(name)) {
        throw StateError('Duplicate enum_name $name');
      }
    }
  }

  final rows = <Row>[];
  for (final p in pin) {
    rows.add(Row(overlay: byId[p.id]!, pin: p));
  }
  for (final o in overlays) {
    if (o.swapPairId == null || o.swapPairId!.isEmpty) {
      rows.add(Row(overlay: o, pin: null));
    }
  }
  return rows;
}

// ── Render ────────────────────────────────────────────────────────────

String renderDart(List<Row> rows) {
  final b = StringBuffer()
    ..writeln('// GENERATED FILE — tool/gen_networks.dart. DO NOT EDIT.')
    ..writeln('//')
    ..writeln('// Pair identity is the pinned fuego-suite SwapPair uint8.')
    ..writeln('// SwapPairSdk is only the activation: ready set. Unknown ids')
    ..writeln('// are not ETH. Wallet-only and staged rows live on NetworkRow.')
    ..writeln()
    ..writeln('class NetworkRow {')
    ..writeln('  final String key;')
    ..writeln('  final String ticker;')
    ..writeln('  final String name;')
    ..writeln('  final String family;')
    ..writeln('  final int? swapPairId;')
    ..writeln('  final String wireName;')
    ..writeln('  final String activation;')
    ..writeln("  /// 'registers' or 'staged' when this row has a SwapPair id.")
    ..writeln('  final String suiteStatus;')
    ..writeln('  final bool cppAcceptsTicker;')
    ..writeln('  final String ctrDivisor;')
    ..writeln('  final int? msPerBlock;')
    ..writeln('  final String note;')
    ..writeln('  final String? enumName;')
    ..writeln()
    ..writeln('  const NetworkRow({')
    ..writeln('    required this.key,')
    ..writeln('    required this.ticker,')
    ..writeln('    required this.name,')
    ..writeln('    required this.family,')
    ..writeln('    required this.swapPairId,')
    ..writeln('    required this.wireName,')
    ..writeln('    required this.activation,')
    ..writeln('    required this.suiteStatus,')
    ..writeln('    required this.cppAcceptsTicker,')
    ..writeln('    required this.ctrDivisor,')
    ..writeln('    required this.msPerBlock,')
    ..writeln('    required this.note,')
    ..writeln('    required this.enumName,')
    ..writeln('  });')
    ..writeln()
    ..writeln("  bool get isReady => activation == 'ready';")
    ..writeln('}')
    ..writeln()
    ..writeln('const List<NetworkRow> kNetworkCatalog = [');
  for (final r in rows) {
    final p = r.pin;
    b.writeln('  NetworkRow(');
    b.writeln("    key: '${_dart(r.key)}',");
    b.writeln("    ticker: '${_dart(r.ticker)}',");
    b.writeln("    name: '${_dart(r.overlay.name)}',");
    b.writeln("    family: '${_dart(r.family)}',");
    b.writeln('    swapPairId: ${p == null ? 'null' : p.id},');
    b.writeln("    wireName: '${_dart(p?.wireName ?? '')}',");
    b.writeln("    activation: '${_dart(r.activation)}',");
    b.writeln("    suiteStatus: '${_dart(p?.suiteStatus ?? '')}',");
    b.writeln('    cppAcceptsTicker: ${r.cppAcceptsTicker},');
    b.writeln("    ctrDivisor: '${_dart(p?.divisor ?? '')}',");
    b.writeln('    msPerBlock: ${p == null ? 'null' : p.msPerBlock},');
    b.writeln("    note: '${_dart(r.overlay.note)}',");
    b.writeln(
      "    enumName: ${r.enumName == null ? 'null' : "'${_dart(r.enumName!)}'"},",
    );
    b.writeln('  ),');
  }
  b.writeln('];');

  final ready = rows.where((r) => r.activation == 'ready').toList()
    ..sort((a, b) => a.swapPairId!.compareTo(b.swapPairId!));

  final buf = StringBuffer()
    ..write(b.toString())
    ..writeln()
    ..writeln('const List<NetworkRow> kReadyNetworks = [');
  for (final r in ready) {
    final p = r.pin!;
    buf.writeln('  NetworkRow(');
    buf.writeln("    key: '${_dart(r.key)}',");
    buf.writeln("    ticker: '${_dart(r.ticker)}',");
    buf.writeln("    name: '${_dart(r.overlay.name)}',");
    buf.writeln("    family: '${_dart(r.family)}',");
    buf.writeln('    swapPairId: ${p.id},');
    buf.writeln("    wireName: '${_dart(p.wireName)}',");
    buf.writeln("    activation: 'ready',");
    buf.writeln("    suiteStatus: '${_dart(p.suiteStatus)}',");
    buf.writeln('    cppAcceptsTicker: ${r.cppAcceptsTicker},');
    buf.writeln("    ctrDivisor: '${_dart(p.divisor)}',");
    buf.writeln('    msPerBlock: ${p.msPerBlock},');
    buf.writeln("    note: '${_dart(r.overlay.note)}',");
    buf.writeln("    enumName: '${_dart(r.enumName!)}',");
    buf.writeln('  ),');
  }
  buf
    ..writeln('];')
    ..writeln()
    ..writeln('/// Trader-facing set: unlocks partner SwapPair rows.')
    ..writeln('/// Wire calls send [NetworkRow.swapPairId] as u8.')
    ..writeln('enum SwapPairSdk {');
  for (var i = 0; i < ready.length; i++) {
    final r = ready[i];
    final tail = i == ready.length - 1 ? ';' : ',';
    buf.writeln(
      "  ${r.enumName}(${r.swapPairId}, '${_dart(r.ticker)}', "
      "'XFG/${_dart(r.ticker)}')$tail",
    );
  }
  buf
    ..writeln()
    ..writeln('  final int id;')
    ..writeln('  final String ticker;')
    ..writeln('  final String displayName;')
    ..writeln('  const SwapPairSdk(this.id, this.ticker, this.displayName);')
    ..writeln()
    ..writeln('  static SwapPairSdk? tryFromId(int id) {')
    ..writeln('    for (final pair in values) {')
    ..writeln('      if (pair.id == id) return pair;')
    ..writeln('    }')
    ..writeln('    return null;')
    ..writeln('  }')
    ..writeln()
    ..writeln('  /// Throws. An unknown id is not ETH.')
    ..writeln('  static SwapPairSdk fromId(int id) {')
    ..writeln('    final pair = tryFromId(id);')
    ..writeln('    if (pair == null) {')
    ..writeln("      throw ArgumentError('unknown swap pair id \$id');")
    ..writeln('    }')
    ..writeln('    return pair;')
    ..writeln('  }')
    ..writeln()
    ..writeln('  static NetworkRow? rowFor(SwapPairSdk pair) {')
    ..writeln('    for (final row in kReadyNetworks) {')
    ..writeln('      if (row.swapPairId == pair.id) return row;')
    ..writeln('    }')
    ..writeln('    return null;')
    ..writeln('  }')
    ..writeln('}')
    ..writeln()
    ..writeln('NetworkRow? networkBySwapPairId(int id) {')
    ..writeln('  for (final row in kNetworkCatalog) {')
    ..writeln('    if (row.swapPairId == id) return row;')
    ..writeln('  }')
    ..writeln('  return null;')
    ..writeln('}')
    ..writeln()
    ..writeln('const Set<String> kReadyEvmKeys = {');
  for (final r in ready.where((r) => r.family == 'evm')) {
    buf.writeln("  '${_dart(r.key)}',");
  }
  buf.writeln('};');
  return buf.toString();
}

String renderRust(List<Row> rows) {
  final pairs = rows.where((r) => r.pin != null).toList()
    ..sort((a, b) => a.swapPairId!.compareTo(b.swapPairId!));
  final b = StringBuffer()
    ..writeln('// GENERATED FILE — tool/gen_networks.dart. DO NOT EDIT.')
    ..writeln(
      '// Included from types.rs. Discriminants are the suite SwapPair uint8.',
    )
    ..writeln(
      '// as_str() is the display label (XFG/TICKER). wire_name() is what',
    )
    ..writeln(
      '// swapPairToString returns. Do not send a display ticker to the daemon.',
    )
    ..writeln()
    ..writeln(
      '#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]',
    )
    ..writeln('#[repr(u8)]')
    ..writeln('pub enum SwapPair {');
  for (final r in pairs) {
    final p = r.pin!;
    b.writeln('    ${_rustName(p)} = ${p.id},');
  }
  b.writeln('}');
  b.writeln();
  b.writeln('impl SwapPair {');
  b.writeln('    pub fn wire_name(&self) -> &\'static str {');
  b.writeln('        match self {');
  for (final r in pairs) {
    final p = r.pin!;
    b.writeln('            Self::${_rustName(p)} => "${p.wireName}",');
  }
  b.writeln('        }');
  b.writeln('    }');
  b.writeln();
  b.writeln('    pub fn ticker(&self) -> &\'static str {');
  b.writeln('        match self {');
  for (final r in pairs) {
    final p = r.pin!;
    b.writeln('            Self::${_rustName(p)} => "${r.ticker}",');
  }
  b.writeln('        }');
  b.writeln('    }');
  b.writeln();
  b.writeln('    /// Display label. Not the wire string.');
  b.writeln('    pub fn as_str(&self) -> &\'static str {');
  b.writeln('        match self {');
  for (final r in pairs) {
    final p = r.pin!;
    b.writeln('            Self::${_rustName(p)} => "XFG/${r.ticker}",');
  }
  b.writeln('        }');
  b.writeln('    }');
  b.writeln();
  b.writeln('    pub fn from_id(id: u8) -> Option<Self> {');
  b.writeln('        match id {');
  for (final r in pairs) {
    final p = r.pin!;
    b.writeln('            ${p.id} => Some(Self::${_rustName(p)}),');
  }
  b.writeln('            _ => None,');
  b.writeln('        }');
  b.writeln('    }');
  b.writeln();
  b.writeln('    pub fn from_id_str(ticker: &str) -> Option<Self> {');
  b.writeln('        match ticker.to_uppercase().as_str() {');
  for (final r in pairs) {
    final p = r.pin!;
    final names = <String>{
      r.ticker.toUpperCase(),
      p.wireName.toUpperCase(),
      ...p.aliases.map((a) => a.toUpperCase()),
    };
    final arms = names.map((n) => '"$n"').join(' | ');
    b.writeln('            $arms => Some(Self::${_rustName(p)}),');
  }
  b.writeln('            _ => None,');
  b.writeln('        }');
  b.writeln('    }');
  b.writeln();
  b.writeln('    /// SPV ChainType, only where that enum already has an arm.');
  b.writeln(
    '    /// None is not a new chain id. Do not extend ChainType here.',
  );
  b.writeln('    pub fn chain_type(&self) -> Option<crate::chain::ChainType> {');
  b.writeln('        match self {');
  for (final r in pairs) {
    final p = r.pin!;
    final ct = chainTypeByWire[p.wireName];
    if (ct == null) continue;
    b.writeln(
      '            Self::${_rustName(p)} => Some(crate::chain::ChainType::$ct),',
    );
  }
  b.writeln('            _ => None,');
  b.writeln('        }');
  b.writeln('    }');
  b.writeln();
  b.writeln('    pub fn all() -> &\'static [SwapPair] {');
  b.writeln('        &[');
  for (final r in pairs) {
    b.writeln('            Self::${_rustName(r.pin!)},');
  }
  b.writeln('        ]');
  b.writeln('    }');
  b.writeln('}');
  b.writeln();
  b.writeln('impl std::fmt::Display for SwapPair {');
  b.writeln(
    '    fn fmt(&self, f: &mut std::fmt::Formatter<\'_>) -> std::fmt::Result {',
  );
  b.writeln('        write!(f, "{}", self.as_str())');
  b.writeln('    }');
  b.writeln('}');
  b.writeln();
  b.writeln('#[cfg(test)]');
  b.writeln('mod swap_pair_generated_tests {');
  b.writeln('    use super::SwapPair;');
  b.writeln();
  b.writeln('    #[test]');
  b.writeln('    fn swap_pair_ids_round_trip() {');
  b.writeln('        for id in 0u8..=28 {');
  b.writeln('            let pair = SwapPair::from_id(id).expect("pin id");');
  b.writeln('            assert_eq!(pair as u8, id);');
  b.writeln(
    '            assert_eq!(SwapPair::from_id_str(pair.ticker()), Some(pair));',
  );
  b.writeln(
    '            assert_eq!(SwapPair::from_id_str(pair.wire_name()), Some(pair));',
  );
  b.writeln('        }');
  b.writeln('        assert!(SwapPair::from_id(29).is_none());');
  b.writeln('    }');
  b.writeln('}');
  return b.toString();
}

String _rustName(PinPair p) {
  final over = rustNameOverride[p.wireName];
  if (over != null) return over;
  final lower = p.wireName.toLowerCase();
  return 'Xfg${lower[0].toUpperCase()}${lower.substring(1)}';
}

String renderBacklog(List<Row> rows, String sha) {
  final b = StringBuffer()
    ..writeln('# Network backlog')
    ..writeln()
    ..writeln(
      'Generated by `tool/gen_networks.dart` from the pinned fuego-suite',
    )
    ..writeln(
      '`SwapPair` enum and `chains.yaml`. Do not edit. Do not add a pair',
    )
    ..writeln('id in Dart or Rust by hand.')
    ..writeln()
    ..writeln('Suite pin: `$sha`')
    ..writeln()
    ..writeln(
      'DeXFG and peer swap show `activation: ready` only. The other rows',
    )
    ..writeln('are not tradable until a later change flips that field, and the')
    ..writeln(
      'generator rejects `ready` when the pin will not register the client.',
    )
    ..writeln()
    ..writeln('## Pin')
    ..writeln()
    ..writeln(
      '| ID | Wire | Ticker | Activation | Suite | Divisor | Block ms |',
    )
    ..writeln(
      '|----|------|--------|------------|-------|---------|----------|',
    );
  for (final r in rows.where((r) => r.pin != null)) {
    final p = r.pin!;
    b.writeln(
      '| ${p.id} | ${p.wireName} | ${r.ticker} | ${r.activation} | '
      '${p.suiteStatus} | `${p.divisor}` | ${p.msPerBlock} |',
    );
  }

  void section(String title, String activation, String intro) {
    final items = rows.where((r) => r.activation == activation).toList();
    b
      ..writeln()
      ..writeln('## $title')
      ..writeln()
      ..writeln(intro)
      ..writeln();
    if (items.isEmpty) {
      b.writeln('None.');
      return;
    }
    for (final r in items) {
      final id = r.swapPairId == null ? 'no id' : 'id ${r.swapPairId}';
      final note = r.overlay.note.isEmpty ? '' : ' ${r.overlay.note}';
      b.writeln('- **${r.ticker}** ($id, `${r.key}`).$note');
    }
  }

  section(
    'Needs Valise wiring',
    'needs_wallet_wiring',
    'The pin will `registerChain` when a host is set. Valise has no settings path. Do not mark these `ready` until that path exists.',
  );
  section(
    'Staged in suite',
    'staged_in_suite',
    'The id is reserved. `registerChain` is refused. A Valise enum arm cannot activate these.',
  );
  section(
    'Wallet only',
    'wallet_only',
    'No `SwapPair` id. ERC-20 / account networks. Assigning an id here is a protocol change and belongs in fuego-suite first, after id 28.',
  );

  final rejected = rows
      .where((r) => r.pin != null && !r.cppAcceptsTicker)
      .toList();
  b
    ..writeln()
    ..writeln('## Display tickers the C++ parser does not accept')
    ..writeln()
    ..writeln(
      'Send the uint8. Do not send these strings to `swapPairFromString`.',
    )
    ..writeln();
  if (rejected.isEmpty) {
    b.writeln('None.');
  } else {
    for (final r in rejected) {
      b.writeln(
        '- `${r.ticker}` is wire `${r.pin!.wireName}` '
        '(id ${r.pin!.id}). Accepted strings: ${r.pin!.aliases.join(', ')}.',
      );
    }
  }
  b
    ..writeln()
    ..writeln('## Not this pass')
    ..writeln()
    ..writeln(
      'Do not deploy HTLCs, clone `OptimismChainClient`, or add settings screens from this file. It is the list of what is left.',
    );
  return b.toString();
}

String pinSha() {
  final res = Process.runSync('git', ['rev-parse', 'HEAD:fuego-suite']);
  if (res.exitCode != 0) return 'unknown';
  return (res.stdout as String).trim();
}

String _dart(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

String dartFormat(String src) {
  final tmp = File(
    '${Directory.systemTemp.path}/gen_networks_fmt_${pid}_'
    '${DateTime.now().microsecondsSinceEpoch}.dart',
  );
  try {
    tmp.writeAsStringSync(src);
    final res = Process.runSync(
      Platform.environment['DART_FORMATTER'] ?? 'dart',
      ['format', tmp.path],
    );
    if (res.exitCode != 0) {
      throw StateError('dart format failed: ${res.stderr}');
    }
    return tmp.readAsStringSync();
  } finally {
    if (tmp.existsSync()) tmp.deleteSync();
  }
}
