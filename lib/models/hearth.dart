import '../core/constants.dart';

/// Hearth — the XFG/ΗΞΔŦ pool and orderbook.
///
/// There is one pool and its name is Hearth. fuegod spells the endpoints
/// `/amm_quote` and `/amm_pool_info`, which is its own shorthand for the same
/// thing (`RpcServer.cpp:210` heads that block "HEAT / Hearth AMM endpoints",
/// and both handlers call `getAmmPoolInfo()` and return `hearth_twap`). The
/// wire names stay as the daemon spells them; everything here is named
/// Hearth.
///
/// Field names and types match the fuego-suite C++ response structs exactly.
/// See: CoreRpcServerCommandsDefinitions.h lines 2448-2497 (HeatMetrics),
///      CoreRpcServerCommandsDefinitions.h lines 1613-1653 (HearthPool),
///      CoreRpcServerCommandsDefinitions.h lines 1047-1087 (OrderBookState),
///      CoreRpcServerCommandsDefinitions.h lines 2500+ (HearthQuote).

/// Response to `/get_heat_metrics`
/// C++: COMMAND_RPC_GET_HEAT_METRICS (CoreRpcServerCommandsDefinitions.h:2448-2497)
class HeatMetrics {
  final int heatSupply;
  final int heatOnDeposit;
  final int burnedXfg;
  final int totalBurnedXfg;

  /// Mint price numerator / denominator — ΗΞΔŦ per XFG.
  ///
  /// There is no redemption for ΗΞΔŦ: XFG is burned to mint it, and nothing
  /// converts it back. The daemon's JSON keys are still `redemption_price_*`
  /// and `redemption_rate_*` (`COMMAND_RPC_GET_HEAT_METRICS`); the wallet
  /// reads those and also accepts `mint_price_*` / `mint_rate_*` so a rename
  /// on the daemon side needs no change here.
  final int mintPriceNum;
  final int mintPriceDenom;
  final int mintRateNum;
  final int mintRateDenom;
  final int treasuryBalance;
  final int treasuryCounterXfg;
  final int swfBurnedXfgPendingHeat;
  final int swfHeatBalance;
  final int epochSwapFees;
  final int vaultHeatCdFeePool;
  final int vaultHeatLpReserve;
  final int vaultHeatGeneral;
  final int vaultHeatSwf;
  final int vaultXfgCdFeePool;
  final int vaultXfgLpReserve;
  final int vaultXfgGeneral;
  final String status;

  const HeatMetrics({
    required this.heatSupply,
    required this.heatOnDeposit,
    required this.burnedXfg,
    required this.totalBurnedXfg,
    required this.mintPriceNum,
    required this.mintPriceDenom,
    required this.mintRateNum,
    required this.mintRateDenom,
    required this.treasuryBalance,
    required this.treasuryCounterXfg,
    required this.swfBurnedXfgPendingHeat,
    required this.swfHeatBalance,
    required this.epochSwapFees,
    required this.vaultHeatCdFeePool,
    required this.vaultHeatLpReserve,
    required this.vaultHeatGeneral,
    required this.vaultHeatSwf,
    required this.vaultXfgCdFeePool,
    required this.vaultXfgLpReserve,
    required this.vaultXfgGeneral,
    required this.status,
  });

