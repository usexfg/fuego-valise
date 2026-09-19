/// Swap and DEX models aligned with fuego-sdk types.
/// Maps 1:1 with Rust SDK types.rs SwapPair, SwapOffer, SwapStatus, etc.

/// Supported swap pair IDs — mirrors `XfgSwap::SwapPair` in
/// fuego-suite `src/SwapDaemon/SwapTypes.h` (ids 0-28, no gaps).
///
/// [ticker] is what the wallet shows. [daemonName] is the string
/// `swapPairFromString()` parses in `src/SwapDaemon/SwapTypes.cpp` — the two
/// differ for six pairs (RHC/UNI/XPL/PLS/MON/KMD), and sending the display
/// ticker where the daemon name is required is rejected as "Unknown swap pair".
enum SwapPairSdk {
  sol(0, 'SOL', 'XFG/SOL', 'SOL'),
  eth(1, 'ETH', 'XFG/ETH', 'ETH'),
  xmr(2, 'XMR', 'XFG/XMR', 'XMR'),
  bch(3, 'BCH', 'XFG/BCH', 'BCH'),
  arb(4, 'ARB', 'XFG/ARB', 'ARB'),
  base(5, 'BASE', 'XFG/BASE', 'BASE'),
  kmd(6, 'KMD', 'XFG/KMD', 'KMD_SPV'),
  bnb(7, 'BNB', 'XFG/BNB', 'BNB'),
  dcr(8, 'DCR', 'XFG/DCR', 'DCR'),
  btc(9, 'BTC', 'XFG/BTC', 'BTC'),
  ltc(10, 'LTC', 'XFG/LTC', 'LTC'),
  poly(11, 'POLY', 'XFG/POLY', 'POLYGON'),
  gleec(12, 'GLEEC', 'XFG/GLEEC', 'GLEEC'),
  robinhood(13, 'RHC', 'XFG/RHC', 'ROBINHOOD'),
  avax(14, 'AVAX', 'XFG/AVAX', 'AVAX'),
  cro(15, 'CRO', 'XFG/CRO', 'CRO'),
  bob(16, 'BOB', 'XFG/BOB', 'BOB'),
  sia(17, 'SIA', 'XFG/SIA', 'SIA'),
  unichain(18, 'UNI', 'XFG/UNI', 'UNICHAIN'),
  plasma(19, 'XPL', 'XFG/XPL', 'PLASMA'),
  doge(20, 'DOGE', 'XFG/DOGE', 'DOGE'),
  dash(21, 'DASH', 'XFG/DASH', 'DASH'),
  zec(22, 'ZEC', 'XFG/ZEC', 'ZEC'),
  pulsex(23, 'PLS', 'XFG/PLS', 'PULSEX'),
  zano(24, 'ZANO', 'XFG/ZANO', 'ZANO'),
  monad(25, 'MON', 'XFG/MON', 'MONAD'),
  optimism(26, 'OP', 'XFG/OP', 'OPTIMISM'),
  ton(27, 'TON', 'XFG/TON', 'TON'),
  dot(28, 'DOT', 'XFG/DOT', 'DOT');

  final int id;
  final String ticker;
  final String displayName;

  /// The exact string `swapPairFromString()` accepts. Never the display
  /// ticker — see the six divergences noted above.
  final String daemonName;

  const SwapPairSdk(this.id, this.ticker, this.displayName, this.daemonName);

  /// Null when [id] is not a pair this build knows. Callers must decide what
  /// an unknown pair means rather than silently rendering it as another asset.
  static SwapPairSdk? tryFromId(int id) {
    for (final p in SwapPairSdk.values) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Null for an unrecognised ticker or daemon name (case-insensitive).
  static SwapPairSdk? tryFromName(String name) {
    final u = name.trim().toUpperCase();
    if (u.isEmpty) return null;
    for (final p in SwapPairSdk.values) {
      if (p.ticker == u || p.daemonName == u) return p;
    }
    return null;
  }
}

/// PTLC lock type (mirrors Rust SwapLockType / C++ SwapLockType).
/// htlc=0 legacy hash, ptlc=1 pure point, bridge=2 PTLC on XFG + HTLC on CTR.
enum SwapLockTypeSdk {
  htlc(0, 'HTLC'),
  ptlc(1, 'PTLC'),
  bridge(2, 'BRIDGE');

  final int id;
  final String label;
  const SwapLockTypeSdk(this.id, this.label);

  /// Null for an id this build does not know — an unknown lock type must not
  /// be shown as HTLC, since that is a claim about how the swap is secured.
  static SwapLockTypeSdk? tryFromId(int id) {
    for (final v in SwapLockTypeSdk.values) {
      if (v.id == id) return v;
    }
    return null;
  }

