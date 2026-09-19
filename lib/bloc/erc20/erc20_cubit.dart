import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:web3dart/web3dart.dart';
import '../../models/erc20_token.dart';
import '../../services/custom_token_store.dart';
import '../../services/erc20_service.dart';
import '../../services/web3_multi_chain_service.dart';

class Erc20Balance extends Equatable {
  final Erc20Token token;
  final BigInt raw;
  final int decimals;
  final double display;

  const Erc20Balance({
    required this.token,
    required this.raw,
    required this.decimals,
    required this.display,
  });

  @override
  List<Object?> get props => [token, raw, decimals, display];
}

class Erc20State extends Equatable {
  final bool isLoading;
  final String? error;
  final String? address; // 0x holder being inspected
  final Map<String, List<Erc20Balance>> byChain; // chainKey -> balances
  final Map<String, BigInt> allowances; // tokenAddress:spender -> allowance
  final Erc20Token? selectedToken;

  const Erc20State({
    this.isLoading = false,
    this.error,
    this.address,
    this.byChain = const {},
    this.allowances = const {},
    this.selectedToken,
  });

  Erc20State copyWith({
    bool? isLoading,
    String? error,
    bool clearError = false,
    String? address,
    Map<String, List<Erc20Balance>>? byChain,
    Map<String, BigInt>? allowances,
    Erc20Token? selectedToken,
  }) =>
      Erc20State(
        isLoading: isLoading ?? this.isLoading,
        error: clearError ? null : (error ?? this.error),
        address: address ?? this.address,
        byChain: byChain ?? this.byChain,
        allowances: allowances ?? this.allowances,
        selectedToken: selectedToken ?? this.selectedToken,
      );

  List<Erc20Balance> balancesFor(String chainKey) =>
      byChain[chainKey.toLowerCase()] ?? const [];

  bool get hasAddress => address != null && address!.isNotEmpty;

  @override
  List<Object?> get props => [isLoading, error, address, byChain, allowances, selectedToken];
}

class Erc20Cubit extends Cubit<Erc20State> {
  final Erc20Service _erc20;
  // ignore: unused_field — retained for future multi-chain routing via Web3MultiChainService
  final Web3MultiChainService? _web3;
  bool _ownsErc20 = false;

  Erc20Cubit({Erc20Service? erc20, Web3MultiChainService? web3})
      : _erc20 = erc20 ?? Erc20Service(),
        _web3 = web3,
        super(const Erc20State()) {
    if (erc20 == null) _ownsErc20 = true;
  }

  Erc20Service get service => _erc20;

  void selectToken(Erc20Token? token) =>
      emit(state.copyWith(selectedToken: token, clearError: true));

