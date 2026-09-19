import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import '../../ffi/fuego_native.dart';
import '../../models/chain_info.dart';
import '../../models/swap_models.dart';
import '../../services/bitcoin_reserve_proof.dart';
import '../../services/reserve_proof_service.dart';
import '../../services/security_service.dart';
import '../../services/swap_daemon_client.dart';
import '../../services/web3_multi_chain_service.dart';

export '../../models/swap_models.dart' show SwapPairSdk, ChainTypeSdk;

enum OrderType { market, limit }

class DexState {
  final bool isLoading;
  final String? error;
  final SwapPairSdk selectedPair;
  final ChainTypeSdk selectedChain;
  final List<SwapOfferSdk> offers;

  /// The offer the user tapped FILL on (or null until one is chosen).
  /// Bound to /requestswap so the request targets the tapped offer, not
  /// whichever offer happens to be first in the list.
  final SwapOfferSdk? selectedOffer;
  final List<SwapTradeSdk> recentTrades;
  final SwapPriceSdk? price;
  final OrderBookStateSdk? orderbook;
  final List<SwapStatusSdk> activeSwaps;
  final PaymentProofSdk? lastProof;
  final String? lastResult;
  final bool isConnected;

  final bool isSwapDaemonConnected;
  final List<SwapInfo> spvSwaps;
  final bool isSwapInitiating;

  final double evmBalance;
  final double solBalance;
  final bool isBalanceLoading;
  final String? htlcTxHash;

  // PTLC (new)
  final bool requirePtlc;
  final String lastLockType;
  final String lastPtlcPoint;

  const DexState({
    this.isLoading = false,
    this.error,
    this.selectedPair = SwapPairSdk.eth,
    this.selectedChain = ChainTypeSdk.ethereum,
    this.offers = const [],
    this.selectedOffer,
    this.recentTrades = const [],
    this.price,
    this.orderbook,
    this.activeSwaps = const [],
    this.lastProof,
    this.lastResult,
    this.isConnected = false,
    this.isSwapDaemonConnected = false,
    this.spvSwaps = const [],
    this.isSwapInitiating = false,
    this.evmBalance = 0.0,
    this.solBalance = 0.0,
    this.isBalanceLoading = false,
    this.htlcTxHash,
    this.requirePtlc = false,
    this.lastLockType = 'HTLC',
    this.lastPtlcPoint = '',
  });

  DexState copyWith({
    bool? isLoading,
    String? error,
    SwapPairSdk? selectedPair,
    ChainTypeSdk? selectedChain,
    List<SwapOfferSdk>? offers,
    SwapOfferSdk? selectedOffer,
    List<SwapTradeSdk>? recentTrades,
    SwapPriceSdk? price,
    OrderBookStateSdk? orderbook,
    List<SwapStatusSdk>? activeSwaps,
    PaymentProofSdk? lastProof,
    String? lastResult,
    bool? isConnected,
    bool? isSwapDaemonConnected,
    List<SwapInfo>? spvSwaps,
    bool? isSwapInitiating,
    double? evmBalance,
    double? solBalance,
    bool? isBalanceLoading,
    String? htlcTxHash,
    bool? requirePtlc,
    String? lastLockType,
    String? lastPtlcPoint,
  }) => DexState(
    isLoading: isLoading ?? this.isLoading,
    error: error,
    selectedPair: selectedPair ?? this.selectedPair,
    selectedChain: selectedChain ?? this.selectedChain,
    offers: offers ?? this.offers,
    selectedOffer: selectedOffer ?? this.selectedOffer,
    recentTrades: recentTrades ?? this.recentTrades,
    price: price ?? this.price,
    orderbook: orderbook ?? this.orderbook,
    activeSwaps: activeSwaps ?? this.activeSwaps,
    lastProof: lastProof ?? this.lastProof,
    lastResult: lastResult,
    isConnected: isConnected ?? this.isConnected,
    isSwapDaemonConnected: isSwapDaemonConnected ?? this.isSwapDaemonConnected,
    spvSwaps: spvSwaps ?? this.spvSwaps,
    isSwapInitiating: isSwapInitiating ?? this.isSwapInitiating,
    evmBalance: evmBalance ?? this.evmBalance,
    solBalance: solBalance ?? this.solBalance,
    isBalanceLoading: isBalanceLoading ?? this.isBalanceLoading,
    htlcTxHash: htlcTxHash ?? this.htlcTxHash,
    requirePtlc: requirePtlc ?? this.requirePtlc,
    lastLockType: lastLockType ?? this.lastLockType,
    lastPtlcPoint: lastPtlcPoint ?? this.lastPtlcPoint,
  );
}

class DexCubit extends Cubit<DexState> {
  final http.Client _http;
  String _baseUrl = '';
  SwapDaemonClient? _swapClient;
  Web3MultiChainService? _web3;
  String? _userAddress;

  DexCubit() : _http = http.Client(), super(const DexState());

  void configure(String host, {int port = 18189}) =>
      _baseUrl = 'http://$host:$port';
  void configureSwapDaemon({
    String host = '127.0.0.1',
    int port = 18902,
  }) => _swapClient = SwapDaemonClient(
    host: host,
    port: port,
  );

  void configureWeb3({
    String ethRpcUrl = '',
    String solRpcUrl = '',
    String? userAddress,
  }) {
    _web3 = Web3MultiChainService(ethRpcUrl: ethRpcUrl, solRpcUrl: solRpcUrl);
    if (userAddress != null) _userAddress = userAddress;
  }

