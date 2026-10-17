import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:web3dart/web3dart.dart';
import '../models/chain_registry.g.dart';
import '../models/erc20_token.dart';

/// ERC20 service for EVM chains (33 chains at 2026-08-25).
///
/// Read path uses raw `eth_call` via HTTP to avoid web3dart ABI quirks
/// and to keep raw selector control (USDT returns non-standard bool).
/// Write path uses web3dart's signed `sendTransaction`.
///
/// All amounts are base units (BigInt). Use [Erc20Amount] helpers for
/// display <-> base conversion.
class Erc20Service {
  final Map<String, Web3Client> _clients = {};
  final Map<String, String> _rpcUrls = {};
  final http.Client _http = http.Client();

  /// Canonical per-chain defaults — generated from chains.yaml via
  /// tool/gen_chains.dart (single source of truth).
  static const Map<String, String> _defaultRpcs = kChainRpcs;
  static const Map<String, int> _chainIds = kChainIds;

  Erc20Service({Map<String, String>? rpcUrls}) {
    final src = rpcUrls ?? _defaultRpcs;
    for (final e in src.entries) {
      final k = e.key.toLowerCase();
      _rpcUrls[k] = e.value;
      _clients[k] = Web3Client(e.value, http.Client());
    }
    for (final k in _defaultRpcs.keys) {
      if (!_clients.containsKey(k)) {
        _rpcUrls[k] = _defaultRpcs[k]!;
        _clients[k] = Web3Client(_defaultRpcs[k]!, http.Client());
      }
    }
  }

  Web3Client _clientFor(String chainKey) {
    final k = chainKey.toLowerCase();
    final c = _clients[k];
    if (c == null) throw ArgumentError('Unknown EVM chain: $chainKey');
    return c;
  }

  String rpcUrlFor(String chainKey) =>
      _rpcUrls[chainKey.toLowerCase()] ??
      _defaultRpcs[chainKey.toLowerCase()] ??
      '';

  int chainIdFor(String chainKey) => _chainIds[chainKey.toLowerCase()] ?? 1;

  void setRpcUrl(String chainKey, String rpcUrl) {
    final k = chainKey.toLowerCase();
    final url = rpcUrl.isEmpty ? (_defaultRpcs[k] ?? rpcUrl) : rpcUrl;
    _clients[k]?.dispose();
    _rpcUrls[k] = url;
    _clients[k] = Web3Client(url, http.Client());
  }

  // ── Read: eth_call ───────────────────────────────────────────────

  Future<BigInt> balanceOf({
    required String chainKey,
    required String tokenAddress,
    required String holderAddress,
  }) async {
    _assertAddress(tokenAddress, 'tokenAddress');
    _assertAddress(holderAddress, 'holderAddress');
    final data = _encodeBalanceOf(EthereumAddress.fromHex(holderAddress));
    final hex = await _ethCall(
      chainKey: chainKey,
      to: tokenAddress,
      data: Uint8List.fromList(data),
    );
    return _hexToBigInt(hex);
  }

  Future<int> decimals({
    required String chainKey,
    required String tokenAddress,
  }) async {
    _assertAddress(tokenAddress, 'tokenAddress');
    final hex = await _ethCall(
      chainKey: chainKey,
      to: tokenAddress,
      data: Uint8List.fromList(_encodeDecimals()),
    );
    final v = _hexToBigInt(hex);
    // decimals() returns uint8 in 32 bytes — value fits in int.
    return v.toInt();
  }

  Future<String> symbol({
    required String chainKey,
    required String tokenAddress,
  }) async {
    _assertAddress(tokenAddress, 'tokenAddress');
    final hex = await _ethCall(
      chainKey: chainKey,
      to: tokenAddress,
      data: Uint8List.fromList(_encodeSymbol()),
    );
    return _decodeAbiStringHex(hex);
  }

  Future<String> name({
    required String chainKey,
    required String tokenAddress,
  }) async {
    _assertAddress(tokenAddress, 'tokenAddress');
    final hex = await _ethCall(
      chainKey: chainKey,
      to: tokenAddress,
      data: Uint8List.fromList(_encodeName()),
    );
    return _decodeAbiStringHex(hex);
  }

