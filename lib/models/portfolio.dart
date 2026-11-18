import 'dart:ui' show Color;

import 'chain_registry.g.dart';

/// Live XFG / ΗΞΔŦ price snapshot from fuegod `GET /get_fuego_price`.
///
/// The daemon derives these in `RpcServer::on_get_fuego_price`:
/// `xfg_heat_ratio = spot_price / COIN`, `heat_peg_usd = HEAT_PEG_USD` and
/// `xfg_spot_usd = ratio * heat_peg_usd`. They arrive as strings, so the peg is
/// parsed once here and never recomputed in the UI.
class FuegoPrice {
  const FuegoPrice({
    required this.xfgHeatRatio,
    required this.heatPegUsd,
    required this.xfgSpotUsd,
    required this.reserveXfg,
    required this.reserveHeat,
    required this.spotPrice,
    required this.height,
  });

  /// HEAT per 1 XFG.
  final double xfgHeatRatio;

  /// ΗΞΔŦ peg in USD — the redemption constant.
  final double heatPegUsd;

  /// Live XFG spot in USD as priced by the Hearth pool.
  final double xfgSpotUsd;

  final int reserveXfg;
  final int reserveHeat;
  final int spotPrice;
  final int height;

  /// False when the daemon reported a zero ratio — the pool has no depth yet,
  /// so any USD figure would be invented rather than observed.
  bool get isPriced => xfgSpotUsd > 0;

  factory FuegoPrice.fromJson(Map<String, dynamic> json) => FuegoPrice(
    xfgHeatRatio: _double(json['xfg_heat_ratio']),
    heatPegUsd: _double(json['heat_peg_usd']),
    xfgSpotUsd: _double(json['xfg_spot_usd']),
    reserveXfg: _int(json['reserve_xfg']),
    reserveHeat: _int(json['reserve_heat']),
    spotPrice: _int(json['spot_price']),
    height: _int(json['height']),
  );

  static double _double(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim()) ?? 0;
    return 0;
  }

  static int _int(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }
}

/// One chain-level asset row in the wallet portfolio.
///
/// [amount] is the native gas-token balance in whole units. A chain whose RPC
/// did not answer keeps `reachable: false` so the row reads as *unknown*
/// instead of an empty wallet.
class PortfolioHolding {
  const PortfolioHolding({
    required this.chainKey,
    required this.ticker,
    required this.name,
    required this.icon,
    required this.color,
    this.amount = 0,
    this.reachable = true,
    this.note,
  });

  final String chainKey;
  final String ticker;
  final String name;
  final String icon;
  final Color color;
  final double amount;
  final bool reachable;
  final String? note;

  bool get isHeld => reachable && amount > 0;

  /// Registry row for [chain], optionally carrying a probed [amount].
  factory PortfolioHolding.fromChain(
    ChainEntry chain, {
    double amount = 0,
    bool reachable = true,
    String? note,
  }) => PortfolioHolding(
    chainKey: chain.key,
    ticker: chain.ticker,
    name: chain.name,
    icon: chain.icon,
    color: Color(0xFF000000 | chain.colorValue),
    amount: amount,
    reachable: reachable,
    note: note,
  );
}

/// USD value of the *priced* part of the portfolio — XFG and ΗΞΔŦ.
///
/// Other chains are deliberately unpriced: the app has no price feed for them,
/// and a portfolio that invents a number is worse than one that shows none.
class PortfolioValuation {
  const PortfolioValuation({
    required this.xfgUsd,
    required this.heatUsd,
    required this.isPriced,
    this.heatKnown = true,
  });

  const PortfolioValuation.unpriced({this.heatKnown = true})
    : xfgUsd = 0,
      heatUsd = 0,
      isPriced = false;

  final double xfgUsd;
  final double heatUsd;
  final bool isPriced;

  /// False when walletd could not report the ΗΞΔŦ balance at all. The total
  /// then covers XFG only, and the header says so instead of implying the
  /// reserve is empty.
  final bool heatKnown;

  double get totalUsd => xfgUsd + heatUsd;

  factory PortfolioValuation.of({
    required double xfgAmount,
    required double heatAmount,
    required FuegoPrice? price,
    bool heatKnown = true,
  }) {
    if (price == null || !price.isPriced) {
      return PortfolioValuation.unpriced(heatKnown: heatKnown);
    }
    return PortfolioValuation(
      xfgUsd: xfgAmount * price.xfgSpotUsd,
      heatUsd: heatKnown ? heatAmount * price.heatPegUsd : 0,
      isPriced: true,
      heatKnown: heatKnown,
    );
  }
}

/// Thin-space thousands grouping for prestige figures (`12 345.6789`).
String groupThousands(String fixed) {
  final parts = fixed.split('.');
  final intPart = parts[0].replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (m) => '${m[1]}\u2009',
  );
  return parts.length > 1 ? '$intPart.${parts[1]}' : intPart;
}
