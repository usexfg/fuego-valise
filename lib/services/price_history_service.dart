import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import '../models/candlestick.dart';

class PriceHistoryService {
  static final PriceHistoryService _instance = PriceHistoryService._();
  factory PriceHistoryService() => _instance;
  PriceHistoryService._();

  List<Candlestick>? _allCandles;

  Future<List<Candlestick>> loadAll() async {
    if (_allCandles != null) return _allCandles!;
    final jsonStr = await rootBundle.loadString(
      'assets/data/xfg_historical_prices.json',
    );
    final decoded = jsonDecode(jsonStr);
    if (decoded is! List) {
      throw const FormatException('XFG history must be an array');
    }

    final candles = <Candlestick>[];
    for (final (index, row) in decoded.indexed) {
      if (row is! Map<String, dynamic>) {
        throw FormatException('Invalid XFG history row $index');
      }
      final candle = Candlestick.fromJson(row);
      if (candle.time <= 0 ||
          (candles.isNotEmpty && candle.time <= candles.last.time) ||
          !candle.open.isFinite ||
          !candle.high.isFinite ||
          !candle.low.isFinite ||
          !candle.close.isFinite ||
          !candle.volume.isFinite ||
          candle.low <= 0 ||
          candle.low > candle.open ||
          candle.low > candle.close ||
          candle.high < candle.open ||
          candle.high < candle.close ||
          candle.volume < 0) {
        throw FormatException('Invalid XFG history candle $index');
      }
      candles.add(candle);
    }

    _allCandles = List.unmodifiable(candles);
    return _allCandles!;
  }

  double? priceAt(int timestamp) {
    if (_allCandles == null) return null;
    for (int i = _allCandles!.length - 1; i >= 0; i--) {
      if (_allCandles![i].time <= timestamp) return _allCandles![i].close;
    }
    return null;
  }
}
