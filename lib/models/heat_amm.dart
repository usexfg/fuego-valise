import '../core/constants.dart';

/// Models for the Hearth AMM / orderbook subsystem.
///
/// Field names and types match the fuego-suite C++ response structs exactly.
/// See: CoreRpcServerCommandsDefinitions.h lines 2448-2497 (HeatMetrics),
///      CoreRpcServerCommandsDefinitions.h lines 1613-1653 (PoolInfo),
///      CoreRpcServerCommandsDefinitions.h lines 1047-1087 (OrderBookState),
///      CoreRpcServerCommandsDefinitions.h lines 2500+ (AmmQuote).

/// Response to `/get_heat_metrics`
/// C++: COMMAND_RPC_GET_HEAT_METRICS (CoreRpcServerCommandsDefinitions.h:2448-2497)
class HeatMetrics {
  final int heatSupply;
  final int heatOnDeposit;
  final int burnedXfg;
  final int totalBurnedXfg;
  final int redemptionPriceNum;
  final int redemptionPriceDenom;
  final int redemptionRateNum;
  final int redemptionRateDenom;
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
    required this.redemptionPriceNum,
    required this.redemptionPriceDenom,
    required this.redemptionRateNum,
    required this.redemptionRateDenom,
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
      redemptionPriceNum: _u64(json['redemption_price_num']),
      redemptionPriceDenom: _u64(json['redemption_price_denom']),
      redemptionRateNum: _u64(json['redemption_rate_num']),
      redemptionRateDenom: _u64(json['redemption_rate_denom']),
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

  /// Redemption price as a human-readable double (num/denom).
  double get redemptionPriceValue =>
      redemptionPriceDenom != 0 ? redemptionPriceNum / redemptionPriceDenom : 0.0;

  /// Redemption price as a display string (num/denom).
  String get redemptionPrice => redemptionPriceValue.toStringAsFixed(6);

  /// Redemption rate as a human-readable double.
  double get redemptionRate =>
      redemptionRateDenom != 0 ? redemptionRateNum / redemptionRateDenom : 0.0;

  /// Price per XFG in HEAT (num/denom).
  /// When denom == 0, price is undefined.
  String get formattedRedemptionPrice {
    if (redemptionPriceDenom == 0) return '—';
    return '${(redemptionPriceNum / redemptionPriceDenom).toStringAsFixed(6)} HEAT/XFG';
  }

  /// CD yield (APY) as a percent, or null.
  ///
  /// `on_get_heat_metrics` in fuego-suite assigns every response field except
  /// `redemption_rate_num` / `redemption_rate_denom`, so a zero denominator
  /// means "the daemon did not report a rate" — not "the rate is zero".
  double? get currentApy =>
      redemptionRateDenom > 0 ? redemptionRate * 100 : null;

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

  /// De-facto mint target: the current redemption price.
  String get piTarget => formattedRedemptionPrice;
}

/// Single level in the orderbook.
/// C++: COMMAND_RPC_GET_ORDER_BOOK::response::OrderBookLevelJson
/// (CoreRpcServerCommandsDefinitions.h:1047-1087)
/// price/amount are uint64_t (JSON numbers, atomic units).
class OrderBookLevel {
  final String price;
  final String amount;
  final int orderCount;

  const OrderBookLevel({
    required this.price,
    required this.amount,
    required this.orderCount,
  });

  factory OrderBookLevel.fromJson(Map<String, dynamic> json) {
    return OrderBookLevel(
      price: json['price']?.toString() ?? '0',
      amount: json['amount']?.toString() ?? '0',
      orderCount: json['orderCount'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'price': price,
        'amount': amount,
        'orderCount': orderCount,
      };
}

/// Response to `/getorderbook`
/// C++: COMMAND_RPC_GET_ORDER_BOOK (CoreRpcServerCommandsDefinitions.h:1047-1087)
class OrderBookState {
  final List<OrderBookLevel> bids;
  final List<OrderBookLevel> asks;
  final String spread;
  final int height;
  final String status;

  const OrderBookState({
    required this.bids,
    required this.asks,
    required this.spread,
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
      spread: json['spread']?.toString() ?? '0',
      height: _u64(json['height']),
      status: json['status'] as String? ?? '',
    );
  }

  /// Best bid price (highest bid).
  OrderBookLevel? get bestBid => bids.isNotEmpty ? bids.first : null;

  /// Best ask price (lowest ask).
  OrderBookLevel? get bestAsk => asks.isNotEmpty ? asks.first : null;
}

/// Response to `/amm_quote`
/// C++: COMMAND_RPC_AMM_QUOTE (CoreRpcServerCommandsDefinitions.h:2500+)
class AmmQuote {
  final String expectedOutput;
  final String priceImpactBps;
  final String fee;
  final String status;

  const AmmQuote({
    required this.expectedOutput,
    required this.priceImpactBps,
    required this.fee,
    required this.status,
  });

  factory AmmQuote.fromJson(Map<String, dynamic> json) {
    return AmmQuote(
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
class PoolInfo {
  final int reserveXfg;
  final int reserveHeat;
  final int totalLpShares;
  final int spotPrice;
  final int epochSwapFees;
  final int hearthTwap;
  final String status;

  const PoolInfo({
    required this.reserveXfg,
    required this.reserveHeat,
    required this.totalLpShares,
    required this.spotPrice,
    required this.epochSwapFees,
    required this.hearthTwap,
    required this.status,
  });

  factory PoolInfo.fromJson(Map<String, dynamic> json) {
    return PoolInfo(
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