  static SwapLockTypeSdk fromString(String s) {
    final u = s.toUpperCase();
    if (u == 'PTLC') return ptlc;
    if (u == 'BRIDGE' || u == 'PTLC_HTLC_BRIDGE') return bridge;
    return htlc;
  }

  bool get isPtlcPure => this == ptlc;
  bool get isBridge => this == bridge;
  bool get isHtlc => this == htlc;
}

/// Wallet-local chain classification, one entry per [SwapPairSdk] plus Fuego.
/// Ids are wallet-internal and are NOT the C++ SwapPair ids — use
/// [SwapPairSdk.id] wherever a daemon pair id is meant.
enum ChainTypeSdk {
  fuego(0, 'XFG', 'Fuego'),
  solana(1, 'SOL', 'Solana'),
  ethereum(2, 'ETH', 'Ethereum'),
  monero(3, 'XMR', 'Monero'),
  bitcoinCash(4, 'BCH', 'Bitcoin Cash'),
  arbitrum(5, 'ARB', 'Arbitrum'),
  base(6, 'BASE', 'Base'),
  komodo(7, 'KMD', 'Komodo'),
  bnb(8, 'BNB', 'BNB Chain'),
  decred(9, 'DCR', 'Decred'),
  bitcoin(10, 'BTC', 'Bitcoin'),
  litecoin(11, 'LTC', 'Litecoin'),
  polygon(12, 'POLY', 'Polygon'),
  avax(13, 'AVAX', 'Avalanche'),
  gleec(14, 'GLEEC', 'Gleec Chain'),
  robinhood(15, 'RHC', 'Robinhood Chain'),
  cro(16, 'CRO', 'Cronos'),
  bob(17, 'BOB', 'BOB'),
  unichain(18, 'UNI', 'Unichain'),
  plasma(19, 'XPL', 'Plasma'),
  pulsex(20, 'PLS', 'PulseChain'),
  monad(21, 'MON', 'Monad'),
  optimism(22, 'OP', 'Optimism'),
  sia(23, 'SIA', 'Sia'),
  doge(24, 'DOGE', 'Dogecoin'),
  dash(25, 'DASH', 'Dash'),
  zec(26, 'ZEC', 'Zcash'),
  zano(27, 'ZANO', 'Zano'),
  ton(28, 'TON', 'TON'),
  dot(29, 'DOT', 'Polkadot');

  final int id;
  final String symbol;
  final String name;
  const ChainTypeSdk(this.id, this.symbol, this.name);

  bool get isEvm =>
      this == ChainTypeSdk.ethereum ||
      this == ChainTypeSdk.arbitrum ||
      this == ChainTypeSdk.base ||
      this == ChainTypeSdk.bnb ||
      this == ChainTypeSdk.polygon ||
      this == ChainTypeSdk.avax ||
      this == ChainTypeSdk.gleec ||
      this == ChainTypeSdk.robinhood ||
      this == ChainTypeSdk.cro ||
      this == ChainTypeSdk.bob ||
      this == ChainTypeSdk.unichain ||
      this == ChainTypeSdk.plasma ||
      this == ChainTypeSdk.pulsex ||
      this == ChainTypeSdk.monad ||
      this == ChainTypeSdk.optimism;

  /// UTXO chains the in-app `signmessage` reserve proof is wired for.
  /// DOGE/DASH/ZEC are UTXO too but have no verified P2PKH version bytes
  /// here, so they stay out and fall to the explicit unsupported branch
  /// rather than producing a proof for the wrong address.
  bool get isBtcFamily =>
      this == ChainTypeSdk.bitcoinCash ||
      this == ChainTypeSdk.komodo ||
      this == ChainTypeSdk.decred ||
      this == ChainTypeSdk.bitcoin ||
      this == ChainTypeSdk.litecoin;

  /// Null for an id this build does not know.
  static ChainTypeSdk? tryFromId(int id) {
    for (final c in ChainTypeSdk.values) {
      if (c.id == id) return c;
    }
    return null;
  }
}

/// Swap state machine states.
enum SwapStateSdk {
  open,
  matched,
  makerLocked,
  takerLocked,
  makerRevealed,
  completed,
  cancelled;

  /// Null for a state name this build does not know. Rendering an unknown
  /// daemon state as `open` hides refunds and failures.
  static SwapStateSdk? tryFromString(String s) {
    for (final v in SwapStateSdk.values) {
      if (v.name == s) return v;
    }
    return null;
  }
}

/// Swap offer on the orderbook.
class SwapOfferSdk {
  final String offerId;
  final String makerPubKey;

  /// The raw daemon pair id, always preserved. [pair] is null when this build
  /// does not know the id — the offer is then shown, but not actionable.
  final int pairId;
  final bool sellXfg;
  final int amount;
  final int rateNum;
  final int createdAt;
  final int expiresAt;