  Future<BigInt> allowance({
    required String chainKey,
    required String tokenAddress,
    required String owner,
    required String spender,
  }) async {
    _assertAddress(tokenAddress, 'tokenAddress');
    _assertAddress(owner, 'owner');
    _assertAddress(spender, 'spender');
    final data = _encodeAllowance(
      EthereumAddress.fromHex(owner),
      EthereumAddress.fromHex(spender),
    );
    final hex = await _ethCall(
      chainKey: chainKey,
      to: tokenAddress,
      data: Uint8List.fromList(data),
    );
    return _hexToBigInt(hex);
  }

  // ── Write: sendTransaction ───────────────────────────────────────

  Future<String> transfer({
    required String chainKey,
    required String privateKey,
    required String tokenAddress,
    required String toAddress,
    required BigInt amountBaseUnits,
  }) async {
    _assertAddress(tokenAddress, 'tokenAddress');
    _assertAddress(toAddress, 'toAddress');
    if (amountBaseUnits <= BigInt.zero) {
      throw ArgumentError('amount must be > 0');
    }
    final client = _clientFor(chainKey);
    final creds = EthPrivateKey.fromHex(_strip0x(privateKey));
    final token = EthereumAddress.fromHex(tokenAddress);
    final to = EthereumAddress.fromHex(toAddress);
    final data = _encodeTransfer(to, amountBaseUnits);
    return client.sendTransaction(
      creds,
      Transaction(to: token, data: Uint8List.fromList(data)),
      chainId: chainIdFor(chainKey),
    );
  }

  Future<String> approve({
    required String chainKey,
    required String privateKey,
    required String tokenAddress,
    required String spender,
    required BigInt amountBaseUnits,
  }) async {
    _assertAddress(tokenAddress, 'tokenAddress');
    _assertAddress(spender, 'spender');
    if (amountBaseUnits < BigInt.zero) {
      throw ArgumentError('amount must be >= 0');
    }
    final client = _clientFor(chainKey);
    final creds = EthPrivateKey.fromHex(_strip0x(privateKey));
    final token = EthereumAddress.fromHex(tokenAddress);
    final sp = EthereumAddress.fromHex(spender);
    final data = _encodeApprove(sp, amountBaseUnits);
    return client.sendTransaction(
      creds,
      Transaction(to: token, data: Uint8List.fromList(data)),
      chainId: chainIdFor(chainKey),
    );
  }

  // ── Token-object convenience ─────────────────────────────────────

  Future<BigInt> balanceOfToken({
    required Erc20Token token,
    required String holderAddress,
  }) => balanceOf(
    chainKey: token.chainKey,
    tokenAddress: token.address,
    holderAddress: holderAddress,
  );

  Future<double> balanceAsDouble({
    required Erc20Token token,
    required String holderAddress,
  }) async {
    final raw = await balanceOfToken(
      token: token,
      holderAddress: holderAddress,
    );
    int dec = token.decimals;
    try {
      dec = await decimals(
        chainKey: token.chainKey,
        tokenAddress: token.address,
      );
    } catch (_) {}
    final divisor = BigInt.from(10).pow(dec).toDouble();
    return divisor == 0 ? 0 : raw.toDouble() / divisor;
  }

  Future<String> transferToken({
    required Erc20Token token,
    required String privateKey,
    required String toAddress,
    required String amountDisplay,
  }) async {
    int dec = token.decimals;
    try {
      dec = await decimals(
        chainKey: token.chainKey,
        tokenAddress: token.address,
      );
    } catch (_) {}
    final baseUnits = Erc20Amount.toBaseUnits(amountDisplay, dec);
    if (baseUnits <= BigInt.zero) throw ArgumentError('amount must be > 0');
    return transfer(
      chainKey: token.chainKey,
      privateKey: privateKey,
      tokenAddress: token.address,
      toAddress: toAddress,
      amountBaseUnits: baseUnits,
    );
  }

  // ── Low-level eth_call ───────────────────────────────────────────

