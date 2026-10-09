import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/chain_info.dart';
import '../models/swap_models.dart';

const int _maxRpcResponseBytes = 4 * 1024 * 1024;
const int _xfgDecimals = 7;

BigInt _atomicAmountToBigInt(dynamic value) {
  if (value == null) return BigInt.zero;
  if (value is BigInt) return value;
  if (value is int) return BigInt.from(value);
  if (value is num) return BigInt.from(value.toInt());
  if (value is String) {
    final text = value.trim();
    if (text.isEmpty) return BigInt.zero;
    return BigInt.parse(text);
  }
  throw FormatException('Invalid atomic amount: $value');
}

bool _boolValue(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') return true;
    if (normalized == 'false' || normalized == '0' || normalized.isEmpty) {
      return false;
    }
  }
  return false;
}

class SwapDaemonStatus {
  final String network;
  final String profile;
  final bool afkSoftOrdersEnabled;

  const SwapDaemonStatus({
    required this.network,
    required this.profile,
    required this.afkSoftOrdersEnabled,
  });

  factory SwapDaemonStatus.fromJson(Map<String, dynamic> json) =>
      SwapDaemonStatus(
        network: json['network']?.toString() ?? '',
        profile: json['profile']?.toString() ?? '',
        afkSoftOrdersEnabled: _boolValue(json['afk_soft_orders_enabled']),
      );
}

class SwapChain {
  final int id;
  final String key;
  final String symbol;
  final String assetTicker;
  final String name;
  final String family;
  final int decimals;
  final String implementation;
  final bool protocol;
  final bool configured;
  final bool ready;
  final String readinessError;

  const SwapChain({
    required this.id,
    required this.key,
    required this.symbol,
    required this.assetTicker,
    required this.name,
    required this.family,
    required this.decimals,
    required this.implementation,
    required this.protocol,
    required this.configured,
    required this.ready,
    required this.readinessError,
  });

  factory SwapChain.fromJson(Map<String, dynamic> json) => SwapChain(
    id: (json['id'] as num?)?.toInt() ?? -1,
    key: json['key']?.toString() ?? '',
    symbol: json['symbol']?.toString() ?? '',
    assetTicker: json['assetTicker']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    family: json['family']?.toString() ?? '',
    decimals: (json['decimals'] as num?)?.toInt() ?? 0,
    implementation: json['implementation']?.toString() ?? '',
    protocol: _boolValue(json['protocol']),
    configured: _boolValue(json['configured']),
    ready: _boolValue(json['ready']),
    readinessError: json['readinessError']?.toString() ?? '',
  );

  bool get executable => protocol && configured && ready;
  String get ticker => assetTicker.isNotEmpty ? assetTicker : symbol;
}

class SwapDaemonClient {
  final String host;
  final int port;
  final String expectedNetwork;
  final String token;
  final http.Client _httpClient;
  final bool _ownsHttpClient;