  factory HeatMetrics.fromJson(Map<String, dynamic> json) {
    return HeatMetrics(
      heatSupply: _u64(json['heat_supply']),
      heatOnDeposit: _u64(json['heat_on_deposit']),
      burnedXfg: _u64(json['burned_xfg']),
      totalBurnedXfg: _u64(json['total_burned_xfg']),
      mintPriceNum: _u64(
        json['mint_price_num'] ?? json['redemption_price_num'],
      ),
      mintPriceDenom: _u64(
        json['mint_price_denom'] ?? json['redemption_price_denom'],
      ),
      mintRateNum: _u64(json['mint_rate_num'] ?? json['redemption_rate_num']),
      mintRateDenom: _u64(
        json['mint_rate_denom'] ?? json['redemption_rate_denom'],
      ),
      treasuryBalance: _u64(json['treasury_balance']),
      treasuryCounterXfg: _u64(json['treasury_counter_xfg']),
      swfBurnedXfgPendingHeat: _u64(json['swf_burned_xfg_pending_heat']),
      // fuegod's COMMAND_RPC_GET_HEAT_METRICS has no `swf_heat_balance`
      // member; the SWF balance it does report is `vault_heat_swf`.
      swfHeatBalance: _u64(json['vault_heat_swf'] ?? json['swf_heat_balance']),
      epochSwapFees: _u64(json['epoch_swap_fees']),
      vaultHeatCdFeePool: _u64(json['vault_heat_cd_fee_pool']),
      vaultHeatLpReserve: _u64(json['vault_heat_lp_reserve']),
      vaultHeatGeneral: _u64(json['vault_heat_general']),
      vaultHeatSwf: _u64(json['vault_heat_swf']),
      vaultXfgCdFeePool: _u64(json['vault_xfg_cd_fee_pool']),
      vaultXfgLpReserve: _u64(json['vault_xfg_lp_reserve']),
      vaultXfgGeneral: _u64(json['vault_xfg_general']),
      status: json['status'] as String? ?? '',
    );
  }

  /// Mint price (ΗΞΔŦ per XFG) as a double, or null when unreported.
  double? get mintPriceValue =>
      mintPriceDenom != 0 ? mintPriceNum / mintPriceDenom : null;

  /// Mint price as a display string, or '—'.
  String get mintPrice => mintPriceValue?.toStringAsFixed(6) ?? '—';

  /// Mint rate as a double, or null when unreported.
  double? get mintRate =>
      mintRateDenom != 0 ? mintRateNum / mintRateDenom : null;

  /// ΗΞΔŦ per XFG, or '—' when the daemon reports no price.
  String get formattedMintPrice {
    final v = mintPriceValue;
    if (v == null) return '—';
    return '${v.toStringAsFixed(6)} ΗΞΔŦ/XFG';
  }

  /// CD yield (APY) as a percent, or null.
  ///
  /// `on_get_heat_metrics` in fuego-suite assigns every response field except
  /// the rate pair, so a zero denominator means "the daemon did not report a
  /// rate" — not "the rate is zero".
  double? get currentApy {
    final r = mintRate;
    return r == null ? null : r * 100;
  }

  /// HEAT in circulation, display units.
  String get supply => atomicToDisplay(heatSupply);

  /// Treasury balance, display units.
  String get treasury => atomicToDisplay(treasuryBalance);

  /// CD yield as a display string, or '—' when unreported.
  String get cdYield {
    final apy = currentApy;
    return apy == null ? '—' : '${apy.toStringAsFixed(2)}%';
  }

  /// XFG LP reserve, display units.
  String get poolXfg => atomicToDisplay(vaultXfgLpReserve);

  /// HEAT LP reserve, display units.
  String get poolHeat => atomicToDisplay(vaultHeatLpReserve);

  /// De-facto mint target: the current mint price.
  String get piTarget => formattedMintPrice;
}

/// Single level in the orderbook.
///
/// C++: `COMMAND_RPC_GET_ORDER_BOOK::response::OrderBookLevelJson`
/// (`CoreRpcServerCommandsDefinitions.h:1061-1071`) — `price` and `amount` are
/// `uint64_t`, both in atomic units. `price` carries the same scaling as
/// `spot_price`: ΗΞΔŦ-per-XFG × COIN. Rendering either raw is off by 10^7.
class OrderBookLevel {
  /// ΗΞΔŦ-per-XFG × COIN.
  final int priceAtomic;

  /// XFG, atomic units.
  final int amountAtomic;
  final int orderCount;

