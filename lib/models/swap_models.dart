import 'erc20_token.dart';
import 'swap_pair_catalog.g.dart';

/// Swap and DEX models aligned with fuego-sdk types.
/// Maps 1:1 with Rust SDK types.rs SwapPair, SwapOffer, SwapStatus, etc.

/// Wire ids from fuego-suite `src/SwapDaemon/SwapPairCatalog.h` (append-only).
/// Absent ids are catalog pairs with no executable client: SIA(17), DOGE(20),
/// DASH(21), ZEC(22), ZANO(24), TON(27), DOT(28).
enum SwapPairSdk {
  sol(0, 'SOL', 'XFG/SOL', ChainTypeSdk.solana),
  eth(1, 'ETH', 'XFG/ETH', ChainTypeSdk.ethereum),
  xmr(2, 'XMR', 'XFG/XMR', ChainTypeSdk.monero),
  bch(3, 'BCH', 'XFG/BCH', ChainTypeSdk.bitcoinCash),
  arb(4, 'ARB', 'XFG/ARB', ChainTypeSdk.arbitrum),
  base(5, 'BASE', 'XFG/BASE', ChainTypeSdk.base),
  kmd(6, 'KMD', 'XFG/KMD', ChainTypeSdk.komodo),
  bnb(7, 'BNB', 'XFG/BNB', ChainTypeSdk.bnb),
  dcr(8, 'DCR', 'XFG/DCR', ChainTypeSdk.decred),
  btc(9, 'BTC', 'XFG/BTC', ChainTypeSdk.bitcoin),
  ltc(10, 'LTC', 'XFG/LTC', ChainTypeSdk.litecoin),
  poly(11, 'POLY', 'XFG/POLY', ChainTypeSdk.polygon),
  gleec(12, 'GLEEC', 'XFG/GLEEC', ChainTypeSdk.gleec),
  robinhood(13, 'RHC', 'XFG/RHC', ChainTypeSdk.robinhood),
  avax(14, 'AVAX', 'XFG/AVAX', ChainTypeSdk.avax),
  cro(15, 'CRO', 'XFG/CRO', ChainTypeSdk.cro),
  bob(16, 'BOB', 'XFG/BOB', ChainTypeSdk.bob),
  unichain(18, 'UNI', 'XFG/UNI', ChainTypeSdk.unichain),
  plasma(19, 'XPL', 'XFG/XPL', ChainTypeSdk.plasma),
  pulsex(23, 'PLS', 'XFG/PLS', ChainTypeSdk.pulsex),
  monad(25, 'MON', 'XFG/MON', ChainTypeSdk.monad),
  optimism(26, 'OP', 'XFG/OP', ChainTypeSdk.optimism),
  linea(29, 'LINEA', 'XFG/LINEA', ChainTypeSdk.linea),
  zksync(30, 'ZKS', 'XFG/ZKS', ChainTypeSdk.zksync),
  hyperevm(31, 'HYPER', 'XFG/HYPER', ChainTypeSdk.hyperevm),
  ink(32, 'INK', 'XFG/INK', ChainTypeSdk.ink),
  rsk(33, 'RSK', 'XFG/RSK', ChainTypeSdk.rsk),
  gnosis(34, 'GNO', 'XFG/GNO', ChainTypeSdk.gnosis),
  flare(35, 'FLR', 'XFG/FLR', ChainTypeSdk.flare),
  kaia(36, 'KAIA', 'XFG/KAIA', ChainTypeSdk.kaia),
  scroll(37, 'SCR', 'XFG/SCR', ChainTypeSdk.scroll),
  abstract(38, 'ABS', 'XFG/ABS', ChainTypeSdk.abstract),
  plume(39, 'PLUME', 'XFG/PLUME', ChainTypeSdk.plume),
  soneium(40, 'SONEIUM', 'XFG/SONEIUM', ChainTypeSdk.soneium),
  doma(41, 'DOMA', 'XFG/DOMA', ChainTypeSdk.doma),
  beam(42, 'BEAM', 'XFG/BEAM', ChainTypeSdk.beam),
  moonriver(43, 'MOVR', 'XFG/MOVR', ChainTypeSdk.moonriver),
  peaq(44, 'PEAQ', 'XFG/PEAQ', ChainTypeSdk.peaq),
  sei(45, 'SEI', 'XFG/SEI', ChainTypeSdk.sei);

  final int id;
  final String ticker;
  final String displayName;
  final ChainTypeSdk chain;
  const SwapPairSdk(this.id, this.ticker, this.displayName, this.chain);