  SwapDaemonClient({
    this.host = '127.0.0.1',
    this.port = 18902,
    required this.expectedNetwork,
    this.token = '',
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null;

  String get _baseUrl => 'http://$host:$port';

  void dispose() {
    if (_ownsHttpClient) _httpClient.close();
  }

  Future<bool> isAvailable() async {
    try {
      await verifyContext();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String> _readBody(http.StreamedResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > _maxRpcResponseBytes) {
        throw const FormatException('Swap RPC response exceeds 4 MiB');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  Future<dynamic> _rpc(
    String method, [
    Map<String, dynamic>? params,
    bool mutation = false,
  ]) async {
    try {
      final request = http.Request('POST', Uri.parse('$_baseUrl/'))
        ..followRedirects = false
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': method,
          'params': params ?? const <String, dynamic>{},
        });
      if (token.isNotEmpty) request.headers['X-Swap-Token'] = token;

      final response = await _httpClient
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw SwapRpcException('Authentication rejected', response.statusCode);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('HTTP ${response.statusCode}');
      }

      final decoded = jsonDecode(await _readBody(response));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid swap RPC envelope');
      }
      final error = decoded['error'];
      if (error is Map<String, dynamic>) {
        throw SwapRpcException(
          error['message']?.toString() ?? 'Unknown error',
          (error['code'] as num?)?.toInt() ?? -1,
        );
      }
      if (!decoded.containsKey('result') || decoded['result'] == null) {
        throw const FormatException('Swap RPC returned an empty result');
      }
      return decoded['result'];
    } on SwapRpcException {
      rethrow;
    } on SwapOutcomeUnknownException {
      rethrow;
    } catch (error) {
      if (mutation) {
        throw SwapOutcomeUnknownException(method, error);
      }
      throw SwapRpcException('$method failed: $error', -1);
    }
  }

  Future<SwapDaemonStatus> verifyContext() async {
    final result = await _rpc('status') as Map<String, dynamic>;
    final status = SwapDaemonStatus.fromJson(result);
    if (status.network != expectedNetwork ||
        status.profile != expectedNetwork) {
      throw SwapRpcException(
        'Swap daemon context mismatch: expected '
        '$expectedNetwork/$expectedNetwork, got '
        '${status.network}/${status.profile}',
        -1,
      );
    }
    return status;
  }

  Future<List<SwapChain>> listChains() async {
    await verifyContext();
    final result = await _rpc('list_chains') as Map<String, dynamic>;
    final chains = (result['chains'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SwapChain.fromJson)
        .where((chain) => chain.protocol)
        .toList();
    if (chains.isEmpty) {
      throw SwapRpcException('Swap daemon reports no protocol chains', -1);
    }
    return chains;
  }

  Future<SwapChain> _requireReadyChain(String pair) async {
    final chains = await listChains();
    for (final chain in chains) {
      if (chain.key.toLowerCase() == pair.toLowerCase() ||
          chain.symbol.toLowerCase() == pair.toLowerCase()) {
        if (!chain.configured || !chain.ready) {
          final detail = chain.readinessError.isEmpty
              ? 'adapter is not configured and ready'
              : chain.readinessError;
          throw SwapRpcException('${chain.symbol}: $detail', -1);
        }
        return chain;
      }
    }
    throw SwapRpcException('Unknown protocol chain: $pair', -1);
  }

  Future<String> initiateSwap({
    required String pair,
    required String xfgAmount,
    required String ctrAmount,
    required String peer,
    String role = 'alice',
    String? expectedPeerPubkey,
    String? swapId,
    String? ourSwapSecretKey,
    bool afk = false,
    String? adaptorPoint,
    String? hashLock,
    String? preSig,
    String? ctrAddress,
    bool requirePtlc = false,
    String? ptlcPoint,
    int? lockType,
  }) async {
    await _requireReadyChain(pair);
    _validateAtomicAmount(xfgAmount, _maxUint64, 'XFG amount');
    _validateAtomicAmount(ctrAmount, _maxUint256, 'Counterparty amount');
    _validatePeerEndpoint(peer);
    _validatePeerKey(expectedPeerPubkey ?? '');
    if (role != 'alice' && role != 'bob') {
      throw SwapRpcException('Role must be alice or bob', -1);
    }
    final params = <String, dynamic>{
      'pair': pair,
      'xfg_amount': xfgAmount,
      'ctr_amount': ctrAmount,
      'peer': peer,
      'role': role,
    };
    params['expected_peer_pubkey'] = expectedPeerPubkey;
    if (swapId != null && swapId.isNotEmpty) params['swap_id'] = swapId;
    if (ourSwapSecretKey != null && ourSwapSecretKey.isNotEmpty) {
      params['our_swap_secret_key'] = ourSwapSecretKey;
    }
    if (afk) params['afk'] = true;
    if (adaptorPoint != null && adaptorPoint.isNotEmpty) {
      params['adaptor_point'] = adaptorPoint;
    }
    if (hashLock != null && hashLock.isNotEmpty) params['hash_lock'] = hashLock;
    if (preSig != null && preSig.isNotEmpty) params['pre_sig'] = preSig;
    if (ctrAddress != null && ctrAddress.isNotEmpty) {
      params['ctr_address'] = ctrAddress;
    }
    if (requirePtlc) params['require_ptlc'] = true;
    if (ptlcPoint != null && ptlcPoint.isNotEmpty) {
      params['ptlc_point'] = ptlcPoint;
    }
    if (lockType != null) params['lock_type'] = lockType;
    final result =
        await _rpc('initiate_swap', params, true) as Map<String, dynamic>;
    return result['swap_id'] as String;
  }

  Future<Map<String, dynamic>> acceptSwap(String swapId) async {
    _validateSwapId(swapId);
    await verifyContext();
    final result =
        await _rpc('accept', {'swap_id': swapId}, true) as Map<String, dynamic>;
    return result;
  }

  /// XMR reserve proof via the daemon → the configured monero-wallet-rpc.
  Future<String> getReserveProof({
    required String address,
    required String message,
  }) async {
    await verifyContext();
    final result =
        await _rpc('get_reserve_proof', {
              'address': address,
              'message': message,
            })
            as Map<String, dynamic>;
    return result['signature'] as String;
  }

  Future<List<SwapInfo>> listSwaps() async {
    await verifyContext();
    final result = await _rpc('list_swaps') as Map<String, dynamic>;
    return (result['swaps'] as List<dynamic>)
        .map((s) => SwapInfo.fromJson(s as Map<String, dynamic>))
        .toList();
  }

  Future<SwapInfo> swapStatus(String swapId) async {
    _validateSwapId(swapId);
    await verifyContext();
    final result =
        await _rpc('swap_status', {'swap_id': swapId}) as Map<String, dynamic>;
    return SwapInfo.fromJson(result['swap'] as Map<String, dynamic>);
  }

  Future<bool> refund(String swapId) async {
    _validateSwapId(swapId);
    await verifyContext();
    final result =
        await _rpc('refund', {'swap_id': swapId}, true) as Map<String, dynamic>;
    return result['success'] == true;
  }

  Future<TimeoutResult> checkTimeouts() async {
    await verifyContext();
    final result =
        await _rpc('check_timeouts', const <String, dynamic>{}, true)
            as Map<String, dynamic>;
    return TimeoutResult.fromJson(result);
  }

  static final BigInt _maxUint64 = (BigInt.one << 64) - BigInt.one;
  static final BigInt _maxUint256 = (BigInt.one << 256) - BigInt.one;

  static String decimalToAtomic(String text, int decimals, {BigInt? maximum}) {
    if (decimals < 0 || decimals > 77 || text.trim() != text) {
      throw const FormatException('Invalid decimal amount');
    }
    final match = RegExp(r'^(0|[1-9][0-9]*)(?:\.([0-9]+))?$').firstMatch(text);
    if (match == null) throw const FormatException('Invalid decimal amount');
    final fraction = match.group(2) ?? '';
    if (fraction.length > decimals) {
      throw FormatException('Amount supports at most $decimals decimal places');
    }
    final paddedFraction = fraction.padRight(decimals, '0');
    final digits = '${match.group(1)}$paddedFraction';
    final atomic = BigInt.parse(digits);
    if (atomic <= BigInt.zero) {
      throw const FormatException('Amount must be greater than zero');
    }
    if (maximum != null && atomic > maximum) {
      throw const FormatException('Amount exceeds protocol range');
    }
    return atomic.toString();
  }

  static String xfgToAtomic(String text) =>
      decimalToAtomic(text, _xfgDecimals, maximum: _maxUint64);

  static String counterpartyToAtomic(String text, int decimals) =>
      decimalToAtomic(text, decimals, maximum: _maxUint256);

  static void _validateAtomicAmount(
    String value,
    BigInt maximum,
    String label,
  ) {
    if (!RegExp(r'^[0-9]+$').hasMatch(value)) {
      throw SwapRpcException('$label must be an unsigned decimal string', -1);
    }
    final parsed = BigInt.parse(value);
    if (parsed <= BigInt.zero || parsed > maximum) {
      throw SwapRpcException('$label is outside the protocol range', -1);
    }
  }

  static void _validatePeerEndpoint(String endpoint) {
    final match = RegExp(r'^([^\s/:]+):(\d{1,5})$').firstMatch(endpoint);
    final port = match == null ? null : int.tryParse(match.group(2)!);
    if (match == null || port == null || port < 1 || port > 65535) {
      throw SwapRpcException('Peer endpoint must be host:port', -1);
    }
  }

  static void _validatePeerKey(String key) {
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(key) ||
        RegExp(r'^0{64}$').hasMatch(key)) {
      throw SwapRpcException(
        'Expected peer key must be 64 nonzero hexadecimal characters',
        -1,
      );
    }
  }

  static void _validateSwapId(String swapId) {
    if (swapId.isEmpty ||
        swapId.length > 128 ||
        !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(swapId)) {
      throw SwapRpcException('Invalid swap ID', -1);
    }
  }
}

class SwapInfo {
  final String swapId;
  final String state;
  final int pair;
  final String pairSymbol;
  final BigInt xfgAmount;
  final BigInt ctrAmount;
  final String peerEndpoint;
  final int createdAt;
  final int updatedAt;
  final int? timeoutHeight;
  final int lockType;
  final String lockTypeName;
  final String ptlcPoint;
  final bool requirePtlc;
  final String? ctrLockTxId;
  final int confirmations;
  final int requiredConfirmations;
  final int blockHeight;
  final bool spvVerified;
  final bool confirmed;
  final String? spvError;
  final int? currentHeight;

