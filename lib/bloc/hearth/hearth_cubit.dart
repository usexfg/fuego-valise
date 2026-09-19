import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/constants.dart';
import '../../models/hearth.dart';
import '../../services/fuego_rpc_service.dart';

enum OrderType { market, limit }

/// Outcome of a Hearth write. Every action returns one of these instead of a
/// bare future, so the UI cannot silently drop a failure.
class HearthResult {
  final bool ok;
  final String? txHash;
  final String? error;

  const HearthResult.success(this.txHash) : ok = true, error = null;
  const HearthResult.failure(this.error) : ok = false, txHash = null;
}

class HearthState {
  final bool isLoading;
  final bool isSubmitting;
  final HearthPool? pool;
  final HearthQuote? quote;

  /// Atomic input the [quote] was produced for; a quote is only spendable
  /// against the amount it was requested with.
  final int? quoteInputAtomic;
  final bool? quoteSellXfg;
  final OrderBookState? orderBookState;
  final OrderType orderType;

  /// Slippage tolerance in basis points applied to `min_output`.
  final int slippageBps;
  final String? error;

  const HearthState({
    this.isLoading = false,
    this.isSubmitting = false,
    this.pool,
    this.quote,
    this.quoteInputAtomic,
    this.quoteSellXfg,
    this.orderBookState,
    this.orderType = OrderType.market,
    this.slippageBps = 50,
    this.error,
  });

  HearthState copyWith({
    bool? isLoading,
    bool? isSubmitting,
    HearthPool? pool,
    HearthQuote? quote,
    int? quoteInputAtomic,
    bool? quoteSellXfg,
    bool clearQuote = false,
    OrderBookState? orderBookState,
    OrderType? orderType,
    int? slippageBps,
    String? error,
    bool clearError = false,
  }) => HearthState(
    isLoading: isLoading ?? this.isLoading,
    isSubmitting: isSubmitting ?? this.isSubmitting,
    pool: pool ?? this.pool,
    quote: clearQuote ? null : (quote ?? this.quote),
    quoteInputAtomic: clearQuote
        ? null
        : (quoteInputAtomic ?? this.quoteInputAtomic),
    quoteSellXfg: clearQuote ? null : (quoteSellXfg ?? this.quoteSellXfg),
    orderBookState: orderBookState ?? this.orderBookState,
    orderType: orderType ?? this.orderType,
    slippageBps: slippageBps ?? this.slippageBps,
    error: clearError ? null : (error ?? this.error),
  );

  /// Minimum acceptable output for the live quote, after slippage.
  int? get minOutputAtomic {
    final q = quote;
    if (q == null) return null;
    final out = int.tryParse(q.expectedOutput);
    if (out == null || out <= 0) return null;
    return out - (out * slippageBps ~/ 10000);
  }
}

/// Hearth — the XFG/ΗΞΔŦ pool and orderbook.
///
/// Reads and writes both go through [FuegoRPCService], i.e. the local
/// fuego_walletd proxy. The Hearth write methods (`swap`, `add_liq`,
/// `remove_liq`, `place_limit_order`, `mint_heat`) are wallet methods — fuegod
/// does not implement them — and the read endpoints need a JSON body, which a
/// GET with query parameters never supplies.
class HearthCubit extends Cubit<HearthState> {
  final FuegoRPCService _rpc;

  HearthCubit(this._rpc) : super(const HearthState());

