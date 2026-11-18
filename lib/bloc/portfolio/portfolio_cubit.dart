import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/daemon_client.dart';
import '../../models/chain_registry.g.dart';
import '../../models/portfolio.dart';
import '../../services/evm_account_service.dart';
import '../../services/web3_multi_chain_service.dart';

/// State of the home portfolio: live XFG/ΗΞΔŦ pricing plus the lazily read
/// native balances across the EVM chains the wallet can sign on.
class PortfolioState extends Equatable {
  const PortfolioState({
    this.price,
    this.priceLoading = false,
    this.priceError,
    this.holdings = const {},
    this.chainsLoaded = false,
    this.chainsLoading = false,
    this.chainsDone = 0,
    this.chainsTotal = 0,
    this.chainsError,
    this.accountName,
    this.accountAddress,
    this.savedAccountCount = 0,
  });

  final FuegoPrice? price;
  final bool priceLoading;
  final String? priceError;

  /// Registry key → probed holding.
  final Map<String, PortfolioHolding> holdings;
  final bool chainsLoaded;
  final bool chainsLoading;
  final int chainsDone;
  final int chainsTotal;
  final String? chainsError;

  /// The EVM account every chain shares (one key, all EVM networks).
  final String? accountName;
  final String? accountAddress;
  final int savedAccountCount;

  bool get hasAccount => accountAddress != null && accountAddress!.isNotEmpty;

  /// Chains actually holding something, richest first.
  List<PortfolioHolding> get heldHoldings {
    final held = holdings.values.where((h) => h.isHeld).toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));
    return held;
  }

  /// Every row in the drawer: chains holding something first (richest first),
  /// then the empty ones in registry order.
  List<PortfolioHolding> get allHoldings {
    final rows = holdings.values.toList()
      ..sort((a, b) {
        if (a.isHeld != b.isHeld) return a.isHeld ? -1 : 1;
        if (a.amount != b.amount) return b.amount.compareTo(a.amount);
        return _registryIndex(a).compareTo(_registryIndex(b));
      });
    return rows;
  }

  static int _registryIndex(PortfolioHolding holding) {
    final index = kChains.indexWhere((c) => c.key == holding.chainKey);
    return index < 0 ? kChains.length : index;
  }

  int get heldChainCount => heldHoldings.length;

  int get unreadableChainCount =>
      holdings.values.where((h) => !h.reachable).length;

  PortfolioState copyWith({
    FuegoPrice? price,
    bool? priceLoading,
    String? priceError,
    bool clearPriceError = false,
    Map<String, PortfolioHolding>? holdings,
    bool? chainsLoaded,
    bool? chainsLoading,
    int? chainsDone,
    int? chainsTotal,
    String? chainsError,
    bool clearChainsError = false,
    String? accountName,
    String? accountAddress,
    int? savedAccountCount,
  }) => PortfolioState(
    price: price ?? this.price,
    priceLoading: priceLoading ?? this.priceLoading,
    priceError: clearPriceError ? null : (priceError ?? this.priceError),
    holdings: holdings ?? this.holdings,
    chainsLoaded: chainsLoaded ?? this.chainsLoaded,
    chainsLoading: chainsLoading ?? this.chainsLoading,
    chainsDone: chainsDone ?? this.chainsDone,
    chainsTotal: chainsTotal ?? this.chainsTotal,
    chainsError: clearChainsError ? null : (chainsError ?? this.chainsError),
    accountName: accountName ?? this.accountName,
    accountAddress: accountAddress ?? this.accountAddress,
    savedAccountCount: savedAccountCount ?? this.savedAccountCount,
  );

  @override
  List<Object?> get props => [
    price,
    priceLoading,
    priceError,
    holdings,
    chainsLoaded,
    chainsLoading,
    chainsDone,
    chainsTotal,
    chainsError,
    accountName,
    accountAddress,
    savedAccountCount,
  ];
}