  void setAddress(String address) {
    final trimmed = address.trim();
    if (trimmed.isEmpty) {
      emit(state.copyWith(address: trimmed, byChain: {}, clearError: true));
      return;
    }
    if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(trimmed)) {
      emit(state.copyWith(error: 'Invalid EVM address'));
      return;
    }
    emit(state.copyWith(address: trimmed, clearError: true));
    refresh();
  }

  Future<void> refresh() async {
    final addr = state.address;
    if (addr == null || addr.isEmpty) return;
    emit(state.copyWith(isLoading: true, clearError: true));
    try {
      final Map<String, List<Erc20Balance>> next = {};
      for (final chain in EvmChainKey.values) {
        final tokens = await CustomTokenStore.instance.forChain(chain.key);
        final List<Erc20Balance> balances = [];
        for (final token in tokens) {
          try {
            final raw = await _erc20.balanceOf(
              chainKey: token.chainKey,
              tokenAddress: token.address,
              holderAddress: addr,
            );
            int dec = token.decimals;
            try {
              dec = await _erc20.decimals(chainKey: token.chainKey, tokenAddress: token.address);
            } catch (_) {}
            final display = dec == 0 ? raw.toDouble() : raw.toDouble() / BigInt.from(10).pow(dec).toDouble();
            balances.add(Erc20Balance(token: token, raw: raw, decimals: dec, display: display));
          } catch (e) {
            // Keep token slot even on RPC failure so UI shows error per token not blank list
            debugPrint('Erc20Cubit ${token.chainKey}:${token.symbol} balance failed: $e');
            balances.add(Erc20Balance(token: token, raw: BigInt.zero, decimals: token.decimals, display: 0));
          }
        }
        next[chain.key] = balances;
      }
      emit(state.copyWith(isLoading: false, byChain: next));
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: 'Failed to load token balances: $e'));
    }
  }

  Future<void> refreshChain(String chainKey) async {
    final addr = state.address;
    if (addr == null || addr.isEmpty) return;
    final k = chainKey.toLowerCase();
    final tokens = await CustomTokenStore.instance.forChain(k);
    if (tokens.isEmpty) return;
    emit(state.copyWith(isLoading: true, clearError: true));
    try {
      final List<Erc20Balance> balances = [];
      for (final token in tokens) {
        final raw = await _erc20.balanceOf(chainKey: k, tokenAddress: token.address, holderAddress: addr);
        int dec = token.decimals;
        try {
          dec = await _erc20.decimals(chainKey: k, tokenAddress: token.address);
        } catch (_) {}
        final display = dec == 0 ? raw.toDouble() : raw.toDouble() / BigInt.from(10).pow(dec).toDouble();
        balances.add(Erc20Balance(token: token, raw: raw, decimals: dec, display: display));
      }
      final next = Map<String, List<Erc20Balance>>.from(state.byChain);
      next[k] = balances;
      emit(state.copyWith(isLoading: false, byChain: next));
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: 'Failed to load $chainKey balances: $e'));
    }
  }

  Future<BigInt> checkAllowance({
    required String tokenAddress,
    required String chainKey,
    required String owner,
    required String spender,
  }) async {
    try {
      final v = await _erc20.allowance(chainKey: chainKey, tokenAddress: tokenAddress, owner: owner, spender: spender);
      final key = '${chainKey.toLowerCase()}:${tokenAddress.toLowerCase()}:$spender'.toLowerCase();
      final next = Map<String, BigInt>.from(state.allowances);
      next[key] = v;
      emit(state.copyWith(allowances: next));
      return v;
    } catch (e) {
      emit(state.copyWith(error: 'Allowance check failed: $e'));
      rethrow;
    }
  }

  Future<String> approveIfNeeded({
    required String privateKey,
    required Erc20Token token,
    required String spender,
    required String amountDisplay,
  }) async {
    final owner = state.address;
    if (owner == null || owner.isEmpty) throw StateError('No holder address set');
    int dec = token.decimals;
    try {
      dec = await _erc20.decimals(chainKey: token.chainKey, tokenAddress: token.address);
    } catch (_) {}
    final needed = Erc20Amount.toBaseUnits(amountDisplay, dec);
    final current = await checkAllowance(tokenAddress: token.address, chainKey: token.chainKey, owner: owner, spender: spender);
    if (current >= needed) return 'already-approved';
    return _erc20.approve(chainKey: token.chainKey, privateKey: privateKey, tokenAddress: token.address, spender: spender, amountBaseUnits: needed);
  }

  Future<String> transfer({
    required String privateKey,
    required Erc20Token token,
    required String toAddress,
    required String amountDisplay,
  }) async {
    emit(state.copyWith(isLoading: true, clearError: true));
    try {
      final tx = await _erc20.transferToken(token: token, privateKey: privateKey, toAddress: toAddress, amountDisplay: amountDisplay);
      await refreshChain(token.chainKey);
      emit(state.copyWith(isLoading: false));
      return tx;
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: 'Transfer failed: $e'));
      rethrow;
    }
  }

  // Derive EVM address from private key via web3dart for convenience.
  String addressFromPrivateKey(String privateKey) {
    try {
      final clean = privateKey.startsWith('0x') ? privateKey.substring(2) : privateKey;
      final creds = EthPrivateKey.fromHex(clean);
      // EthPrivateKey exposes address lazily; extract via credentials.address
      return creds.address.hexEip55;
    } catch (_) {
      return '';
    }
  }

  @override
  Future<void> close() {
    if (_ownsErc20) _erc20.dispose();
    return super.close();
  }
}
