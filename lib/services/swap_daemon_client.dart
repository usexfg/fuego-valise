import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/chain_info.dart';
import '../models/swap_models.dart';

class SwapDaemonClient {
  final String host;
  final int port;
  http.Client? _httpClient;

  SwapDaemonClient({this.host = '127.0.0.1', this.port = 18902});

  String get _baseUrl => 'http://$host:$port';
  http.Client get _client => _httpClient ??= http.Client();

  void dispose() {
    _httpClient?.close();
    _httpClient = null;
  }

  Future<bool> isAvailable() async {
    try {
      final resp = await _client
          .get(Uri.parse('$_baseUrl/health'))
          .timeout(const Duration(seconds: 3));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<dynamic> _rpc(String method, [Map<String, dynamic>? params]) async {
    final body = json.encode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': method,
      'params': params ?? {},
    });
    final resp = await _client
        .post(
          Uri.parse('$_baseUrl/'),
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200)
      throw SwapRpcException('HTTP ${resp.statusCode}', -1);
    final decoded = json.decode(resp.body) as Map<String, dynamic>;
    if (decoded.containsKey('error')) {
      final err = decoded['error'] as Map<String, dynamic>;
      throw SwapRpcException(
        err['message'] as String? ?? 'Unknown error',
        (err['code'] as num?)?.toInt() ?? -1,
      );
    }
    return decoded['result'];
  }

  Future<String> initiateSwap({
    required String pair,
    required int xfgAmount,
    required int ctrAmount,
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
    final params = <String, dynamic>{
      'pair': pair,
      'xfg_amount': xfgAmount,
      'ctr_amount': ctrAmount,
      'peer': peer,
      'role': role,
    };
    if (expectedPeerPubkey != null && expectedPeerPubkey.isNotEmpty)
      params['expected_peer_pubkey'] = expectedPeerPubkey;
    if (swapId != null && swapId.isNotEmpty) params['swap_id'] = swapId;
    if (ourSwapSecretKey != null && ourSwapSecretKey.isNotEmpty)
      params['our_swap_secret_key'] = ourSwapSecretKey;
    if (afk) params['afk'] = true;
    if (adaptorPoint != null && adaptorPoint.isNotEmpty)
      params['adaptor_point'] = adaptorPoint;
    if (hashLock != null && hashLock.isNotEmpty) params['hash_lock'] = hashLock;
    if (preSig != null && preSig.isNotEmpty) params['pre_sig'] = preSig;
    if (ctrAddress != null && ctrAddress.isNotEmpty)
      params['ctr_address'] = ctrAddress;
    if (requirePtlc) params['require_ptlc'] = true;
    if (ptlcPoint != null && ptlcPoint.isNotEmpty)
      params['ptlc_point'] = ptlcPoint;
    if (lockType != null) params['lock_type'] = lockType;
    final result = await _rpc('initiate_swap', params) as Map<String, dynamic>;
    return result['swap_id'] as String;
  }

  Future<Map<String, dynamic>> acceptSwap(String swapId) async {
    final result =
        await _rpc('accept', {'swap_id': swapId}) as Map<String, dynamic>;
    return result;
  }

  /// XMR reserve proof via the daemon → the configured monero-wallet-rpc.
  Future<String> getReserveProof({
    required String address,
    required String message,
  }) async {
    final result =
        await _rpc('get_reserve_proof', {
              'address': address,
              'message': message,
            })
            as Map<String, dynamic>;
    return result['signature'] as String;
  }

  Future<List<SwapInfo>> listSwaps() async {
    final result = await _rpc('list_swaps') as Map<String, dynamic>;
    return (result['swaps'] as List<dynamic>)
        .map((s) => SwapInfo.fromJson(s as Map<String, dynamic>))
        .toList();
  }

  Future<SwapInfo> swapStatus(String swapId) async {
    final result =
        await _rpc('swap_status', {'swap_id': swapId}) as Map<String, dynamic>;
    return SwapInfo.fromJson(result['swap'] as Map<String, dynamic>);
  }

  Future<bool> refund(String swapId) async {
    final result =
        await _rpc('refund', {'swap_id': swapId}) as Map<String, dynamic>;
    return result['success'] == true;
  }

  Future<TimeoutResult> checkTimeouts() async {
    final result = await _rpc('check_timeouts') as Map<String, dynamic>;
    return TimeoutResult.fromJson(result);
  }
}

class SwapInfo {
  final String swapId;
  final String state;
  final int pair;
  final int xfgAmount;
  final int ctrAmount;
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
      if (lockTypeVal == 1)
        lockTypeNameVal = 'PTLC';
      else if (lockTypeVal == 2)
        lockTypeNameVal = 'BRIDGE';
      else
        lockTypeNameVal = 'HTLC';
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
    int confirmationsVal =
        (params['confirmations'] as num?)?.toInt() ??
        (j['confirmations'] as num?)?.toInt() ??
        0;
    int requiredConfirmationsVal =
        (params['requiredConfirmations'] as num?)?.toInt() ??
        (j['requiredConfirmations'] as num?)?.toInt() ??
        (params['required_confirmations'] as num?)?.toInt() ??
        (j['required_confirmations'] as num?)?.toInt() ??
        6;
    int blockHeightVal =
        (params['blockHeight'] as num?)?.toInt() ??
        (j['blockHeight'] as num?)?.toInt() ??
        (params['block_height'] as num?)?.toInt() ??
        (j['block_height'] as num?)?.toInt() ??
        0;
    bool spvVerifiedVal =
        params['spvVerified'] as bool? ??
        j['spvVerified'] as bool? ??
        params['spv_verified'] as bool? ??
        j['spv_verified'] as bool? ??
        false;
    bool confirmedVal =
        params['confirmed'] as bool? ?? j['confirmed'] as bool? ?? false;
    String? spvErrorVal =
        params['spvError'] as String? ??
        j['spvError'] as String? ??
        params['spv_error'] as String? ??
        j['spv_error'] as String?;
    int? currentHeightVal =
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
      xfgAmount:
          (params['xfgAmount'] as num?)?.toInt() ??
          (j['xfgAmount'] as num?)?.toInt() ??
          0,
      ctrAmount:
          (params['ctrAmount'] as num?)?.toInt() ??
          (j['ctrAmount'] as num?)?.toInt() ??
          0,
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

  /// Display ticker for this swap's pair. Single source of truth is
  /// [SwapPairSdk]; the old inline table stopped at id 11, so every pair added
  /// after it fell back to 7 decimals in [ctrAmountDecimal] (an error of 10^11
  /// for the 18-decimal EVM chains).
  SwapPairSdk? get pairSdk => SwapPairSdk.tryFromId(pair);

  String get pairName => pairSdk?.ticker ?? 'PAIR_$pair';

  /// True when the counterparty amount can be scaled correctly.
  bool get hasKnownDecimals =>
      pairSdk != null && ChainInfo.decimals.containsKey(pairSdk!.ticker);

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

  /// Null when the pair's decimals are unknown — render "—", never a number
  /// scaled by the wrong power of ten.
  double? get ctrAmountDecimal {
    final t = pairSdk?.ticker;
    if (t == null) return null;
    final d = ChainInfo.decimals[t];
    if (d == null) return null;
    return ChainInfo.amountToDecimalWith(d, ctrAmount);
  }

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
