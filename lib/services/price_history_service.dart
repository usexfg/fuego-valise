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
    final List<dynamic> raw = jsonDecode(jsonStr) as List<dynamic>;
    _allCandles = raw
        .map((e) => Candlestick.fromJson(e as Map<String, dynamic>))
        .toList();

    // Append final launch-price candle: XFG=$0.15
    if (_allCandles!.isNotEmpty) {
      final last = _allCandles!.last;
      final now = DateTime.now();
      final launchTs =
          DateTime(now.year, now.month, now.day).millisecondsSinceEpoch ~/ 1000;
      if (last.time < launchTs) {
        _allCandles!.add(
          Candlestick(
            time: launchTs,
            open: last.close,
            high: 0.155,
            low: 0.145,
            close: 0.15,
            volume: 0,
          ),
        );
      }
    }
    return _allCandles!;
  }

  List<Candlestick> aggregateDaily(List<Candlestick> daily) {
    return daily;
  }

  double get currentPrice {
    if (_allCandles == null || _allCandles!.isEmpty) return 0;
    return _allCandles!.last.close;
  }

  double? priceAt(int timestamp) {
    if (_allCandles == null) return null;
    for (int i = _allCandles!.length - 1; i >= 0; i--) {
      if (_allCandles![i].time <= timestamp) return _allCandles![i].close;
    }
    return null;
  }
}
