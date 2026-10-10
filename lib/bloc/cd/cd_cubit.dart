import 'package:flutter_bloc/flutter_bloc.dart';
import '../../models/cd.dart';
import '../../services/fuego_rpc_service.dart';

// ── State ──

enum CdLoadStatus { initial, loading, loaded, error }

class CdState {
  final CdLoadStatus status;
  final List<CdInfo> myCds;
  final List<CdMarketListing> marketListings;
  final CdApyResult? apy;
  final String? error;

  const CdState({
    this.status = CdLoadStatus.initial,
    this.myCds = const [],
    this.marketListings = const [],
    this.apy,
    this.error,
  });

  CdState copyWith({
    CdLoadStatus? status,
    List<CdInfo>? myCds,
    List<CdMarketListing>? marketListings,
    CdApyResult? apy,
    String? error,
  }) => CdState(
    status: status ?? this.status,
    myCds: myCds ?? this.myCds,
    marketListings: marketListings ?? this.marketListings,
    apy: apy ?? this.apy,
    error: error,
  );
}

// ── Cubit ──

class CdCubit extends Cubit<CdState> {
  final FuegoRPCService _rpc;
  final Future<void>? _backendReady;

  CdCubit(this._rpc, {Future<void>? backendReady})
    : _backendReady = backendReady,
      super(const CdState()) {
    _init();
  }

  Future<void> _init() async {
    if (_backendReady != null) {
      await _backendReady;
    }
    await loadAll();
  }

  Future<void> loadAll() async {
    emit(state.copyWith(status: CdLoadStatus.loading));
    try {
      // cdMarketList has no fuegod backend yet (the CD market does not exist in
      // the daemon), so walletd rejects it. It is loaded independently: a
      // Future.wait would let that one failure discard cdList — the deposits
      // the user actually owns — and blank the whole screen. cdApy is a real
      // endpoint and is loaded with the list; if it ever fails the screen falls
      // back to defaults rather than erroring out the user's CDs.
      final listFuture = _rpc.cdList();
      final apyFuture = _rpc
          .cdApy()
          .catchError((Object _) => const CdApyResult.empty());
      final marketFuture = _rpc.cdMarketList().then<CdMarketListResult>(
        (v) => v,
        onError: (Object _, StackTrace __) => const CdMarketListResult.empty(),
      );

      final results = await Future.wait([listFuture, marketFuture, apyFuture]);
      emit(
        CdState(
          status: CdLoadStatus.loaded,
          myCds: (results[0] as CdListResult).cds,
          marketListings: (results[1] as CdMarketListResult).listings,
          apy: results[2] as CdApyResult,
        ),
      );
    } catch (e) {
      emit(state.copyWith(status: CdLoadStatus.error, error: e.toString()));
    }
  }

  Future<CdCreateResult> createCd({
    required String coin,
    required String amount,
    int? durationBlocks,
  }) async {
    final result = await _rpc.cdCreate(
      coin: coin,
      amount: amount,
      durationBlocks: durationBlocks,
    );
    await loadAll();
    return result;
  }

  Future<CdClaimResult> claimCd(String cdId) async {
    final result = await _rpc.cdClaim(cdId);
    await loadAll();
    return result;
  }

  Future<CdRolloverResult> rolloverCd({
    required String cdId,
    int? newTerm,
  }) async {
    final result = await _rpc.cdRollover(cdId: cdId, newTerm: newTerm);
    await loadAll();
    return result;
  }

  Future<CdSellResult> sellCd({
    required String cdId,
    required String price,
  }) async {
    final result = await _rpc.cdSell(cdId: cdId, price: price);
    await loadAll();
    return result;
  }

  Future<CdBuyResult> buyCd(String listingId) async {
    final result = await _rpc.cdBuy(listingId);
    await loadAll();
    return result;
  }

  Future<void> cancelListing(String listingId) async {
    await _rpc.cdCancelListing(listingId);
    await loadAll();
  }
}