  const OrderBookLevel({
    required this.priceAtomic,
    required this.amountAtomic,
    required this.orderCount,
  });

  factory OrderBookLevel.fromJson(Map<String, dynamic> json) {
    return OrderBookLevel(
      priceAtomic: _u64(json['price']),
      amountAtomic: _u64(json['amount']),
      orderCount: _u64(json['orderCount']),
    );
  }

  /// ΗΞΔŦ per XFG.
  double get price => priceAtomic / atomicPerCoin;

  /// XFG in display units.
  double get amount => amountAtomic / atomicPerCoin;

  String get priceDisplay => price.toStringAsFixed(7);
  String get amountDisplay => atomicToDisplay(amountAtomic);

  /// Level depth in ΗΞΔŦ — price × amount, both already descaled.
  double get totalHeat => price * amount;

  Map<String, dynamic> toJson() => {
    'price': priceAtomic,
    'amount': amountAtomic,
    'orderCount': orderCount,
  };
}

/// Response to `/getorderbook`
/// C++: COMMAND_RPC_GET_ORDER_BOOK (CoreRpcServerCommandsDefinitions.h:1047-1087)
class OrderBookState {
  final List<OrderBookLevel> bids;
  final List<OrderBookLevel> asks;

  /// Same scaling as a level price: ΗΞΔŦ-per-XFG × COIN.
  final int spreadAtomic;
  final int height;
  final String status;

  const OrderBookState({
    required this.bids,
    required this.asks,
    required this.spreadAtomic,
    required this.height,
    required this.status,
  });

  factory OrderBookState.fromJson(Map<String, dynamic> json) {
    final bidsRaw = json['bids'] as List<dynamic>? ?? [];
    final asksRaw = json['asks'] as List<dynamic>? ?? [];
    return OrderBookState(
      bids: bidsRaw
          .map((e) => OrderBookLevel.fromJson(e as Map<String, dynamic>))
          .toList(),
      asks: asksRaw
          .map((e) => OrderBookLevel.fromJson(e as Map<String, dynamic>))
          .toList(),
      spreadAtomic: _u64(json['spread']),
      height: _u64(json['height']),
      status: json['status'] as String? ?? '',
    );
  }

  double get spread => spreadAtomic / atomicPerCoin;
  String get spreadDisplay => spread.toStringAsFixed(7);

  /// Highest bid. Computed rather than taking `bids.first` — the daemon's
  /// ordering is not part of the response contract.
  OrderBookLevel? get bestBid {
    if (bids.isEmpty) return null;
    return bids.reduce((a, b) => a.priceAtomic >= b.priceAtomic ? a : b);
  }

  /// Lowest ask, computed for the same reason.
  OrderBookLevel? get bestAsk {
    if (asks.isEmpty) return null;
    return asks.reduce((a, b) => a.priceAtomic <= b.priceAtomic ? a : b);
  }

  /// Mid price in ΗΞΔŦ per XFG, or null when one side is empty.
  double? get mid {
    final b = bestBid;
    final a = bestAsk;
    if (b == null || a == null) return null;
    return (b.price + a.price) / 2;
  }

  bool get isEmpty => bids.isEmpty && asks.isEmpty;
}

/// Response to `/amm_quote`
/// C++: COMMAND_RPC_AMM_QUOTE (CoreRpcServerCommandsDefinitions.h:2500+)
class HearthQuote {
  final String expectedOutput;
  final String priceImpactBps;
  final String fee;
  final String status;

  const HearthQuote({
    required this.expectedOutput,
    required this.priceImpactBps,
    required this.fee,
    required this.status,
  });

  factory HearthQuote.fromJson(Map<String, dynamic> json) {
    return HearthQuote(
      expectedOutput: json['expected_output']?.toString() ?? '0',
      priceImpactBps: json['price_impact_bps']?.toString() ?? '0',
      fee: json['fee']?.toString() ?? '0',
      status: json['status'] as String? ?? '',
    );
  }

