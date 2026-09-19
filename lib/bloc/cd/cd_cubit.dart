import 'package:flutter_bloc/flutter_bloc.dart';
import '../../models/cd.dart';
import '../../services/cd_auto_renew_store.dart';
import '../../services/fuego_rpc_service.dart';

// ── State ──

enum CdLoadStatus { initial, loading, loaded, error }

class CdState {
  final CdLoadStatus status;
  final List<CdInfo> myCds;
  final CdYieldPool? yieldPool;
  final CdConfig config;

  /// CD ids the user has opted into automatic renewal for.
  final Set<String> autoRenewIds;

  /// CD ids currently being renewed, so the UI can show progress and the
  /// sweep cannot re-enter.
  final Set<String> renewingIds;

  /// Renewal failures keyed by CD id, surfaced rather than swallowed.
  final Map<String, String> renewErrors;

  final String? error;

  const CdState({
    this.status = CdLoadStatus.initial,
    this.myCds = const [],
    this.yieldPool,
    this.config = CdConfig.fallback,
    this.autoRenewIds = const {},
    this.renewingIds = const {},
    this.renewErrors = const {},
    this.error,
  });

  CdState copyWith({
    CdLoadStatus? status,
    List<CdInfo>? myCds,
    CdYieldPool? yieldPool,
    CdConfig? config,
    Set<String>? autoRenewIds,
    Set<String>? renewingIds,
    Map<String, String>? renewErrors,
    String? error,
  }) =>
      CdState(
        status: status ?? this.status,
        myCds: myCds ?? this.myCds,
        yieldPool: yieldPool ?? this.yieldPool,
        config: config ?? this.config,
        autoRenewIds: autoRenewIds ?? this.autoRenewIds,
        renewingIds: renewingIds ?? this.renewingIds,
        renewErrors: renewErrors ?? this.renewErrors,
        error: error,
      );

  List<CdInfo> get activeCds =>
      myCds.where((cd) => !cd.matured).toList()
        ..sort((a, b) => a.blocksToMaturity.compareTo(b.blocksToMaturity));

  List<CdInfo> get maturedCds =>
      myCds.where((cd) => cd.matured).toList()
        ..sort((a, b) => b.depositHeight.compareTo(a.depositHeight));
}

// ── Cubit ──

class CdCubit extends Cubit<CdState> {
  final FuegoRPCService _rpc;
  final CdAutoRenewStore _autoRenew;
  final Future<void>? _backendReady;

  /// One sweep at a time. Renewals broadcast transactions, so overlapping
  /// sweeps could double-spend the same matured CD.
  bool _sweeping = false;