  SwapInfo({
    required this.swapId,
    required this.state,
    required this.pair,
    this.pairSymbol = '',
    required this.xfgAmount,
    required this.ctrAmount,
    required this.peerEndpoint,
    required this.createdAt,
    required this.updatedAt,
    this.timeoutHeight,
    this.lockType = 0,
    this.lockTypeName = 'HTLC',
    this.ptlcPoint = '',
    this.requirePtlc = false,
    this.ctrLockTxId,
    this.confirmations = 0,
    this.requiredConfirmations = 6,
    this.blockHeight = 0,
    this.spvVerified = false,
    this.confirmed = false,
    this.spvError,
    this.currentHeight,
  });

  factory SwapInfo.fromJson(Map<String, dynamic> j) {
    final params = j['params'] as Map<String, dynamic>? ?? j;
    // The daemon sends the numeric state id in "state" plus a human-readable
    // "stateName". Prefer stateName; fall back to numeric id → name mapping.
    String? stateName = j['stateName'] as String?;
    if (stateName == null || stateName.isEmpty) {
      final rawState = j['state'];
      if (rawState is num) {
        stateName = _stateNames[rawState.toInt()] ?? 'UNKNOWN';
      } else if (rawState is String) {
        stateName = rawState;
      } else {
        stateName = 'UNKNOWN';
      }
    }
    // PTLC lockType: daemon sends int lockType (0 HTLC,1 PTLC,2 BRIDGE) and optionally lockTypeName/ptlcPoint
    int lockTypeVal = 0;
    String lockTypeNameVal = 'HTLC';
    if (params.containsKey('lockType') && params['lockType'] is num) {
      lockTypeVal = (params['lockType'] as num).toInt();
    } else if (j.containsKey('lockType') && j['lockType'] is num) {
      lockTypeVal = (j['lockType'] as num).toInt();
    } else if (params.containsKey('lock_type') && params['lock_type'] is num) {
      lockTypeVal = (params['lock_type'] as num).toInt();
    } else if (j.containsKey('lock_type') && j['lock_type'] is num) {
      lockTypeVal = (j['lock_type'] as num).toInt();
    }
    if (params.containsKey('lockTypeName') &&
        params['lockTypeName'] is String) {
      lockTypeNameVal = params['lockTypeName'] as String;
    } else if (j.containsKey('lockTypeName') && j['lockTypeName'] is String) {
      lockTypeNameVal = j['lockTypeName'] as String;
    } else if (params.containsKey('lock_type_name') &&
        params['lock_type_name'] is String) {
      lockTypeNameVal = params['lock_type_name'] as String;
    } else {
      // derive from int
      if (lockTypeVal == 1) {
        lockTypeNameVal = 'PTLC';
      } else if (lockTypeVal == 2) {
        lockTypeNameVal = 'BRIDGE';
      } else {
        lockTypeNameVal = 'HTLC';
      }
    }
    // SPV live fields (additive — daemon may omit on old binaries)
    String? ctrLockTxIdVal =
        params['ctrLockTxId'] as String? ??
        j['ctrLockTxId'] as String? ??
        params['ctr_lock_txid'] as String? ??
        j['ctr_lock_txid'] as String? ??
        params['ctrLockTxId'] as String? ??
        j['ctrLockTxId'] as String?;
    if (ctrLockTxIdVal != null && ctrLockTxIdVal.isEmpty) ctrLockTxIdVal = null;
    // params may also hold ctrLockTxId as hex without prefix — also check top-level j
    ctrLockTxIdVal ??= j['ctrLockTxId'] as String?;
    final confirmationsVal =
        (params['confirmations'] as num?)?.toInt() ??
        (j['confirmations'] as num?)?.toInt() ??
        0;
    final requiredConfirmationsVal =
        (params['requiredConfirmations'] as num?)?.toInt() ??
        (j['requiredConfirmations'] as num?)?.toInt() ??
        (params['required_confirmations'] as num?)?.toInt() ??
        (j['required_confirmations'] as num?)?.toInt() ??
        6;
    final blockHeightVal =
        (params['blockHeight'] as num?)?.toInt() ??
        (j['blockHeight'] as num?)?.toInt() ??
        (params['block_height'] as num?)?.toInt() ??
        (j['block_height'] as num?)?.toInt() ??
        0;
    final spvVerifiedVal = _boolValue(
      params['spvVerified'] ??
          j['spvVerified'] ??
          params['spv_verified'] ??
          j['spv_verified'],
    );
    final confirmedVal = _boolValue(params['confirmed'] ?? j['confirmed']);
    final spvErrorVal =
        params['spvError'] as String? ??
        j['spvError'] as String? ??
        params['spv_error'] as String? ??
        j['spv_error'] as String?;
    final currentHeightVal =
        (params['currentHeight'] as num?)?.toInt() ??
        (j['currentHeight'] as num?)?.toInt() ??
        (params['current_height'] as num?)?.toInt() ??
        (j['current_height'] as num?)?.toInt();
    // Fallback: legacy field name ctrLockTxId may be inside j['params'] already handled via params= j; also check top-level txid alias
    ctrLockTxIdVal ??=
        params['ctrLockTxid'] as String? ?? j['ctrLockTxid'] as String?;
    return SwapInfo(
      swapId:
          params['swapId'] as String? ??
          j['swapId'] as String? ??
          j['swap_id'] as String? ??
          '',
      state: stateName,
      pair:
          (params['pair'] as num?)?.toInt() ??
          (j['pair'] as num?)?.toInt() ??
          0,
      pairSymbol:
          params['pairName']?.toString() ??
          j['pairName']?.toString() ??
          params['pair_name']?.toString() ??
          j['pair_name']?.toString() ??
          '',
      xfgAmount: _atomicAmountToBigInt(
        params['xfgAmountAtomic'] ??
            j['xfgAmountAtomic'] ??
            params['xfg_amount_atomic'] ??
            j['xfg_amount_atomic'] ??
            params['xfgAmount'] ??
            j['xfgAmount'] ??
            params['xfg_amount'] ??
            j['xfg_amount'],
      ),
      ctrAmount: _atomicAmountToBigInt(
        params['ctrAmount'] ??
            j['ctrAmount'] ??
            params['ctr_amount'] ??
            j['ctr_amount'],
      ),
      peerEndpoint:
          params['peerEndpoint'] as String? ??
          j['peerEndpoint'] as String? ??
          params['peer'] as String? ??
          j['peer'] as String? ??
          '',
      createdAt:
          (j['createdAt'] as num?)?.toInt() ??
          (params['createdAt'] as num?)?.toInt() ??
          0,
      updatedAt:
          (j['updatedAt'] as num?)?.toInt() ??
          (params['updatedAt'] as num?)?.toInt() ??
          0,
      timeoutHeight:
          (params['xfgTimeoutHeight'] as num?)?.toInt() ??
          (j['xfgTimeoutHeight'] as num?)?.toInt() ??
          (params['xfg_timeout_height'] as num?)?.toInt(),
      lockType: lockTypeVal,
      lockTypeName: lockTypeNameVal,
      ptlcPoint:
          params['ptlcPoint'] as String? ??
          params['ptlc_point'] as String? ??
          j['ptlcPoint'] as String? ??
          j['ptlc_point'] as String? ??
          '',
      requirePtlc:
          params['requirePtlc'] as bool? ??
          params['require_ptlc'] as bool? ??
          j['requirePtlc'] as bool? ??
          j['require_ptlc'] as bool? ??
          false,
      ctrLockTxId: ctrLockTxIdVal,
      confirmations: confirmationsVal,
      requiredConfirmations: requiredConfirmationsVal,
      blockHeight: blockHeightVal,
      spvVerified: spvVerifiedVal,
      confirmed: confirmedVal,
      spvError: spvErrorVal,
      currentHeight: currentHeightVal,
    );
  }