  /// Unknown ids are refused: a record for a pair this wallet cannot
  /// represent must never be shown as an ETH swap.
  static SwapPairSdk fromId(int id) =>
      tryFromId(id) ?? (throw FormatException('unknown swap pair id $id'));

  /// This pair's row in xfg-swapd's catalog (generated from fuego-suite).
  SwapPairCatalogEntry get catalog => kSwapPairCatalog[id];

  static SwapPairSdk? tryFromId(int id) {
    for (final p in SwapPairSdk.values) {
      if (p.id == id) return p;
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

  static SwapLockTypeSdk fromId(int id) => SwapLockTypeSdk.values.firstWhere(
    (v) => v.id == id,
    orElse: () => SwapLockTypeSdk.htlc,
  );

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

/// Supported chains for SPV verification. Ids 0-12 are the Rust SDK
/// `ChainType` discriminants walletd's `/verify_payment` accepts; later ids
/// are wallet-side only. Append-only.
enum ChainTypeSdk {
  fuego(0, 'XFG', 'Fuego'),
  solana(1, 'SOL', 'Solana'),
  ethereum(2, 'ETH', 'Ethereum', EvmChainKey.eth),
  monero(3, 'XMR', 'Monero'),
  bitcoinCash(4, 'BCH', 'Bitcoin Cash'),
  arbitrum(5, 'ARB', 'Arbitrum', EvmChainKey.arb),
  base(6, 'BASE', 'Base', EvmChainKey.base),
  komodo(7, 'KMD', 'Komodo'),
  bnb(8, 'BNB', 'BNB Chain', EvmChainKey.bsc),
  decred(9, 'DCR', 'Decred'),
  bitcoin(10, 'BTC', 'Bitcoin'),
  litecoin(11, 'LTC', 'Litecoin'),
  polygon(12, 'POLY', 'Polygon', EvmChainKey.poly),
  avax(13, 'AVAX', 'Avalanche', EvmChainKey.avax),
  gleec(14, 'GLEEC', 'Gleec Chain', EvmChainKey.gleec),
  robinhood(15, 'RHC', 'Robinhood Chain', EvmChainKey.rh),
  cro(16, 'CRO', 'Cronos', EvmChainKey.cro),
  bob(17, 'BOB', 'BOB', EvmChainKey.bob),
  unichain(18, 'UNI', 'Unichain', EvmChainKey.uni),
  plasma(19, 'XPL', 'Plasma', EvmChainKey.xpl),
  pulsex(20, 'PLS', 'PulseChain', EvmChainKey.pls),
  monad(21, 'MON', 'Monad', EvmChainKey.monad),
  optimism(22, 'OP', 'Optimism', EvmChainKey.op),
  linea(23, 'LINEA', 'Linea', EvmChainKey.linea),
  zksync(24, 'ZKS', 'ZKsync Era', EvmChainKey.zksync),
  hyperevm(25, 'HYPER', 'HyperEVM', EvmChainKey.hyperevm),
  ink(26, 'INK', 'Ink', EvmChainKey.ink),
  rsk(27, 'RSK', 'Rootstock', EvmChainKey.rsk),
  gnosis(28, 'GNO', 'Gnosis', EvmChainKey.gnosis),
  flare(29, 'FLR', 'Flare', EvmChainKey.flare),
  kaia(30, 'KAIA', 'Kaia', EvmChainKey.kaia),
  scroll(31, 'SCR', 'Scroll', EvmChainKey.scroll),
  abstract(32, 'ABS', 'Abstract', EvmChainKey.abstract),
  plume(33, 'PLUME', 'Plume', EvmChainKey.plume),
  soneium(34, 'SONEIUM', 'Soneium', EvmChainKey.soneium),
  doma(35, 'DOMA', 'Doma', EvmChainKey.doma),
  beam(36, 'BEAM', 'Beam', EvmChainKey.beam),
  moonriver(37, 'MOVR', 'Moonriver', EvmChainKey.moonriver),
  peaq(38, 'PEAQ', 'peaq', EvmChainKey.peaq),
  sei(39, 'SEI', 'Sei', EvmChainKey.sei);

  final int id;
  final String symbol;
  final String name;
  final EvmChainKey? evm;
  const ChainTypeSdk(this.id, this.symbol, this.name, [this.evm]);

  bool get isEvm => evm != null;
  bool get isBtcFamily =>
      this == ChainTypeSdk.bitcoinCash ||
      this == ChainTypeSdk.komodo ||
      this == ChainTypeSdk.decred ||
      this == ChainTypeSdk.bitcoin ||
      this == ChainTypeSdk.litecoin;

  static ChainTypeSdk fromId(int id) => ChainTypeSdk.values.firstWhere(
    (c) => c.id == id,
    orElse: () => ChainTypeSdk.fuego,
  );
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

  static SwapStateSdk fromString(String s) => SwapStateSdk.values.firstWhere(
    (v) => v.name == s,
    orElse: () => SwapStateSdk.open,
  );
}

/// Swap offer on the orderbook.
class SwapOfferSdk {
  final String offerId;
  final String makerPubKey;
  final SwapPairSdk pair;
  final bool sellXfg;
  final int amount;
  final int rateNum;
  final int createdAt;
  final int expiresAt;

  const SwapOfferSdk({
    required this.offerId,
    required this.makerPubKey,
    required this.pair,
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
  String get pairLabel => pair.displayName;

  SwapOfferSdk copyWith({String? makerPubKey}) => SwapOfferSdk(
    offerId: offerId,
    makerPubKey: makerPubKey ?? this.makerPubKey,
    pair: pair,
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
      pair: SwapPairSdk.fromId(_intValue(j['pair'])),
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
    'pair': pair.id,
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
  final SwapStateSdk state;
  final SwapPairSdk pair;
  final int amount;
  final String makerPubkey;
  final String? takerPubkey;
  final int createdAt;
  final int updatedAt;

  const SwapStatusSdk({
    required this.swapId,
    required this.state,
    required this.pair,
    required this.amount,
    required this.makerPubkey,
    this.takerPubkey,
    required this.createdAt,
    required this.updatedAt,
  });

  factory SwapStatusSdk.fromJson(Map<String, dynamic> j) => SwapStatusSdk(
    swapId: j['swapId'] as String? ?? j['swap_id'] as String? ?? '',
    state: SwapStateSdk.fromString(j['state'] as String? ?? 'open'),
    pair: SwapPairSdk.fromId(j['pair'] as int? ?? 0),
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
  final SwapPairSdk pair;
  final bool sellXfg;
  final int amount;
  final int price;
  final int timestamp;

  const SwapTradeSdk({
    required this.tradeId,
    required this.pair,
    required this.sellXfg,
    required this.amount,
    required this.price,
    required this.timestamp,
  });

  factory SwapTradeSdk.fromJson(Map<String, dynamic> j) => SwapTradeSdk(
    tradeId: j['tradeId'] as String? ?? j['trade_id'] as String? ?? '',
    pair: SwapPairSdk.fromId(j['pair'] as int? ?? 0),
    sellXfg: j['sellXfg'] as bool? ?? j['sell_xfg'] as bool? ?? true,
    amount: j['amount'] as int? ?? 0,
    price: j['price'] as int? ?? 0,
    timestamp: j['timestamp'] as int? ?? 0,
  );
}

/// Price data for a trading pair.
class SwapPriceSdk {
  final SwapPairSdk pair;
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
    pair: pairOverride ?? SwapPairSdk.fromId(_intValue(j['pair'])),
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

/// Orderbook level (bid or ask).
class OrderLevelSdk {
  final String price;
  final String amount;
  final int count;

  const OrderLevelSdk({
    required this.price,
    required this.amount,
    required this.count,
  });

  factory OrderLevelSdk.fromJson(Map<String, dynamic> j) => OrderLevelSdk(
    price: j['price']?.toString() ?? '0',
    amount: j['amount']?.toString() ?? '0',
    count: j['count'] as int? ?? j['orderCount'] as int? ?? 0,
  );
}

/// Orderbook state snapshot.
class OrderBookStateSdk {
  final List<OrderLevelSdk> bids;
  final List<OrderLevelSdk> asks;
  final String lastPrice;
  final String volume24h;

  const OrderBookStateSdk({
    required this.bids,
    required this.asks,
    required this.lastPrice,
    required this.volume24h,
  });

  factory OrderBookStateSdk.fromJson(
    Map<String, dynamic> j,
  ) => OrderBookStateSdk(
    bids:
        (j['bids'] as List<dynamic>?)
            ?.map((e) => OrderLevelSdk.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [],
    asks:
        (j['asks'] as List<dynamic>?)
            ?.map((e) => OrderLevelSdk.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [],
    lastPrice: j['last_price']?.toString() ?? j['lastPrice']?.toString() ?? '0',
    volume24h: j['volume_24h']?.toString() ?? j['volume24h']?.toString() ?? '0',
  );
}

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
  final ChainTypeSdk chain;
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
    chain: ChainTypeSdk.fromId(j['chain_id'] as int? ?? 0),
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
    'chain_id': chain.id,
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