  CdCubit(
    this._rpc, {
    required CdAutoRenewStore autoRenewStore,
    Future<void>? backendReady,
  })  : _autoRenew = autoRenewStore,
        _backendReady = backendReady,
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
      final results = await Future.wait([
        _rpc.cdList(),
        _rpc.cdYieldPool(),
        _rpc.cdConfig(),
      ]);
      final cds = (results[0] as CdListResult).cds;
      // Renewal replaces a CD's id, so drop opt-ins whose CD is gone.
      final ids = await _autoRenew.prune(cds.map((cd) => cd.cdId).toSet());
      emit(state.copyWith(
        status: CdLoadStatus.loaded,
        myCds: cds,
        yieldPool: results[1] as CdYieldPool,
        config: results[2] as CdConfig,
        autoRenewIds: ids,
      ));
      await _sweepAutoRenew();
    } catch (e) {
      emit(state.copyWith(status: CdLoadStatus.error, error: e.toString()));
    }
  }

  /// Reject an out-of-range term before broadcasting. Bounds come from the
  /// daemon's own config, so they follow the network — Currency's deposit
  /// term bounds differ on testnet.
  void _assertTermInRange(int blocks) {
    final c = state.config;
    if (blocks < c.depositMinTerm || blocks > c.depositMaxTerm) {
      throw ArgumentError(
        'CD term must be between ${c.depositMinTerm ~/ c.epochBlocks} and '
        '${c.depositMaxTerm ~/ c.epochBlocks} epochs',
      );
    }
  }

  Future<CdCreateResult> createCd({
    required String coin,
    required String amount,
    required int durationBlocks,
  }) async {
    _assertTermInRange(durationBlocks);
    final result = await _rpc.cdCreate(
      coin: coin,
      amount: amount,
      durationBlocks: durationBlocks,
    );
    await loadAll();
    return result;
  }

  /// Create a ladder server-side, so a mid-way failure reports which rungs
  /// already broadcast instead of losing their hashes.
  Future<List<String>> createLadder(List<Map<String, dynamic>> rungs) async {
    final hashes = await _rpc.cdCreateLadder(rungs);
    await loadAll();
    return hashes;
  }

  Future<CdClaimResult> claimCd(String cdId) async {
    final result = await _rpc.cdClaim(cdId);
    // A claimed CD no longer exists, so drop any renewal opt-in with it.
    await setAutoRenew(cdId, false);
    await loadAll();
    return result;
  }

  Future<CdRolloverResult> rolloverCd({
    required String cdId,
    int? newTermBlocks,
  }) async {
    if (newTermBlocks != null) {
      _assertTermInRange(newTermBlocks);
    }
    final result =
        await _rpc.cdRollover(cdId: cdId, newTermBlocks: newTermBlocks);
    await loadAll();
    return result;
  }

  // ── Auto-renew ──
  //
  // Renewal is a wallet feature, not a chain one. Chain auto-roll is gated
  // behind a v13 TODO in Blockchain.cpp and its CommitmentIndex is never
  // populated, and the mechanism it stubs would double the lock rather than
  // release at maturity. Rolling over here is unlimited and keeps the CD
  // withdrawable at every maturity.
  //
  // The cost, stated plainly: base interest stops accruing at maturity
  // (Currency::calculateCdInterest clamps endEpoch at expiry), so a matured
  // CD earns nothing until the wallet next opens and sweeps it.

  Future<void> setAutoRenew(String cdId, bool enabled) async {
    final ids = Set<String>.from(state.autoRenewIds);
    if (enabled) {
      ids.add(cdId);
    } else {
      ids.remove(cdId);
    }
    await _autoRenew.save(ids);
    final errors = Map<String, String>.from(state.renewErrors)..remove(cdId);
    emit(state.copyWith(autoRenewIds: ids, renewErrors: errors));
    if (enabled) {
      await _sweepAutoRenew();
    }
  }

  /// Roll over every matured CD the user opted in for.
  ///
  /// A CD that failed to renew is not retried until the user acts, so a
  /// persistent failure cannot become a broadcast loop.
  Future<void> _sweepAutoRenew() async {
    if (_sweeping) return;
    final due = state.maturedCds
        .where((cd) => state.autoRenewIds.contains(cd.cdId))
        .where((cd) => !state.renewErrors.containsKey(cd.cdId))
        .toList();
    if (due.isEmpty) return;

    _sweeping = true;
    try {
      for (final cd in due) {
        emit(state.copyWith(
          renewingIds: {...state.renewingIds, cd.cdId},
        ));
        try {
          await _rpc.cdRollover(cdId: cd.cdId, newTermBlocks: cd.termBlocks);
        } catch (e) {
          emit(state.copyWith(
            renewErrors: {...state.renewErrors, cd.cdId: e.toString()},
          ));
        } finally {
          emit(state.copyWith(
            renewingIds: {...state.renewingIds}..remove(cd.cdId),
          ));
        }
      }
    } finally {
      _sweeping = false;
    }
    // Refresh once after the sweep rather than per rollover.
    try {
      final cds = await _rpc.cdList();
      emit(state.copyWith(myCds: cds.cds));
    } catch (_) {
      // Leave the pre-sweep list in place; the next loadAll corrects it.
    }
  }

  /// Clear a renewal failure so the next sweep retries that CD.
  void clearRenewError(String cdId) {
    emit(state.copyWith(
      renewErrors: Map<String, String>.from(state.renewErrors)..remove(cdId),
    ));
  }
}
