import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../models/heat_amm.dart';
import '../../services/fuego_daemon_client.dart';
import '../../services/hearth_spot_history_service.dart';

enum OrderType { market, limit }

class HearthState {
  final bool isLoading;
  final PoolInfo? pool;
  final AmmQuote? quote;
  final OrderBookState? orderBookState;
  final OrderType orderType;
  final String? error;
  final String networkId;
  final List<HearthSpotObservation> spotObservations;

  const HearthState({
    this.isLoading = false,
    this.pool,
    this.quote,
    this.orderBookState,
    this.orderType = OrderType.market,
    this.error,
    this.networkId = '',
    this.spotObservations = const [],
  });

  HearthState copyWith({
    bool? isLoading,
    PoolInfo? pool,
    AmmQuote? quote,
    OrderBookState? orderBookState,
    OrderType? orderType,
    String? error,
    String? networkId,
    List<HearthSpotObservation>? spotObservations,
  }) => HearthState(
    isLoading: isLoading ?? this.isLoading,
    pool: pool ?? this.pool,
    quote: quote,
    orderBookState: orderBookState ?? this.orderBookState,
    orderType: orderType ?? this.orderType,
    error: error,
    networkId: networkId ?? this.networkId,
    spotObservations: spotObservations ?? this.spotObservations,
  );
}

class HearthCubit extends Cubit<HearthState> {
  final FuegoDaemonClient _daemon;
  final HearthSpotHistoryService _spotHistory;
  bool _refreshInFlight = false;
  bool _refreshRequested = false;

  HearthCubit(this._daemon, {HearthSpotHistoryService? spotHistory})
    : _spotHistory = spotHistory ?? HearthSpotHistoryService(),
      super(const HearthState());

  Future<void> loadPool() async {
    if (_refreshInFlight) {
      _refreshRequested = true;
      return;
    }
    _refreshInFlight = true;
    final networkId = _daemon.networkConfig.networkId;
    bool networkChanged() {
      if (_daemon.networkConfig.networkId == networkId) return false;
      _refreshRequested = true;
      return true;
    }

    final base = state.networkId == networkId
        ? state
        : HearthState(networkId: networkId);
    emit(base.copyWith(isLoading: base.pool == null));

    var observations = base.spotObservations;
    String? historyError;
    try {
      try {
        observations = await _spotHistory.load(networkId);
      } catch (error) {
        historyError = 'Saved pool history unavailable: $error';
      }
      if (isClosed || networkChanged()) return;
      final pool = await _daemon.getPoolInfo();
      if (isClosed || networkChanged()) return;
      if (historyError == null) {
        try {
          observations = await _spotHistory.record(networkId, pool);
        } catch (error) {
          historyError = 'Unable to save pool history: $error';
        }
      }
      if (isClosed || networkChanged()) return;
      emit(
        state.copyWith(
          isLoading: false,
          pool: pool,
          spotObservations: observations,
          error: historyError,
        ),
      );
      try {
        final orderbookState = await _daemon.getOrderbookState();
        if (isClosed || networkChanged()) return;
        emit(
          state.copyWith(orderBookState: orderbookState, error: historyError),
        );
      } catch (error) {
        if (isClosed) return;
        emit(state.copyWith(error: 'Hearth order book unavailable: $error'));
      }
    } catch (e) {
      if (!isClosed && !networkChanged()) {
        emit(
          state.copyWith(
            isLoading: false,
            spotObservations: observations,
            error: 'Hearth pool unavailable: $e',
          ),
        );
      }
    } finally {
      _refreshInFlight = false;
      if (_refreshRequested && !isClosed) {
        _refreshRequested = false;
        unawaited(loadPool());
      }
    }
  }

  void setOrderType(OrderType type) {
    emit(state.copyWith(orderType: type, quote: null));
  }

  Future<void> getQuote({required bool sellXfg, required String amount}) async {
    try {
      final quote = await _daemon.getAmmQuote(sellXfg: sellXfg, amount: amount);
      emit(state.copyWith(quote: quote));
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  Future<Map<String, dynamic>> executeSwap({
    required bool sellXfg,
    required String inputAmount,
    required String minOutput,
  }) {
    return _daemon.swap(
      sellXfg: sellXfg,
      inputAmount: inputAmount,
      minOutput: minOutput,
    );
  }

  Future<Map<String, dynamic>> placeLimitOrder({
    required bool sellXfg,
    required String amount,
    required String price,
  }) {
    return _daemon.placeLimitOrder(
      sellXfg: sellXfg,
      amount: amount,
      price: price,
    );
  }

  Future<Map<String, dynamic>> addLiquidity({
    required String xfgAmount,
    required String heatAmount,
  }) {
    return _daemon.addLiquidity(xfgAmount: xfgAmount, heatAmount: heatAmount);
  }

  Future<Map<String, dynamic>> removeLiquidity({
    required String shares,
    required String minXfg,
    required String minHeat,
  }) {
    return _daemon.removeLiquidity(
      shares: shares,
      minXfg: minXfg,
      minHeat: minHeat,
    );
  }
}