  const SwapOfferSdk({
    required this.offerId,
    required this.makerPubKey,
    required this.pairId,
    required this.sellXfg,
    required this.amount,
    required this.rateNum,
    required this.createdAt,
    required this.expiresAt,
  });

  double get xfgPerCounterparty => rateNum / 1e7;
  double get counterpartyPerXfg =>
      xfgPerCounterparty > 0 ? 1 / xfgPerCounterparty : 0;
  double get rate => counterpartyPerXfg;

  SwapPairSdk? get pair => SwapPairSdk.tryFromId(pairId);

  /// True when the wallet knows this pair well enough to act on it.
  bool get isKnownPair => pair != null;

  String get pairLabel => pair?.displayName ?? 'XFG/PAIR_$pairId';
  String get ticker => pair?.ticker ?? 'PAIR_$pairId';

  SwapOfferSdk copyWith({String? makerPubKey}) => SwapOfferSdk(
    offerId: offerId,
    makerPubKey: makerPubKey ?? this.makerPubKey,
    pairId: pairId,
    sellXfg: sellXfg,
    amount: amount,
    rateNum: rateNum,
    createdAt: createdAt,
    expiresAt: expiresAt,
  );

  factory SwapOfferSdk.fromJson(Map<String, dynamic> j) {
    return SwapOfferSdk(
      offerId: j['offerId']?.toString() ?? j['offer_id']?.toString() ?? '',
      makerPubKey:
          j['makerPubKey']?.toString() ?? j['maker_pubkey']?.toString() ?? '',
      pairId: _intValue(j['pair']),
      sellXfg:
          j['sellXfg'] as bool? ??
          j['sell_xfg'] as bool? ??
          j['isSell'] as bool? ??
          true,
      amount: _intValue(j['amount'] ?? j['xfgAmount'] ?? j['xfg_amount']),
      rateNum: _intValue(j['rateNum'] ?? j['rate_num'] ?? j['rate']),
      createdAt: _intValue(j['createdAt'] ?? j['created_at'] ?? j['timestamp']),
      expiresAt: _intValue(j['expiresAt'] ?? j['expires_at']),
    );
  }

  static int _intValue(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Map<String, dynamic> toJson() => {
    'offerId': offerId,
    'makerPubKey': makerPubKey,
    'pair': pairId,
    'sellXfg': sellXfg,
    'amount': amount,
    'rateNum': rateNum,
    'createdAt': createdAt,
    'expiresAt': expiresAt,
  };
}

/// Active swap status.
class SwapStatusSdk {
  final String swapId;
  final SwapStateSdk? state;
  final String stateName;
  final int pairId;
  final int amount;
  final String makerPubkey;
  final String? takerPubkey;
  final int createdAt;
  final int updatedAt;

  const SwapStatusSdk({
    required this.swapId,
    required this.state,
    required this.stateName,
    required this.pairId,
    required this.amount,
    required this.makerPubkey,
    this.takerPubkey,
    required this.createdAt,
    required this.updatedAt,
  });

  factory SwapStatusSdk.fromJson(Map<String, dynamic> j) => SwapStatusSdk(
    swapId: j['swapId'] as String? ?? j['swap_id'] as String? ?? '',
    state: SwapStateSdk.tryFromString(j['state'] as String? ?? ''),
    stateName: j['state'] as String? ?? '',
    pairId: (j['pair'] as num?)?.toInt() ?? 0,
    amount: j['amount'] as int? ?? 0,
    makerPubkey:
        j['makerPubkey'] as String? ?? j['maker_pubkey'] as String? ?? '',
    takerPubkey: j['takerPubkey'] as String? ?? j['taker_pubkey'] as String?,
    createdAt: j['createdAt'] as int? ?? j['created_at'] as int? ?? 0,
    updatedAt: j['updatedAt'] as int? ?? j['updated_at'] as int? ?? 0,
  );
}

/// Historical trade record.
class SwapTradeSdk {
  final String tradeId;
  final int pairId;
  final bool sellXfg;
  final int amount;
  final int price;
  final int timestamp;

  const SwapTradeSdk({
    required this.tradeId,
    required this.pairId,
    required this.sellXfg,
    required this.amount,
    required this.price,
    required this.timestamp,
  });

  factory SwapTradeSdk.fromJson(Map<String, dynamic> j) => SwapTradeSdk(
    tradeId: j['tradeId'] as String? ?? j['trade_id'] as String? ?? '',
    pairId: (j['pair'] as num?)?.toInt() ?? 0,
    sellXfg: j['sellXfg'] as bool? ?? j['sell_xfg'] as bool? ?? true,
    amount: j['amount'] as int? ?? 0,
    price: j['price'] as int? ?? 0,
    timestamp: j['timestamp'] as int? ?? 0,
  );
}

/// Price data for a trading pair.
class SwapPriceSdk {
  final SwapPairSdk? pair;
  final String bid;
  final String ask;
  final String last;
  final String volume24h;
  final String change24h;
  final String status;