/// Loads what the portfolio can prove: the live Hearth price and the native
/// gas-token balance of the active EVM account on every EVM chain.
///
/// The 33-chain sweep runs only when the drawer is first opened (never on home
/// paint) and is bounded to [_probeConcurrency] concurrent RPCs so public
/// endpoints are not hammered.
class PortfolioCubit extends Cubit<PortfolioState> {
  PortfolioCubit({
    required FuegoDaemonClient daemon,
    required EvmAccountService accounts,
    Web3MultiChainService? web3,
  }) : _daemon = daemon,
       _accounts = accounts,
       _web3 = web3,
       super(PortfolioState(chainsTotal: evmChainCount));

  static const int _probeConcurrency = 6;

  /// EVM chains a single account addresses — 33 at the 2026-08-25 registry.
  static final int evmChainCount = kChains
      .where((chain) => chain.family == 'evm')
      .length;

  final FuegoDaemonClient _daemon;
  final EvmAccountService _accounts;

  /// Injected in tests; built lazily on first sweep in the app.
  Web3MultiChainService? _web3;

  /// Fetch the live XFG/ΗΞΔŦ price once. Cheap enough to retry on demand.
  Future<void> loadPrice({bool force = false}) async {
    if (state.priceLoading) return;
    if (state.price != null && !force) return;
    emit(state.copyWith(priceLoading: true, clearPriceError: true));
    try {
      final price = await _daemon.getFuegoPrice();
      if (isClosed) return;
      emit(state.copyWith(price: price, priceLoading: false));
    } on Object {
      if (isClosed) return;
      emit(
        state.copyWith(
          priceLoading: false,
          priceError: 'Live price unavailable',
        ),
      );
    }
  }

  /// Read native balances for every EVM chain on the active account.
  Future<void> loadChains({bool force = false}) async {
    if (state.chainsLoading) return;
    if (state.chainsLoaded && !force) return;

    await _accounts.init();
    if (isClosed) return;

    final account = _accounts.activeAccount;
    final chains = kChains
        .where((chain) => chain.family == 'evm')
        .toList(growable: false);
    final address = account?.address ?? '';

    emit(
      state.copyWith(
        chainsLoading: true,
        chainsDone: 0,
        chainsTotal: chains.length,
        accountName: account?.name,
        accountAddress: address,
        savedAccountCount: _accounts.accounts.length,
        clearChainsError: true,
      ),
    );

    if (address.isEmpty) {
      final rows = <String, PortfolioHolding>{
        for (final chain in chains)
          chain.key: PortfolioHolding.fromChain(
            chain,
            note: 'No EVM wallet on this device',
          ),
      };
      if (isClosed) return;
      emit(
        state.copyWith(
          holdings: Map.unmodifiable(rows),
          chainsLoaded: true,
          chainsLoading: false,
          chainsDone: chains.length,
        ),
      );
      return;
    }

    final web3 = _web3 ??= Web3MultiChainService();
    final rows = <String, PortfolioHolding>{};
    var cursor = 0;
    var done = 0;
    var unreadable = 0;

    Future<void> worker() async {
      while (cursor < chains.length) {
        final chain = chains[cursor++];
        final probe = await web3.probeNativeBalance(address, chain.key);
        rows[chain.key] = PortfolioHolding.fromChain(
          chain,
          amount: probe.amount,
          reachable: probe.ok,
          note: probe.note,
        );
        done++;
        if (!probe.ok) unreadable++;
        if (isClosed) return;
        emit(
          state.copyWith(holdings: Map.unmodifiable(rows), chainsDone: done),
        );
      }
    }

    await Future.wait(
      List<Future<void>>.generate(_probeConcurrency, (_) => worker()),
    );
    if (isClosed) return;

    emit(
      state.copyWith(
        holdings: Map.unmodifiable(rows),
        chainsLoading: false,
        chainsLoaded: true,
        chainsDone: chains.length,
        chainsError: unreadable == chains.length
            ? 'No chain RPC answered — balances unknown'
            : null,
      ),
    );
  }

  /// Refresh price and re-sweep every chain (pull-to-refresh / drawer action).
  Future<void> refresh() async {
    await loadPrice(force: true);
    await loadChains(force: true);
  }
}
