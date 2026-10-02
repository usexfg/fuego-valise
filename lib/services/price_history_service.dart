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
    final jsonStr = await rootBundle.loadString('assets/data/xfg_historical_prices.json');
    final List<dynamic> raw = jsonDecode(jsonStr) as List<dynamic>;
    _allCandles = raw.map((e) => Candlestick.fromJson(e as Map<String, dynamic>)).toList();

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