  const SwapPriceSdk({
    required this.pair,
    required this.bid,
    required this.ask,
    required this.last,
    required this.volume24h,
    required this.change24h,
    this.status = '',
  });

  factory SwapPriceSdk.fromJson(
    Map<String, dynamic> j, {
    SwapPairSdk? pairOverride,
  }) => SwapPriceSdk(
    pair: pairOverride ?? SwapPairSdk.tryFromId(_intValue(j['pair'])),
    bid: _firstString(j, const ['bid', 'compositeRate', 'twap']),
    ask: _firstString(j, const ['ask', 'compositeRate', 'twap']),
    last: _firstString(j, const ['last', 'compositeRate', 'twap', 'seedRate']),
    volume24h: _firstString(j, const ['volume_24h', 'volume24h']),
    change24h: _firstString(j, const ['change_24h', 'change24h']),
    status: j['status']?.toString() ?? '',
  );

  static int _intValue(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _firstString(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value != null && value.toString().isNotEmpty) return value.toString();
    }
    return '0';
  }
}

// NOTE: the orderbook model lives in `heat_amm.dart` as OrderBookState /
// OrderBookLevel, which matches `COMMAND_RPC_GET_ORDER_BOOK` exactly (bids,
// asks, spread, height, status; levels of price/amount/orderCount).
//
// A second pair, OrderBookStateSdk / OrderLevelSdk, used to live here. It
// parsed `last_price` and `volume_24h` — neither exists in that response —
// and dropped `spread` and `height`, which do. It was filled by
// DexCubit.loadOrderbook(), which nothing called and no widget read, via a
// json_rpc method name (`getorderbook`) the walletd proxy does not route.
// Removed rather than left as a second, wrong answer to the same question.

/// HTLC hash lock result.
class HtlcHashLock {
  final String preimage;
  final String hash;

  const HtlcHashLock({required this.preimage, required this.hash});

  factory HtlcHashLock.fromJson(Map<String, dynamic> j) => HtlcHashLock(
    preimage: j['preimage'] as String? ?? '',
    hash: j['hash'] as String? ?? '',
  );
}

/// HTLC script build result.
class HtlcScript {
  final String script;
  final bool ok;
  final String? error;

  const HtlcScript({required this.script, required this.ok, this.error});

  factory HtlcScript.fromJson(Map<String, dynamic> j) => HtlcScript(
    script: j['script'] as String? ?? '',
    ok: j['ok'] as bool? ?? false,
    error: j['error'] as String?,
  );
}

/// Payment proof for cross-chain SPV verification.
class PaymentProofSdk {
  final ChainTypeSdk? chain;
  final int chainId;
  final String txHash;
  final int amount;
  final String fromAddress;
  final String toAddress;
  final int confirmations;
  final int blockHeight;
  final String blockHash;
  final String merkleRoot;
  final List<String> merkleProof;
  final int txIndex;
  final int totalTxs;
  final bool verified;

  const PaymentProofSdk({
    required this.chain,
    required this.chainId,
    required this.txHash,
    required this.amount,
    required this.fromAddress,
    required this.toAddress,
    required this.confirmations,
    required this.blockHeight,
    required this.blockHash,
    required this.merkleRoot,
    required this.merkleProof,
    required this.txIndex,
    required this.totalTxs,
    required this.verified,
  });

  factory PaymentProofSdk.fromJson(Map<String, dynamic> j) => PaymentProofSdk(
    chain: ChainTypeSdk.tryFromId(j['chain_id'] as int? ?? 0),
    chainId: j['chain_id'] as int? ?? 0,
    txHash: j['tx_hash'] as String? ?? '',
    amount: j['amount'] as int? ?? 0,
    fromAddress: j['from_address'] as String? ?? '',
    toAddress: j['to_address'] as String? ?? '',
    confirmations: j['confirmations'] as int? ?? 0,
    blockHeight: j['block_height'] as int? ?? 0,
    blockHash: j['block_hash'] as String? ?? '',
    merkleRoot: j['merkle_root'] as String? ?? '',
    merkleProof:
        (j['merkle_proof'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [],
    txIndex: j['tx_index'] as int? ?? 0,
    totalTxs: j['total_txs'] as int? ?? 0,
    verified: j['verified'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'chain_id': chainId,
    'tx_hash': txHash,
    'amount': amount,
    'from_address': fromAddress,
    'to_address': toAddress,
    'confirmations': confirmations,
    'block_height': blockHeight,
    'block_hash': blockHash,
    'merkle_root': merkleRoot,
    'merkle_proof': merkleProof,
    'tx_index': txIndex,
    'total_txs': totalTxs,
    'verified': verified,
  };
}
