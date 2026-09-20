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
  final int treasuryBalance;
  final int treasuryCounterXfg;
  final int swfBurnedXfgPendingHeat;
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
    required this.treasuryBalance,
    required this.treasuryCounterXfg,
    required this.swfBurnedXfgPendingHeat,
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
      treasuryBalance: _u64(json['treasury_balance']),
      treasuryCounterXfg: _u64(json['treasury_counter_xfg']),
      swfBurnedXfgPendingHeat: _u64(json['swf_burned_xfg_pending_heat']),
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

  /// Redemption price in **XFG per HEAT**, for display only.
  ///
  /// Core.cpp computes `redemptionPriceNum = reserveXfg * 1e6 / reserveHeat`
  /// with `redemptionPriceDenom = 1e6`, so num/denom is XFG per HEAT.
  ///
  /// This is NOT the price a mint is validated against. Since v11 the chain
  /// uses `mintPrice` — the rolling 8-block TWAP, or the AMM spot price when
  /// the window is too short — on the canonical scale (HEAT atomics per XFG
  /// atomic × COIN), and fails closed when it is zero. Quoting a mint from
  /// this field instead drifts from the TWAP and gets the transaction
  /// rejected. Use [PoolInfo.mintPrice].
  double? get xfgPerHeat {
    if (redemptionPriceDenom == 0 || redemptionPriceNum == 0) return null;
    return redemptionPriceNum / redemptionPriceDenom;
  }

  /// Redemption price as a display string, or '—' when undefined.
  String get formattedRedemptionPrice {
    final price = xfgPerHeat;
    if (price == null) return '—';
    return '${price.toStringAsFixed(6)} XFG/HEAT';
  }

  /// HEAT in circulation, in HEAT.
  String get supply => formatHeat(heatSupply);

  /// Treasury balance, in HEAT.
  String get treasury => formatHeat(treasuryBalance);

  /// HEAT locked in CDs — the denominator of the epoch yield rate
  /// (Blockchain.cpp: `epochCdLocked = m_heatOnDeposit`).
  String get onDeposit => formatHeat(heatOnDeposit);

  /// CD yield pool backing. This is what caps claims at claim time; there is
  /// no APY to quote, because yield is realized swap-fee revenue distributed
  /// per epoch rather than a fixed rate.
  String get cdYieldPool => formatHeat(vaultHeatCdFeePool);

  /// XFG LP reserve, in XFG.
  String get poolXfg => formatHeat(reserveDisplayXfg);

  /// HEAT LP reserve, in HEAT.
  String get poolHeat => formatHeat(vaultHeatLpReserve);

  int get reserveDisplayXfg => vaultXfgLpReserve;
}

/// Atomic units per coin (CryptoNoteConfig.h COIN). Both XFG and HEAT use 7
/// decimal places.
const int _atomicPerCoin = 10000000;

/// Format an atomic amount as a coin decimal, trimming trailing zeros.
String formatHeat(int atomic) {
  final whole = atomic ~/ _atomicPerCoin;
  final frac = atomic % _atomicPerCoin;
  if (frac == 0) return whole.toString();
  final fracStr =
      frac.toString().padLeft(7, '0').replaceFirst(RegExp(r'0+$'), '');
  return '$whole.$fracStr';
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

  /// Output amount (atomic units) as a display string.
  String get outputAmount => expectedOutput;

  /// Price impact in basis points (1/100th of a percent).
  String get priceImpact => priceImpactBps;
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

  /// The price a HEAT mint is validated against, on the canonical scale:
  /// HEAT atomics per XFG atomic × COIN (AmmPool.cpp ammGetSpotPrice).
  ///
  /// Mirrors Blockchain.cpp's v11+ selection: the rolling 8-block TWAP when
  /// the window holds at least two samples, otherwise the AMM spot price.
  /// Null when neither is available — consensus fails closed there
  /// ("HEAT mint rejected: no pool price available"), so a quote must too.
  int? get mintPrice {
    if (hearthTwap > 0) return hearthTwap;
    if (spotPrice > 0) return spotPrice;
    return null;
  }

  /// HEAT minted per whole XFG burned, for display.
  double? get heatPerXfg {
    final price = mintPrice;
    if (price == null) return null;
    return price / _atomicPerCoin;
  }

  /// Spot price (HEAT per XFG × COIN) as a display string.
  String get price => spotPrice.toString();

  /// XFG reserve (atomic units) as a display string.
  String get xfgBalance => reserveXfg.toString();

  /// HEAT reserve (atomic units) as a display string.
  String get heatBalance => reserveHeat.toString();

  /// Total LP shares as a display string.
  String get heatTotalSupply => totalLpShares.toString();

  /// Total liquidity value in HEAT units.
  String get totalLiquidity => totalLpShares.toString();
}

int _u64(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