  void switchEvmChain(String chain) {
    if (_web3 == null) return;
    final k = chain.toLowerCase();
    // Use per-chain routing — setEthRpc only affects ETH mainnet, not L2s
    switch (k) {
      case 'arb':
        _web3!.setEvmRpc('arb', Web3MultiChainService.defaultArbRpc);
        break;
      case 'base':
        _web3!.setEvmRpc('base', Web3MultiChainService.defaultBaseRpc);
        break;
      case 'bsc':
        _web3!.setEvmRpc('bsc', Web3MultiChainService.defaultBscRpc);
        break;
      case 'poly':
        _web3!.setEvmRpc('poly', Web3MultiChainService.defaultPolyRpc);
        break;
      case 'eth':
      default:
        _web3!.setEvmRpc('eth', Web3MultiChainService.defaultEthRpc);
        break;
    }
  }

  /// ERC20 helpers delegated to Web3MultiChainService.erc20.
  Future<BigInt> erc20BalanceOf({required String chain, required String tokenAddress, required String holder}) =>
      _web3!.getErc20Balance(holderAddress: holder, tokenAddress: tokenAddress, chain: chain);

  Future<BigInt> erc20Allowance({required String chain, required String tokenAddress, required String owner, required String spender}) =>
      _web3!.getErc20Allowance(owner: owner, spender: spender, tokenAddress: tokenAddress, chain: chain);

  /// Check allowance and approve HTLC spender if needed before a token lock.
  /// Returns txHash if approval sent, 'already-approved' if sufficient, throws on failure.
  Future<String> ensureErc20Allowance({
    required String chain,
    required String tokenAddress,
    required String owner,
    required String spender,
    required String privateKey,
    required BigInt amountBaseUnits,
  }) async {
    if (_web3 == null) throw StateError('Web3 not configured');
    final current = await erc20Allowance(chain: chain, tokenAddress: tokenAddress, owner: owner, spender: spender);
    if (current >= amountBaseUnits) return 'already-approved';
    return _web3!.approveErc20(privateKey: privateKey, tokenAddress: tokenAddress, spender: spender, amountBaseUnits: amountBaseUnits, chain: chain);
  }

  Future<void> init({String host = '127.0.0.1', int port = 18189}) async {
    configure(host, port: port);
    configureSwapDaemon();
    configureWeb3();
    await _checkConnection();
    await _checkSwapDaemon();
  }