  Future<void> loadPool() async {
    emit(state.copyWith(isLoading: true, clearError: true));
    try {
      final pool = HearthPool.fromJson(await _rpc.hearthPool());
      OrderBookState? book;
      try {
        book = OrderBookState.fromJson(await _rpc.orderbookState());
      } catch (_) {
        // The book is optional context; a missing one must not blank the pool.
      }
      emit(
        state.copyWith(
          isLoading: false,
          pool: pool,
          orderBookState: book,
          clearError: true,
        ),
      );
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: _message(e)));
    }
  }

  void setOrderType(OrderType type) =>
      emit(state.copyWith(orderType: type, clearQuote: true));

  void setSlippageBps(int bps) =>
      emit(state.copyWith(slippageBps: bps.clamp(0, 5000)));

  /// [amountDisplay] is what the user typed. It is parsed to atomic units
  /// exactly; the daemon's `input_amount` is a uint64 of atomic units.
  Future<void> getQuote({
    required bool sellXfg,
    required String amountDisplay,
  }) async {
    final atomic = parseAtomic(amountDisplay);
    if (atomic == null || atomic <= 0) {
      emit(
        state.copyWith(
          clearQuote: true,
          error: 'Enter an amount with at most $decimalPlaces decimals.',
        ),
      );
      return;
    }
    try {
      final quote = HearthQuote.fromJson(
        await _rpc.hearthQuote(inputAmountAtomic: atomic, sellXfg: sellXfg),
      );
      emit(
        state.copyWith(
          quote: quote,
          quoteInputAtomic: atomic,
          quoteSellXfg: sellXfg,
          clearError: true,
        ),
      );
    } catch (e) {
      emit(state.copyWith(clearQuote: true, error: _message(e)));
    }
  }

  /// Execute the live quote. Refuses when there is no quote, when the quote
  /// was taken for a different amount or direction, or when slippage leaves no
  /// floor — a swap sent with `min_output` equal to the quote has zero
  /// tolerance and fails on any tick.
  Future<HearthResult> executeQuotedSwap() async {
    final q = state.quote;
    final input = state.quoteInputAtomic;
    final sellXfg = state.quoteSellXfg;
    final minOut = state.minOutputAtomic;
    if (q == null || input == null || sellXfg == null || minOut == null) {
      return const HearthResult.failure('Get a quote first.');
    }
    if (minOut <= 0) {
      return const HearthResult.failure(
        'Quoted output is zero — nothing to swap.',
      );
    }
    emit(state.copyWith(isSubmitting: true, clearError: true));
    try {
      final r = await _rpc.hearthSwap(
        sellXfg: sellXfg,
        inputAmountAtomic: input,
        minOutputAtomic: minOut,
      );
      emit(state.copyWith(isSubmitting: false, clearQuote: true));
      unawaited(loadPool());
      return HearthResult.success(_txHash(r));
    } catch (e) {
      final msg = _message(e);
      emit(state.copyWith(isSubmitting: false, error: msg));
      return HearthResult.failure(msg);
    }
  }

  Future<HearthResult> placeLimitOrder({
    required bool sellXfg,
    required String amountDisplay,
    required String priceDisplay,
  }) async {
    final amount = parseAtomic(amountDisplay);
    if (amount == null || amount <= 0) {
      return const HearthResult.failure('Enter a valid amount.');
    }
    if (double.tryParse(priceDisplay) == null ||
        double.parse(priceDisplay) <= 0) {
      return const HearthResult.failure('Enter a valid price.');
    }
    emit(state.copyWith(isSubmitting: true, clearError: true));
    try {
      // price stays a human decimal — walletd scales it by COIN itself.
      final r = await _rpc.placeLimitOrder(
        sellXfg: sellXfg,
        amountAtomic: amount,
        priceDisplay: priceDisplay,
      );
      emit(state.copyWith(isSubmitting: false));
      unawaited(loadPool());
      return HearthResult.success(_txHash(r));
    } catch (e) {
      final msg = _message(e);
      emit(state.copyWith(isSubmitting: false, error: msg));
      return HearthResult.failure(msg);
    }
  }

  Future<HearthResult> addLiquidity({
    required String xfgDisplay,
    required String heatDisplay,
  }) async {
    final xfg = parseAtomic(xfgDisplay);
    final heat = parseAtomic(heatDisplay);
    if (xfg == null || heat == null || xfg <= 0 || heat <= 0) {
      return const HearthResult.failure(
        'Enter both amounts with at most 7 decimals.',
      );
    }
    emit(state.copyWith(isSubmitting: true, clearError: true));
    try {
      final r = await _rpc.hearthAddLiquidity(
        xfgAmountAtomic: xfg,
        heatAmountAtomic: heat,
      );
      emit(state.copyWith(isSubmitting: false));
      unawaited(loadPool());
      return HearthResult.success(_txHash(r));
    } catch (e) {
      final msg = _message(e);
      emit(state.copyWith(isSubmitting: false, error: msg));
      return HearthResult.failure(msg);
    }
  }

  /// Both minimums are required. Sending them empty made walletd default them
  /// to 0, which is a withdrawal with no floor.
  Future<HearthResult> removeLiquidity({
    required String sharesDisplay,
    required String minXfgDisplay,
    required String minHeatDisplay,
  }) async {
    final shares = int.tryParse(sharesDisplay.trim());
    if (shares == null || shares <= 0) {
      return const HearthResult.failure('Enter the LP shares to burn.');
    }
    final minXfg = parseAtomic(minXfgDisplay);
    final minHeat = parseAtomic(minHeatDisplay);
    if (minXfg == null || minHeat == null) {
      return const HearthResult.failure(
        'Set both minimums — a withdrawal with no floor can be sandwiched.',
      );
    }
    if (minXfg <= 0 || minHeat <= 0) {
      return const HearthResult.failure('Both minimums must be above zero.');
    }
    emit(state.copyWith(isSubmitting: true, clearError: true));
    try {
      final r = await _rpc.hearthRemoveLiquidity(
        shares: shares,
        minXfgAtomic: minXfg,
        minHeatAtomic: minHeat,
      );
      emit(state.copyWith(isSubmitting: false));
      unawaited(loadPool());
      return HearthResult.success(_txHash(r));
    } catch (e) {
      final msg = _message(e);
      emit(state.copyWith(isSubmitting: false, error: msg));
      return HearthResult.failure(msg);
    }
  }

  static String? _txHash(Map<String, dynamic> r) =>
      (r['transactionHash'] ?? r['txHash'] ?? r['tx_hash']) as String?;

  static String _message(Object e) =>
      e is FuegoRPCException ? e.message : e.toString();
}