  /// Output in atomic units, or null when the daemon returned nothing usable.
  int? get outputAtomic {
    final v = int.tryParse(expectedOutput);
    return (v != null && v > 0) ? v : null;
  }

  int get feeAtomic => int.tryParse(fee) ?? 0;

  /// Output in display units, or '—'.
  String get outputAmount {
    final v = outputAtomic;
    return v == null ? '—' : atomicToDisplay(v);
  }

  String get feeDisplay => atomicToDisplay(feeAtomic);

  /// Price impact as a percent, from the daemon's basis points.
  double get priceImpactPercent => (int.tryParse(priceImpactBps) ?? 0) / 100;

  String get priceImpact => '${priceImpactPercent.toStringAsFixed(2)}%';
}

/// Response to `/amm_pool_info`
/// C++: COMMAND_RPC_AMM_POOL_INFO (CoreRpcServerCommandsDefinitions.h:1613-1653)
class HearthPool {
  final int reserveXfg;
  final int reserveHeat;
  final int totalLpShares;
  final int spotPrice;
  final int epochSwapFees;
  final int hearthTwap;
  final String status;

  const HearthPool({
    required this.reserveXfg,
    required this.reserveHeat,
    required this.totalLpShares,
    required this.spotPrice,
    required this.epochSwapFees,
    required this.hearthTwap,
    required this.status,
  });

  factory HearthPool.fromJson(Map<String, dynamic> json) {
    return HearthPool(
      reserveXfg: _u64(json['reserve_xfg']),
      reserveHeat: _u64(json['reserve_heat']),
      totalLpShares: _u64(json['total_lp_shares']),
      spotPrice: _u64(json['spot_price']),
      epochSwapFees: _u64(json['epoch_swap_fees']),
      hearthTwap: _u64(json['hearth_twap']),
      status: json['status'] as String? ?? '',
    );
  }

  /// HEAT per XFG.
  ///
  /// fuego-suite defines `spot_price` as "HEAT atomics per XFG atomic * COIN"
  /// (`COMMAND_RPC_GET_FUEGO_PRICE` comment), so the human ratio is
  /// `spot_price / COIN`. At the genesis seed (10,000 XFG : 1,000 HEAT) that
  /// is 0.1 — ten XFG to one HEAT.
  double get heatPerXfg => spotPrice / atomicPerCoin;

  /// XFG per HEAT — the number the mint screen quotes.
  double? get xfgPerHeat => heatPerXfg > 0 ? 1 / heatPerXfg : null;

  /// True when the daemon returned a usable pool. Reserves of zero mean the
  /// pool is not seeded yet and no rate should be displayed.
  bool get isSeeded => reserveXfg > 0 && reserveHeat > 0 && spotPrice > 0;

  /// Pool ratio straight from the reserves — this is the rule walletd and
  /// SimpleWallet both use to size a mint.
  double? get reserveHeatPerXfg =>
      reserveXfg > 0 ? reserveHeat / reserveXfg : null;

  /// Spot price as a display string, or '—' when the pool is not seeded.
  String get price => isSeeded ? heatPerXfg.toStringAsFixed(7) : '—';

  /// XFG reserve in display units.
  String get xfgBalance => atomicToDisplay(reserveXfg);

  /// HEAT reserve in display units.
  String get heatBalance => atomicToDisplay(reserveHeat);

  /// Total LP shares (a raw count, not an atomic amount).
  String get heatTotalSupply => totalLpShares.toString();

  /// Epoch swap fees in display HEAT.
  String get epochSwapFeesDisplay => atomicToDisplay(epochSwapFees);

  /// TWAP as HEAT per XFG, or null when the daemon has not filled it.
  double? get twapHeatPerXfg =>
      hearthTwap > 0 ? hearthTwap / atomicPerCoin : null;
}

int _u64(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