  Future<void> _checkConnection() async {
    if (_baseUrl.isEmpty) return;
    try {
      final resp = await _http
          .get(Uri.parse('$_baseUrl/getinfo'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        emit(
          state.copyWith(isConnected: true, error: null),
        );
        await Future.wait([loadOffers(), loadPrice()]);
      }
    } catch (e) {
      emit(state.copyWith(error: 'Cannot connect to fuegod: $e'));
    }
  }

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, String>? query,
  }) async {
    final resp = await _http
        .get(_rest(path, query: query))
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final resp = await _http
        .post(
          _rest(path),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _rpc(
    String method,
    Map<String, dynamic> params,
  ) async {
    final resp = await _http
        .post(
          _rest('/json_rpc'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': 'dex',
            'method': method,
            'params': params,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (data['error'] != null) throw Exception(data['error'].toString());
    final result = data['result'];
    return result is Map<String, dynamic>
        ? result
        : <String, dynamic>{'result': result};
  }

  Uri _rest(String path, {Map<String, String>? query}) => Uri(
    scheme: 'http',
    host: Uri.parse(_baseUrl).host,
    port: Uri.parse(_baseUrl).port,
    path: path,
    queryParameters: query,
  );

  void selectPair(SwapPairSdk pair) {
    final chain = _chainForPair(pair);
    emit(
      state.copyWith(
        selectedPair: pair,
        selectedChain: chain,
        offers: [],
        recentTrades: [],
        isLoading: true,
      ),
    );
    loadOffers();
    loadPrice();
    loadTrades();
  }

  void selectChain(ChainTypeSdk chain) =>
      emit(state.copyWith(selectedChain: chain));

  /// Toggle PTLC requirement (no downgrade to HTLC). Persists in state only.
  void toggleRequirePtlc(bool v) => emit(state.copyWith(requirePtlc: v));

  /// Select a pair by chain ticker (e.g. "BTC"); no-op for unknown tickers.
  void selectPairById(String ticker) {
    for (final pair in SwapPairSdk.values) {
      if (pair.ticker == ticker) {
        selectPair(pair);
        return;
      }
    }
  }

  /// Exhaustive by construction — no `default:`, so adding a pair to
  /// [SwapPairSdk] is a compile error here until it is mapped. The previous
  /// `default: return 'SOL'` silently routed ten pairs to Solana.
  ChainTypeSdk _chainForPair(SwapPairSdk pair) {
    switch (pair) {
      case SwapPairSdk.sol:
        return ChainTypeSdk.solana;
      case SwapPairSdk.eth:
        return ChainTypeSdk.ethereum;
      case SwapPairSdk.xmr:
        return ChainTypeSdk.monero;
      case SwapPairSdk.bch:
        return ChainTypeSdk.bitcoinCash;
      case SwapPairSdk.arb:
        return ChainTypeSdk.arbitrum;
      case SwapPairSdk.base:
        return ChainTypeSdk.base;
      case SwapPairSdk.kmd:
        return ChainTypeSdk.komodo;
      case SwapPairSdk.bnb:
        return ChainTypeSdk.bnb;
      case SwapPairSdk.dcr:
        return ChainTypeSdk.decred;
      case SwapPairSdk.btc:
        return ChainTypeSdk.bitcoin;
      case SwapPairSdk.ltc:
        return ChainTypeSdk.litecoin;
      case SwapPairSdk.poly:
        return ChainTypeSdk.polygon;
      case SwapPairSdk.gleec:
        return ChainTypeSdk.gleec;
      case SwapPairSdk.robinhood:
        return ChainTypeSdk.robinhood;
      case SwapPairSdk.avax:
        return ChainTypeSdk.avax;
      case SwapPairSdk.cro:
        return ChainTypeSdk.cro;
      case SwapPairSdk.bob:
        return ChainTypeSdk.bob;
      case SwapPairSdk.sia:
        return ChainTypeSdk.sia;
      case SwapPairSdk.unichain:
        return ChainTypeSdk.unichain;
      case SwapPairSdk.plasma:
        return ChainTypeSdk.plasma;
      case SwapPairSdk.doge:
        return ChainTypeSdk.doge;
      case SwapPairSdk.dash:
        return ChainTypeSdk.dash;
      case SwapPairSdk.zec:
        return ChainTypeSdk.zec;
      case SwapPairSdk.pulsex:
        return ChainTypeSdk.pulsex;
      case SwapPairSdk.zano:
        return ChainTypeSdk.zano;
      case SwapPairSdk.monad:
        return ChainTypeSdk.monad;
      case SwapPairSdk.optimism:
        return ChainTypeSdk.optimism;
      case SwapPairSdk.ton:
        return ChainTypeSdk.ton;
      case SwapPairSdk.dot:
        return ChainTypeSdk.dot;
    }
  }

  Future<List<SwapOfferSdk>> _loadOffersFromFuegod() async {
    // Only pairs the daemon registers a client for — querying the four
    // staged pairs is four guaranteed-empty round trips per refresh.
    final results = await Future.wait(
      SwapPairSdk.values
          .where((p) => ChainInfo.isSwapable(p.ticker))
          .map((pair) async {
        try {
          return await _rpc('getswapoffers', {'pair': pair.id});
        } catch (e) {
          debugPrint('DexCubit: ${pair.ticker} offers failed: $e');
          return <String, dynamic>{};
        }
      }),
    );
    return results
        .expand((result) => result['offers'] as List<dynamic>? ?? const [])
        .map((offer) => SwapOfferSdk.fromJson(offer as Map<String, dynamic>))
        .where((offer) => offer.offerId.isNotEmpty)
        .toList();
  }

  Future<void> loadOffers() async {
    if (_baseUrl.isEmpty) return;
    try {
      final allOffers = await _loadOffersFromFuegod();
      final selected = allOffers
          .where((offer) => offer.pair == state.selectedPair)
          .toList();
      emit(
        state.copyWith(
          offers: selected,
          isLoading: false,
          error: null,
        ),
      );
    } catch (e) {
      debugPrint('DexCubit: loadOffers failed: $e');
    }
  }

  Future<void> loadPrice() async {
    if (_baseUrl.isEmpty) return;
    try {
      final r = await _rpc('getswapprice', {'pair': state.selectedPair.id});
      emit(
        state.copyWith(
          price: SwapPriceSdk.fromJson(r, pairOverride: state.selectedPair),
        ),
      );
    } catch (e) {
      debugPrint('DexCubit: loadPrice failed: $e');
    }
  }

  Future<void> loadTrades() async {
    if (_baseUrl.isEmpty) return;
    try {
      final r = await _rpc('getswaptrades', {
        'pair': state.selectedPair.id,
        'limit': 50,
      });
      final trades = (r['trades'] as List<dynamic>? ?? [])
          .map((t) => SwapTradeSdk.fromJson(t as Map<String, dynamic>))
          .toList();
      emit(state.copyWith(recentTrades: trades));
    } catch (e) {
      debugPrint('DexCubit: loadTrades failed: $e');
    }
  }

  Future<void> loadOrderbook() async {
    if (_baseUrl.isEmpty) return;
    try {
      final r = await _rpc('getorderbook', {
        'pair': state.selectedPair.id,
        'depth': 20,
      });
      emit(state.copyWith(orderbook: OrderBookStateSdk.fromJson(r)));
    } catch (e) {
      debugPrint('DexCubit: loadOrderbook failed: $e');
    }
  }

  /// Remember the offer the user tapped FILL on; /requestswap must target
  /// exactly this offer (H11: `offers.first` was orderbook-order dependent).
  void selectOffer(SwapOfferSdk offer) {
    final pair = offer.pair;
    if (pair == null) {
      emit(state.copyWith(
        selectedOffer: offer,
        error: 'Offer pair id ${offer.pairId} is not supported by this build.',
      ));
      return;
    }
    emit(
      state.copyWith(
        selectedOffer: offer,
        selectedPair: pair,
        selectedChain: _chainForPair(pair),
      ),
    );
  }

  Future<void> loadActiveSwaps() async {
    if (_baseUrl.isEmpty) return;
    try {
      final r = await _post('/getactiveswaps', {});
      final swaps = (r['swaps'] as List<dynamic>? ?? [])
          .map((s) => SwapStatusSdk.fromJson(s as Map<String, dynamic>))
          .toList();
      emit(state.copyWith(activeSwaps: swaps));
    } catch (e) {
      debugPrint('DexCubit: loadActiveSwaps failed: $e');
    }
  }

  /// Sign an offer/cancel payload with the persisted maker identity and
  /// return (sigHash, signature, makerPubKey). Empty strings on failure.
  /// For cancels the payload is `cancel:<offerId>` (matches
  /// SwapOfferRelay::handleCancelMessage).
  Future<(String, String, String)> _signOffer(String payload) async {
    await _ensureMakerIdentity();
    final pub = makerPublicKeyHex();
    final sec = _makerSecretKeyHex;
    if (pub.isEmpty || sec == null) return ('', '', '');
    try {
      final sigHash = _native.cnFastHash(utf8.encode(payload));
      if (sigHash.isEmpty) return ('', '', '');
      final sig = _native.cryptoNoteSign(
        _hexToBytes(sigHash),
        _hexToBytes(pub),
        _hexToBytes(sec),
      );
      return (sigHash, sig, pub);
    } catch (e) {
      debugPrint('DexCubit: offer signing failed: $e');
      return ('', '', '');
    }
  }

  /// Sign the canonical offer digest — must match the fuegod relay's
  /// `offerCanonicalHash` exactly:
  ///   offerId ‖ u8(pair) ‖ u64LE(xfgAmount) ‖ u64LE(rateNum)
  ///   ‖ u8(isSoftOrder) ‖ u32LE(ttlBlocks) ‖ u8(allowedSlippagePct)
  ///   ‖ u64LE(timestamp)
  /// The relay validates `generate_signature(that hash)` — signing any other
  /// byte layout produces offers that are rejected.
  @visibleForTesting
  static List<int> canonicalOfferBytesForTest({
    required String offerId,
    required int pair,
    required int xfgAmount,
    required int rateNum,
    required int ttlBlocks,
    required int timestamp,
    bool isSoftOrder = false,
    int slippagePct = 0,
  }) {
    final out = <int>[];
    out.addAll(utf8.encode(offerId));
    out.add(pair & 0xFF);
    out.addAll(_leU64(xfgAmount));
    out.addAll(_leU64(rateNum));
    out.add(isSoftOrder ? 0x01 : 0x00);
    out.addAll(_leU32(ttlBlocks));
    out.add(slippagePct & 0xFF);
    out.addAll(_leU64(timestamp));
    return out;
  }

  static List<int> _leU32(int v) {
    final b = ByteData(4)..setUint32(0, v & 0xFFFFFFFF, Endian.little);
    return b.buffer.asUint8List().toList();
  }

  static List<int> _leU64(int v) {
    final b = ByteData(8)..setUint64(0, v, Endian.little);
    return b.buffer.asUint8List().toList();
  }

  Future<void> submitOffer({
    required int xfgAmount,
    required int rateNum,
    int ttlBlocks = 720,
  }) async {
    emit(state.copyWith(isLoading: true, lastResult: null, error: null));
    try {
      // Offer id: hash of a unique seed. The relay validates the signature
      // over the canonical field digest (below), so the id itself only
      // needs uniqueness.
      final timestamp =
          DateTime.now().millisecondsSinceEpoch ~/ 1000; // seconds
      final seed = '${state.selectedPair.id}:$xfgAmount:$rateNum:$timestamp';
      final offerId = _native.cnFastHash(utf8.encode(seed));
      if (offerId.isEmpty) {
        emit(state.copyWith(isLoading: false, error: 'Offer signing failed'));
        return;
      }
      await _ensureMakerIdentity();
      final pub = makerPublicKeyHex();
      final sec = _makerSecretKeyHex;
      if (pub.isEmpty || sec == null) {
        emit(state.copyWith(isLoading: false, error: 'Maker identity missing'));
        return;
      }
      final sigData = canonicalOfferBytesForTest(
        offerId: offerId,
        pair: state.selectedPair.id,
        xfgAmount: xfgAmount,
        rateNum: rateNum,
        ttlBlocks: ttlBlocks,
        timestamp: timestamp,
      );
      final sigHash = _native.cnFastHash(sigData);
      final signature = _native.cryptoNoteSign(
        _hexToBytes(sigHash),
        _hexToBytes(pub),
        _hexToBytes(sec),
      );
      if (signature.isEmpty) {
        emit(state.copyWith(isLoading: false, error: 'Offer signing failed'));
        return;
      }
      final r = await _post('/submitswap', {
        'offerId': offerId,
        'xfgAmount': xfgAmount,
        'rateNum': rateNum,
        'pair': state.selectedPair.id,
        'makerPubKey': pub,
        'signature': signature,
        'ttlBlocks': ttlBlocks,
        'isSoftOrder': false,
        // The canonical hash covers the timestamp — the relay honors the
        // client-signed value.
        'timestamp': timestamp,
      });
      emit(
        state.copyWith(
          isLoading: false,
          lastResult: 'Offer submitted: ${r['status'] ?? 'error'}',
        ),
      );
      await loadOffers();
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: 'Submit failed: $e'));
    }
  }

  Future<void> cancelOffer({required String offerId}) async {
    emit(state.copyWith(isLoading: true, lastResult: null, error: null));
    try {
      final (_, signature, makerPubKey) = await _signOffer('cancel:$offerId');
      if (signature.isEmpty || makerPubKey.isEmpty) {
        emit(state.copyWith(isLoading: false, error: 'Cancel signing failed'));
        return;
      }
      final r = await _post('/cancelswap', {
        'offerId': offerId,
        'makerPubKey': makerPubKey,
        'signature': signature,
      });
      emit(
        state.copyWith(
          isLoading: false,
          lastResult: 'Offer cancelled: ${r['status'] ?? 'error'}',
        ),
      );
      await loadOffers();
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: 'Cancel failed: $e'));
    }
  }

  /// Fill [offer] for [amount] XFG atomic units.
  ///
  /// The offer carries the pair and the rate, so both the daemon pair name and
  /// the counterparty leg are derived from it. If either cannot be resolved the
  /// request is refused — a swap whose counterparty amount is a guess is worse
  /// than no swap.
  Future<void> requestSwap({
    required SwapOfferSdk offer,
    required int amount,
    required String takerPubKey,
    required String proofOfFunds,
    String? takerChainKey,
  }) async {
    final offerId = offer.offerId;
    final pair = offer.pair;
    if (pair == null) {
      emit(state.copyWith(
        isLoading: false,
        error:
            'This offer is for pair id ${offer.pairId}, which this wallet build '
            'does not support. Update the wallet before filling it.',
      ));
      return;
    }
    if (amount > offer.amount) {
      emit(state.copyWith(
        isLoading: false,
        error:
            'Amount exceeds the offer (${offer.amount} atomic XFG available).',
      ));
      return;
    }
    final ctrAmount = counterpartyAmountFor(
      xfgAtomic: amount,
      rateNum: offer.rateNum,
      pair: pair,
    );
    if (ctrAmount == null) {
      emit(state.copyWith(
        isLoading: false,
        error:
            'Cannot price the ${pair.ticker} leg of this offer (rate '
            '${offer.rateNum}). Refusing to initiate.',
      ));
      return;
    }
    // The taker identity (Ed25519 keypair from the native crypto lib) and the
    // chain reserve proof are required; the maker verifies both before locking.
    var pubKey = takerPubKey;
    var proof = proofOfFunds;
    if ((pubKey.isEmpty || proof.isEmpty) &&
        takerChainKey != null &&
        takerChainKey.isNotEmpty) {
      await _ensureTakerIdentity();
      pubKey = _takerPublicKeyHex();
      final chain = state.selectedChain;
      if (chain.isEvm) {
        proof = ReserveProofService.buildEvmProof(
          offerId: offerId,
          privateKeyHex: takerChainKey,
        );
      } else if (chain == ChainTypeSdk.solana) {
        proof = await ReserveProofService.buildSolProof(
          offerId: offerId,
          privateKeyHex: takerChainKey,
        );
      } else if (chain.isBtcFamily) {
        // Bitcoin signmessage proof from the taker's WIF key.
        final version = _btcP2pkhVersion(chain);
        if (version == null) {
          emit(state.copyWith(
            isLoading: false,
            error:
                'No verified address prefix for ${chain.symbol} — refusing to '
                'build a reserve proof that could name the wrong address.',
          ));
          return;
        }
        proof = BitcoinReserveProof.build(
          wif: takerChainKey,
          offerId: offerId,
          p2pkhVersion: version.$1,
          p2pkhVersion2: version.$2,
        );
      } else if (chain == ChainTypeSdk.monero) {
        // XMR reserve proofs are produced by monero-wallet-rpc. Bridge via
        // the local swap daemon: the user's XMR address is the taker input.
        final xmrProof = await _xmrReserveProof(
          offerId: offerId,
          address: takerChainKey,
        );
        if (xmrProof == null) return;
        proof = xmrProof;
      } else {
        emit(
          state.copyWith(
            isLoading: false,
            error:
                'Reserve proofs for ${chain.symbol} are not supported in-app',
          ),
        );
        return;
      }
    }
    if (pubKey.isEmpty || proof.isEmpty) {
      emit(
        state.copyWith(
          isLoading: false,
          error:
              'Taking offers requires a taker identity + chain reserve proof — enter your chain private key',
        ),
      );
      return;
    }
    emit(state.copyWith(isLoading: true, lastResult: null, error: null));
    try {
      final r = await _post('/requestswap', {
        'offerId': offerId,
        'amount': amount,
        'takerPubKey': pubKey,
        'proofOfFunds': proof,
      });
      emit(
        state.copyWith(
          isLoading: false,
          lastResult:
              'Swap requested: ${r['status'] ?? 'error'} — waiting for the maker to lock XFG',
        ),
      );
      // The maker's SwapDaemon verifies the proof, creates the AFK lock and
      // publishes the fill result. Poll for it, then drive the local swap
      // daemon into the AFK flow.
      await _awaitFillResult(
        offerId: offerId,
        takerPubKey: pubKey,
        amount: amount,
        pair: pair,
        ctrAmount: ctrAmount,
      );
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: 'Swap failed: $e'));
    }
  }

  // ── Fill-result polling + local AFK initiation ──
  static const _fillResultPollSeconds = 5;
  static const _fillResultMaxAttempts = 30; // 2.5 minutes

  Future<void> _awaitFillResult({
    required String offerId,
    required String takerPubKey,
    required int amount,
    required SwapPairSdk pair,
    required int ctrAmount,
  }) async {
    for (var attempt = 0; attempt < _fillResultMaxAttempts; ++attempt) {
      await Future<void>.delayed(
        const Duration(seconds: _fillResultPollSeconds),
      );
      Map<String, dynamic> r;
      try {
        r = await _get('/getswaprequests', query: {'takerPubKey': takerPubKey});
      } catch (e) {
        continue;
      }
      final requests = (r['requests'] as List<dynamic>? ?? const []);
      Map<String, dynamic>? match;
      for (final q in requests) {
        final m = q as Map<String, dynamic>;
        if (m['offerId'] == offerId) {
          match = m;
          break;
        }
      }
      if (match == null) continue;
      final lockId = (match['lockId'] as String?) ?? '';
      final makerEndpoint = (match['makerEndpoint'] as String?) ?? '';
      final adaptorPoint = (match['adaptorPoint'] as String?) ?? '';
      final hashLock = (match['hashLock'] as String?) ?? '';
      final preSig = (match['preSig'] as String?) ?? '';
      final ctrAddress = (match['ctrAddress'] as String?) ?? '';
      if (lockId.isEmpty) {
        emit(state.copyWith(error: 'Maker fill result missing lockId'));
        return;
      }
      if (makerEndpoint.isEmpty) {
        emit(
          state.copyWith(
            error:
                'The maker did not advertise a public endpoint (xfg-swapd --public-endpoint) — this fill cannot complete from the app',
          ),
        );
        return;
      }
      if (adaptorPoint.isEmpty || hashLock.isEmpty || preSig.isEmpty) {
        emit(
          state.copyWith(error: 'Maker fill result missing pre-lock material'),
        );
        return;
      }
      await _initiateAfkSwap(
        lockId: lockId,
        makerEndpoint: makerEndpoint,
        amount: amount,
        ctrAmount: ctrAmount,
        pair: pair,
        adaptorPoint: adaptorPoint,
        hashLock: hashLock,
        preSig: preSig,
        ctrAddress: ctrAddress,
        expectedPeerPubkey: state.selectedOffer?.makerPubKey ?? '',
      );
      return;
    }
    emit(
      state.copyWith(
        error:
            'No fill result after ${_fillResultPollSeconds * _fillResultMaxAttempts}s — the maker may be offline',
      ),
    );
  }

  /// Counterparty base units for [xfgAtomic] at an offer's `rateNum`.
  ///
  /// `rateNum` is XFG-atomic per 1e7 counterparty-atomic (the orderbook
  /// convention `/getswapprice` uses), so
  ///   ctr_atomic = xfg_atomic * 1e7 / rateNum
  /// scaled from XFG's 7 decimals to the counterparty chain's own decimals.
  /// Returns null when the rate or the pair's decimals are unknown — the
  /// caller must refuse to initiate rather than guess.
  static int? counterpartyAmountFor({
    required int xfgAtomic,
    required int rateNum,
    required SwapPairSdk pair,
  }) {
    if (xfgAtomic <= 0 || rateNum <= 0) return null;
    final ctrDecimals = ChainInfo.decimals[pair.ticker];
    if (ctrDecimals == null) return null;
    // Exact integer math — no double anywhere on the value path.
    final xfgBig = BigInt.from(xfgAtomic);
    final ctrUnitScale = BigInt.from(10).pow(ctrDecimals);
    final value = xfgBig * ctrUnitScale ~/ BigInt.from(rateNum);
    if (value <= BigInt.zero) return null;
    if (value > BigInt.from(0x7FFFFFFFFFFFFFFF)) return null;
    return value.toInt();
  }

  Future<void> _initiateAfkSwap({
    required String lockId,
    required String makerEndpoint,
    required int amount,
    required int ctrAmount,
    required SwapPairSdk pair,
    String adaptorPoint = '',
    String hashLock = '',
    String preSig = '',
    String ctrAddress = '',
    String expectedPeerPubkey = '',
  }) async {
    if (_swapClient == null) {
      emit(state.copyWith(error: 'Swap daemon not connected'));
      return;
    }
    if (_takerSecretKeyHex == null || _takerSecretKeyHex!.isEmpty) {
      emit(state.copyWith(error: 'Taker identity missing — retry the request'));
      return;
    }
    try {
      // Bind this daemon's record to the maker's lock and sign with the exact
      // identity published in the request (the maker pre-bound it). The
      // pre-lock material lets the daemon lock the counterparty HTLC and
      // complete the maker's pre-sig after extracting t.
      final swapId = await _swapClient!.initiateSwap(
        // The daemon's own name for the pair the user picked. Never a chain
        // lookup with a fallback — a wrong name here runs the swap on the
        // wrong chain (C1).
        pair: pair.daemonName,
        xfgAmount: amount,
        ctrAmount: ctrAmount,
        peer: makerEndpoint,
        role: 'alice',
        swapId: lockId,
        ourSwapSecretKey: _takerSecretKeyHex!,
        afk: true,
        adaptorPoint: adaptorPoint,
        hashLock: hashLock,
        preSig: preSig,
        ctrAddress: ctrAddress,
        // Pin the daemon's peer connection to the offer's maker key so a
        // relay-supplied endpoint cannot redirect the fill (H13).
        expectedPeerPubkey: expectedPeerPubkey,
        requirePtlc: state.requirePtlc,
      );
      final accept = await _swapClient!.acceptSwap(swapId);
      emit(
        state.copyWith(
          lastResult:
              'Maker locked XFG. AFK swap ${swapId}: ${accept['state']}',
        ),
      );
      await loadSpvSwaps();
    } catch (e) {
      emit(state.copyWith(error: 'AFK swap initiation failed: $e'));
    }
  }

  /// (prefix byte, optional second prefix byte) for P2PKH addresses.
  ///
  /// Null for a chain with no verified prefix here. The old `default:
  /// (0x00, null)` produced a Bitcoin mainnet address for any unlisted
  /// chain, so the reserve proof was signed for an address the maker would
  /// never see funds at.
  static (int, int?)? _btcP2pkhVersion(ChainTypeSdk chain) {
    switch (chain) {
      case ChainTypeSdk.bitcoin:
        return (0x00, null);
      case ChainTypeSdk.bitcoinCash:
        return (0x00, null);
      case ChainTypeSdk.litecoin:
        return (0x30, null);
      case ChainTypeSdk.komodo:
        return (0x3c, null);
      case ChainTypeSdk.decred:
        return (0x3f, 0x07); // two-byte prefix 0x073f
      default:
        return null;
    }
  }

  /// XMR reserve proof via the local swap daemon → the user's configured
  /// monero-wallet-rpc (get_reserve_proof). The maker's verifyReserveProof
  /// expects the "address:message:signature" layout.
  Future<String?> _xmrReserveProof({
    required String offerId,
    required String address,
  }) async {
    if (_swapClient == null) {
      emit(
        state.copyWith(
          error: 'Swap daemon not connected — cannot build XMR reserve proof',
        ),
      );
      return null;
    }
    try {
      final signature = await _swapClient!.getReserveProof(
        address: address,
        message: offerId,
      );
      return '$address:$offerId:$signature';
    } catch (e) {
      emit(state.copyWith(error: 'XMR reserve proof failed: $e'));
      return null;
    }
  }

  // ── Taker identity ──
  // Ed25519 keypair published as takerPubKey in /requestswap. Persisted in
  // secure storage so an app restart between the request and the AFK fill
  // does not strand the identity (the maker pre-binds the published key).
  String? _takerSecretKeyHex;
  String? _takerPublicKeyHexCache;
  final FuegoNative _native = FuegoNative();

  Future<void> _ensureTakerIdentity() async {
    if (_takerPublicKeyHexCache != null) return;
    try {
      final stored = await SecurityService.readTakerSwapSecret();
      if (stored != null && stored.length == 64) {
        final kp = _native.keypairFromSecret(
          Uint8List.fromList(_hexToBytes(stored)),
        );
        final pub = kp['public'];
        if (pub is String && pub.length == 64) {
          _takerSecretKeyHex = stored;
          _takerPublicKeyHexCache = pub;
          return;
        }
      }
    } catch (e) {
      debugPrint('DexCubit: taker identity load failed: $e');
    }
    final keys = _native.keypairGenerate();
    final priv = keys['secret'];
    final pub = keys['public'];
    if (priv is String && pub is String) {
      _takerSecretKeyHex = priv;
      _takerPublicKeyHexCache = pub;
      try {
        await SecurityService.writeTakerSwapSecret(_takerSecretKeyHex!);
      } catch (e) {
        debugPrint('DexCubit: taker identity persist failed: $e');
      }
    } else {
      _takerPublicKeyHexCache = '';
    }
  }

  String _takerPublicKeyHex() {
    if (_takerPublicKeyHexCache == null) {
      _takerPublicKeyHexCache = '';
    }
    return _takerPublicKeyHexCache!;
  }

  // ── Maker identity ──
  // Keypair that signs /submitswap and /cancelswap (CryptoNote Schnorr
  // signatures over cn_fast_hash of the payload). Persisted so offers can
  // be cancelled from a later session.
  String? _makerSecretKeyHex;
  String? _makerPublicKeyHexCache;

  Future<void> _ensureMakerIdentity() async {
    if (_makerPublicKeyHexCache != null) return;
    try {
      final stored = await SecurityService.readMakerSwapSecret();
      if (stored != null && stored.length == 64) {
        final kp = _native.keypairFromSecret(
          Uint8List.fromList(_hexToBytes(stored)),
        );
        final pub = kp['public'];
        if (pub is String && pub.length == 64) {
          _makerSecretKeyHex = stored;
          _makerPublicKeyHexCache = pub;
          return;
        }
      }
    } catch (e) {
      debugPrint('DexCubit: maker identity load failed: $e');
    }
    final keys = _native.keypairGenerate();
    final priv = keys['secret'];
    final pub = keys['public'];
    if (priv is String && pub is String) {
      _makerSecretKeyHex = priv;
      _makerPublicKeyHexCache = pub;
      try {
        await SecurityService.writeMakerSwapSecret(_makerSecretKeyHex!);
      } catch (e) {
        debugPrint('DexCubit: maker identity persist failed: $e');
      }
    } else {
      _makerPublicKeyHexCache = '';
    }
  }

  /// Public key of the maker identity ('' if not yet ensured).
  String makerPublicKeyHex() {
    if (_makerPublicKeyHexCache == null) {
      _makerPublicKeyHexCache = '';
    }
    return _makerPublicKeyHexCache!;
  }

  static List<int> _hexToBytes(String hex) {
    final out = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  Future<void> verifyPayment({
    required String txHash,
    required String fromAddress,
    required String toAddress,
    required int amount,
    int minConfirmations = 6,
  }) async {
    emit(state.copyWith(isLoading: true, error: null));
    try {
      final r = await _post('/verify_payment', {
        'chain': state.selectedChain.id,
        'tx_hash': txHash,
        'from_address': fromAddress,
        'to_address': toAddress,
        'amount': amount,
        'min_confirmations': minConfirmations,
      });
      final proof = PaymentProofSdk.fromJson(r);
      emit(
        state.copyWith(
          isLoading: false,
          lastProof: proof,
          lastResult: proof.verified
              ? 'Payment verified: ${proof.confirmations} confirmations'
              : 'Payment NOT verified',
        ),
      );
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: 'Verification failed: $e'));
    }
  }

  Future<HtlcHashLock?> createHtlcHashLock() async {
    try {
      final r = await _post('/htlc_create_hash_lock', {});
      return HtlcHashLock.fromJson(r);
    } catch (e) {
      emit(state.copyWith(error: 'HTLC hash lock failed: $e'));
      return null;
    }
  }

  Future<HtlcScript?> buildHtlcScript({
    required String hashLock,
    required String recipientPubkey,
    required String senderPubkey,
    required int timelock,
  }) async {
    try {
      final r = await _post('/htlc_build_script', {
        'hash_lock': hashLock,
        'recipient_pubkey': recipientPubkey,
        'sender_pubkey': senderPubkey,
        'timelock': timelock,
      });
      return HtlcScript.fromJson(r);
    } catch (e) {
      emit(state.copyWith(error: 'HTLC script build failed: $e'));
      return null;
    }
  }

  Future<void> refresh() async {
    await loadOffers();
    await loadPrice();
    await loadTrades();
    await loadActiveSwaps();
    if (_swapClient != null) await loadSpvSwaps();
  }

  Future<void> _checkSwapDaemon() async {
    if (_swapClient == null) return;
    try {
      final available = await _swapClient!.isAvailable();
      emit(state.copyWith(isSwapDaemonConnected: available));
      if (available) await loadSpvSwaps();
    } catch (e) {
      emit(state.copyWith(isSwapDaemonConnected: false));
    }
  }

  Future<void> loadSpvSwaps() async {
    if (_swapClient == null) return;
    try {
      final swaps = await _swapClient!.listSwaps();
      emit(state.copyWith(spvSwaps: swaps, error: null));
      if (swaps.isNotEmpty) {
        final latest = swaps.first;
        emit(state.copyWith(lastLockType: latest.lockTypeName, lastPtlcPoint: latest.ptlcPoint));
      }
    } catch (e) {
      debugPrint('DexCubit: loadSpvSwaps failed: $e');
    }
  }

  Future<void> initiateSpvSwap({
    required String pair,
    required int xfgAmount,
    required int ctrAmount,
    required String peer,
  }) async {
    await initiateCrossChainSwap(
      pair: pair,
      xfgAmount: xfgAmount,
      ctrAmount: ctrAmount,
      peer: peer,
    );
  }

  Future<void> acceptSwap(String swapId) async {
    if (_swapClient == null) {
      emit(state.copyWith(error: 'Swap daemon not connected'));
      return;
    }
    emit(state.copyWith(isLoading: true, error: null, lastResult: null));
    try {
      final result = await _swapClient!.acceptSwap(swapId);
      emit(
        state.copyWith(
          isLoading: false,
          lastResult: 'Accepted: ${result['state'] ?? swapId}',
        ),
      );
      await loadSpvSwaps();
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: 'Accept failed: $e'));
    }
  }

  /// Direct peer-to-peer atomic swap via the local xfg-swapd (any chain).
  /// `requirePtlc` enforces PTLC (no HTLC fallback) — daemon aborts if CTR cannot do PTLC.
  Future<void> initiateCrossChainSwap({
    required String pair,
    required int xfgAmount,
    required int ctrAmount,
    required String peer,
    String role = 'alice',
    String? expectedPeerPubkey,
    bool? requirePtlc,
  }) async {
    if (_swapClient == null) {
      emit(state.copyWith(error: 'Swap daemon not connected'));
      return;
    }
    emit(state.copyWith(isSwapInitiating: true, error: null, lastResult: null));
    try {
      final swapId = await _swapClient!.initiateSwap(
        pair: pair,
        xfgAmount: xfgAmount,
        ctrAmount: ctrAmount,
        peer: peer,
        role: role,
        expectedPeerPubkey: expectedPeerPubkey,
        requirePtlc: requirePtlc ?? state.requirePtlc,
      );
      emit(
        state.copyWith(
          isSwapInitiating: false,
          lastResult: 'Swap initiated: $swapId',
        ),
      );
      await loadSpvSwaps();
    } catch (e) {
      emit(
        state.copyWith(
          isSwapInitiating: false,
          error: 'Failed to initiate swap: $e',
        ),
      );
    }
  }

  Future<void> refundSpvSwap(String swapId) async {
    if (_swapClient == null) return;
    emit(state.copyWith(isLoading: true, error: null));
    try {
      await _swapClient!.refund(swapId);
      emit(state.copyWith(isLoading: false, lastResult: 'Refunded: $swapId'));
      await loadSpvSwaps();
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: 'Refund failed: $e'));
    }
  }

  Future<void> checkSpvTimeouts() async {
    if (_swapClient == null) return;
    try {
      final result = await _swapClient!.checkTimeouts();
      if (result.refunded.isNotEmpty)
        emit(
          state.copyWith(
            lastResult: 'Refunded ${result.refunded.length} timed-out swap(s)',
          ),
        );
      await loadSpvSwaps();
    } catch (e) {
      debugPrint('DexCubit: checkSpvTimeouts failed: $e');
    }
  }

  Future<void> loadBalance({String? address}) async {
    final addr = address ?? _userAddress;
    if (addr == null || addr.isEmpty || _web3 == null) return;
    emit(state.copyWith(isBalanceLoading: true));
    try {
      final bal = await _web3!.getBalance(addr, _userAddress ?? 'eth');
      emit(state.copyWith(evmBalance: bal, isBalanceLoading: false));
    } catch (e) {
      emit(
        state.copyWith(
          isBalanceLoading: false,
          error: 'Balance fetch failed: $e',
        ),
      );
    }
  }

  Future<void> evmLockHtlc({
    required String privateKey,
    required String htlcAddress,
    required String hashlock,
    required int timelock,
    required String amountDisplay,
    String chain = 'eth',
  }) async {
    if (_web3 == null) {
      emit(state.copyWith(error: 'Web3 not configured'));
      return;
    }
    emit(state.copyWith(isLoading: true, error: null, lastResult: null));
    try {
      switchEvmChain(chain);
      final txHash = await _web3!.lockHtlc(
        privateKey: privateKey,
        htlcAddress: htlcAddress,
        hashlock: hashlock,
        timelock: timelock,
        amountDisplay: amountDisplay,
        chain: chain,
      );
      emit(
        state.copyWith(
          isLoading: false,
          htlcTxHash: txHash,
          lastResult: 'HTLC locked: $txHash',
        ),
      );
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: 'HTLC lock failed: $e'));
    }
  }

  Future<void> evmClaimHtlc({
    required String privateKey,
    required String htlcAddress,
    required String preimage,
    String chain = 'eth',
  }) async {
    if (_web3 == null) return;
    emit(state.copyWith(isLoading: true, error: null));
    try {
      switchEvmChain(chain);
      final txHash = await _web3!.claimHtlc(
        privateKey: privateKey,
        htlcAddress: htlcAddress,
        preimage: preimage,
        chain: chain,
      );
      emit(state.copyWith(isLoading: false, lastResult: 'Claimed: $txHash'));
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: 'Claim failed: $e'));
    }
  }

  Future<void> evmRefundHtlc({
    required String privateKey,
    required String htlcAddress,
    String chain = 'eth',
  }) async {
    if (_web3 == null) return;
    emit(state.copyWith(isLoading: true, error: null));
    try {
      switchEvmChain(chain);
      final txHash = await _web3!.refundHtlc(
        privateKey: privateKey,
        htlcAddress: htlcAddress,
        chain: chain,
      );
      emit(state.copyWith(isLoading: false, lastResult: 'Refunded: $txHash'));
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: 'Refund failed: $e'));
    }
  }

  @override
  Future<void> close() {
    _http.close();
    _swapClient?.dispose();
    _web3?.dispose();
    return super.close();
  }
}