  Future<String> _ethCall({
    required String chainKey,
    required String to,
    required Uint8List data,
  }) async {
    final url = rpcUrlFor(chainKey);
    if (url.isEmpty) throw StateError('No RPC URL for $chainKey');
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'eth_call',
      'params': [
        {'to': to, 'data': '0x${_bytesToHex(data)}'},
        'latest',
      ],
    });
    final resp = await _http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: body,
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError(
        'eth_call $chainKey failed HTTP ${resp.statusCode}: ${resp.body}',
      );
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    if (json['error'] != null) {
      throw StateError('eth_call $chainKey error: ${json['error']}');
    }
    final result = json['result'] as String?;
    if (result == null) throw StateError('eth_call $chainKey missing result');
    return result;
  }

  // ── ABI encoders ─────────────────────────────────────────────────

  static List<int> _encodeBalanceOf(EthereumAddress holder) => [
    0x70,
    0xa0,
    0x82,
    0x31,
    ..._pad32Address(holder),
  ];

  static List<int> _encodeDecimals() => [0x31, 0x3c, 0xe5, 0x67];
  static List<int> _encodeSymbol() => [0x95, 0xd8, 0x9b, 0x41];
  static List<int> _encodeName() => [0x06, 0xfd, 0xde, 0x03];

  static List<int> _encodeAllowance(
    EthereumAddress owner,
    EthereumAddress spender,
  ) => [
    0xdd,
    0x62,
    0xed,
    0x3e,
    ..._pad32Address(owner),
    ..._pad32Address(spender),
  ];

  static List<int> _encodeTransfer(EthereumAddress to, BigInt amount) => [
    0xa9,
    0x05,
    0x9c,
    0xbb,
    ..._pad32Address(to),
    ..._pad32BigInt(amount),
  ];

  static List<int> _encodeApprove(EthereumAddress spender, BigInt amount) => [
    0x09,
    0x5e,
    0xa7,
    0xb3,
    ..._pad32Address(spender),
    ..._pad32BigInt(amount),
  ];

  static List<int> _pad32Address(EthereumAddress addr) {
    final b = addr.addressBytes;
    return List<int>.filled(32 - b.length, 0) + b;
  }

  static List<int> _pad32BigInt(BigInt v) {
    final hex = v.toRadixString(16).padLeft(64, '0');
    return _hexToBytes(hex);
  }

  static List<int> _hexToBytes(String hex) {
    final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
    final out = <int>[];
    for (var i = 0; i < clean.length; i += 2) {
      out.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  static String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String _strip0x(String s) => s.startsWith('0x') ? s.substring(2) : s;

  static void _assertAddress(String addr, String label) {
    if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(addr)) {
      throw ArgumentError('$label must be 0x 20-byte hex, got: $addr');
    }
  }

  static BigInt _hexToBigInt(String hex) {
    final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
    if (clean.isEmpty || clean == '0') return BigInt.zero;
    // Trim leading zeros; empty -> 0
    final trimmed = clean.replaceFirst(RegExp(r'^0+'), '');
    if (trimmed.isEmpty) return BigInt.zero;
    return BigInt.parse(trimmed, radix: 16);
  }

  // Hex ABI string: 0x + offset(32) + length(32) + data(padded)
  static String _decodeAbiStringHex(String hex) {
    final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
    if (clean.length < 128) {
      // Short string fallback: try direct utf8 of trailing bytes
      if (clean.length >= 64) {
        final lenHex = clean.substring(64, 128);
        final len = int.tryParse(lenHex, radix: 16) ?? 0;
        if (len > 0 && clean.length >= 128 + len * 2) {
          final strHex = clean.substring(128, 128 + len * 2);
          return _hexToAscii(strHex);
        }
      }
      return '';
    }
    // offset at 0..64 ignored (usually 0x20)
    final lenHex = clean.substring(64, 128);
    final len = int.tryParse(lenHex, radix: 16) ?? 0;
    if (len <= 0) return '';
    if (clean.length < 128 + len * 2) return '';
    final strHex = clean.substring(128, 128 + len * 2);
    return _hexToAscii(strHex);
  }

  static String _hexToAscii(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      final b = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (b == null || b == 0) continue;
      bytes.add(b);
    }
    // Use utf8 with fallback to ascii
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  void dispose() {
    for (final c in _clients.values) {
      c.dispose();
    }
    _clients.clear();
    _http.close();
  }
}