  /// Ticker for the wire `pair` id, keyed the same way as every [ChainInfo]
  /// map so colour/icon/decimals/explorer lookups all resolve.
  ///
  /// Derived from [SwapPairSdk] rather than a local id table: a hardcoded
  /// 0-11 map silently returned `PAIR_12`..`PAIR_26` for ten wired pairs
  /// (GLEEC, RHC, AVAX, CRO, BOB, UNI, XPL, PLS, MON, OP) and returned
  /// `POLYGON` for id 11, which no [ChainInfo] map is keyed by.
  String get pairName => pairSymbol.isNotEmpty
      ? pairSymbol
      : (SwapPairSdk.tryFromId(pair)?.ticker ?? 'PAIR_$pair');

  String get lockTypeLabel => lockTypeName;
  bool get isPtlc => lockType == 1;
  bool get isBridge => lockType == 2;
  bool get isHtlc => lockType == 0;

  // Numeric SwapState ids (XfgSwap::SwapState) → names. Kept in sync with the
  // C++ SwapTypes.h enum; terminal names match the daemon's isTerminal set.
  static const Map<int, String> _stateNames = {
    0: 'INITIATED',
    1: 'XFG_LOCKED',
    2: 'CTR_LOCKED',
    3: 'XFG_CLAIMED',
    4: 'CTR_CLAIMED',
    5: 'XFG_REFUNDED',
    6: 'CTR_REFUNDED',
    7: 'FAILED',
    10: 'ADAPTOR_KEYS_EXCHANGED',
    11: 'ADAPTOR_ESCROW_FUNDED',
    12: 'ADAPTOR_PRESIGS_READY',
    13: 'ADAPTOR_CTR_LOCKED',
    14: 'ADAPTOR_SECRET_REVEALED',
    15: 'ADAPTOR_XFG_SPENT',
    16: 'ADAPTOR_REFUNDED',
    17: 'ADAPTOR_WAITING_SPV',
    18: 'ADAPTOR_SECRET_CONFIRMED_SPV',
    100: 'AFK_OFFER_LOCKED',
    101: 'AFK_OFFER_ACCEPTED',
    102: 'AFK_CLAIMED',
    103: 'AFK_REFUNDED',
  };

  bool get isTerminal {
    const terminal = {
      'ADAPTOR_XFG_SPENT',
      'ADAPTOR_REFUNDED',
      'AFK_CLAIMED',
      'AFK_REFUNDED',
      'FAILED',
      'XFG_REFUNDED',
      'XFG_CLAIMED',
      'CTR_CLAIMED',
      'CTR_REFUNDED',
    };
    return terminal.contains(state);
  }

  double get xfgAmountDecimal => ChainInfo.amountToDecimal('XFG', xfgAmount);
  double get ctrAmountDecimal => ChainInfo.amountToDecimal(pairName, ctrAmount);

  bool get isCommitSeen => ctrLockTxId != null && ctrLockTxId!.isNotEmpty;
  bool get isLanded =>
      spvVerified &&
      confirmations >= requiredConfirmations &&
      requiredConfirmations > 0;
  double get confirmationProgress => requiredConfirmations > 0
      ? (confirmations / requiredConfirmations).clamp(0.0, 1.0)
      : 0.0;
  String get shortTxid => ctrLockTxId == null || ctrLockTxId!.length < 12
      ? (ctrLockTxId ?? '')
      : '${ctrLockTxId!.substring(0, 8)}…${ctrLockTxId!.substring(ctrLockTxId!.length - 4)}';
  String? get explorerUrl => ctrLockTxId == null
      ? null
      : ChainInfo.explorerTxUrl(pairName, ctrLockTxId!);
  bool get isWaitingSpv => state == 'ADAPTOR_WAITING_SPV';
  bool get isSecretConfirmedSpv => state == 'ADAPTOR_SECRET_CONFIRMED_SPV';
  bool get isFailedCommit =>
      state.contains('FAILED') || state.contains('REFUND');
  String get displayState {
    switch (state) {
      case 'ADAPTOR_KEYS_EXCHANGED':
        return 'Keys exchanged';
      case 'ADAPTOR_ESCROW_FUNDED':
        return 'XFG escrow funded';
      case 'ADAPTOR_PRESIGS_READY':
        return 'Presignatures ready';
      case 'ADAPTOR_CTR_LOCKED':
        return isCommitSeen
            ? 'Counterparty committed'
            : 'Awaiting counterparty lock';
      case 'ADAPTOR_WAITING_SPV':
        return 'Confirming — $confirmations/$requiredConfirmations';
      case 'ADAPTOR_SECRET_CONFIRMED_SPV':
        return 'Confirmed — claiming';
      case 'ADAPTOR_SECRET_REVEALED':
        return 'Secret revealed';
      case 'ADAPTOR_XFG_SPENT':
        return 'Claimed — complete';
      case 'ADAPTOR_REFUNDED':
        return 'Refunded';
      case 'AFK_OFFER_LOCKED':
        return 'Offer pre-locked (AFK)';
      case 'AFK_OFFER_ACCEPTED':
        return 'Offer accepted';
      case 'AFK_CLAIMED':
        return 'AFK completed';
      case 'AFK_REFUNDED':
        return 'AFK refunded';
      default:
        return state;
    }
  }
}

class TimeoutResult {
  final int processed;
  final List<String> refunded;
  TimeoutResult({required this.processed, required this.refunded});
  factory TimeoutResult.fromJson(Map<String, dynamic> j) => TimeoutResult(
    processed: (j['processed'] as num?)?.toInt() ?? 0,
    refunded:
        (j['refunded'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
        [],
  );
}

class SwapRpcException implements Exception {
  final String message;
  final int code;
  SwapRpcException(this.message, this.code);
  @override
  String toString() => 'SwapRpcException($code): $message';
}

class SwapOutcomeUnknownException implements Exception {
  final String method;
  final Object cause;

  const SwapOutcomeUnknownException(this.method, this.cause);

  @override
  String toString() =>
      '$method response failed; outcome is unknown. Inspect swap status '
      'before retrying: $cause';
}
