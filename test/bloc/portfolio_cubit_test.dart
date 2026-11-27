import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fuego/bloc/portfolio/portfolio_cubit.dart';
import 'package:fuego/core/daemon_client.dart';
import 'package:fuego/models/chain_registry.g.dart';
import 'package:fuego/services/evm_account_service.dart';
import 'package:fuego/services/web3_multi_chain_service.dart';

/// Account registry stub — the real one reads a JSON file plus secure storage.
class _FakeAccounts extends EvmAccountService {
  _FakeAccounts({this.account, this.accountCount = 0});

  final EvmAccount? account;
  final int accountCount;

  @override
  Future<void> init() async {}

  @override
  List<EvmAccount> get accounts => account == null
      ? const []
      : List<EvmAccount>.filled(accountCount, account!);

  @override
  EvmAccount? get activeAccount => account;
}

/// Chain probe stub with a controllable latency and outcome table.
class _FakeWeb3 extends Web3MultiChainService {
  _FakeWeb3({
    this.balances = const {},
    this.unreadable = const {},
    this.latency = Duration.zero,
  });

  final Map<String, double> balances;
  final Set<String> unreadable;
  final Duration latency;

  int calls = 0;
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<ChainBalanceProbe> probeNativeBalance(
    String address,
    String chainKey, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    calls++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    inFlight--;
    if (unreadable.contains(chainKey)) {
      return const ChainBalanceProbe(
        amount: 0,
        ok: false,
        note: 'RPC unreachable',
      );
    }
    return ChainBalanceProbe(amount: balances[chainKey] ?? 0, ok: true);
  }
}

FuegoDaemonClient _daemon({
  int status = 200,
  Map<String, dynamic> body = const {
    'xfg_heat_ratio': '0.40000000',
    'heat_peg_usd': '1.5800',
    'xfg_spot_usd': '0.6320',
    'reserve_xfg': 50000000,
    'reserve_heat': 20000000,
    'spot_price': 4000000,
    'height': 120000,
  },
}) {
  final client = MockClient((request) async {
    expect(request.url.path, '/get_fuego_price');
    return http.Response(
      status == 200 ? jsonEncode(body) : '{"status":"Failed"}',
      status,
    );
  });
  return FuegoDaemonClient(host: '127.0.0.1', port: 18180, client: client);
}

const _account = EvmAccount(
  id: 'acct-1',
  name: 'Treasury',
  chainKey: 'eth',
  address: '0x8f3a5b0d21c4e7f9a6b8c1d2e3f4a5b6c7d8e9f0',
  createdAt: 0,
);

int get _evmChainCount =>
    kChains.where((chain) => chain.family == 'evm').length;

void main() {
  group('price', () {
    test('loads the live snapshot from /get_fuego_price', () async {
      final cubit = PortfolioCubit(
        daemon: _daemon(),
        accounts: _FakeAccounts(),
      );
      await cubit.loadPrice();
      expect(cubit.state.price, isNotNull);
      expect(cubit.state.price!.xfgSpotUsd, closeTo(0.632, 1e-9));
      expect(cubit.state.price!.heatPegUsd, closeTo(1.58, 1e-9));
      expect(cubit.state.priceError, isNull);
      expect(cubit.state.priceLoading, isFalse);
      await cubit.close();
    });

    test('degrades to unpriced when the daemon errors', () async {
      final cubit = PortfolioCubit(
        daemon: _daemon(status: 500),
        accounts: _FakeAccounts(),
      );
      await cubit.loadPrice();
      expect(cubit.state.price, isNull);
      expect(cubit.state.priceError, 'Live price unavailable');
      await cubit.close();
    });
  });

  group('chain sweep', () {
    test('without an EVM wallet every chain reads as unlocked', () async {
      final web3 = _FakeWeb3();
      final cubit = PortfolioCubit(
        daemon: _daemon(),
        accounts: _FakeAccounts(),
        web3: web3,
      );
      await cubit.loadChains();
      expect(cubit.state.chainsLoaded, isTrue);
      expect(cubit.state.hasAccount, isFalse);
      expect(cubit.state.holdings.length, _evmChainCount);
      expect(cubit.state.holdings['eth']!.note, 'No EVM wallet on this device');
      expect(web3.calls, 0, reason: 'no address — never touch the network');
      await cubit.close();
    });

    test('reads every chain and keeps unreadable ones unknown', () async {
      final web3 = _FakeWeb3(
        balances: {'eth': 0.5, 'arb': 12.0, 'poly': 340.75},
        unreadable: {'cro'},
      );
      final cubit = PortfolioCubit(
        daemon: _daemon(),
        accounts: _FakeAccounts(account: _account, accountCount: 1),
        web3: web3,
      );
      await cubit.loadChains();

      expect(web3.calls, _evmChainCount);
      expect(cubit.state.holdings['eth']!.amount, 0.5);
      expect(cubit.state.holdings['eth']!.reachable, isTrue);
      expect(cubit.state.holdings['cro']!.reachable, isFalse);
      expect(cubit.state.unreadableChainCount, 1);
      expect(cubit.state.heldChainCount, 3);
      expect(cubit.state.heldHoldings.first.chainKey, 'poly');
      expect(cubit.state.accountName, 'Treasury');
      expect(cubit.state.savedAccountCount, 1);
      await cubit.close();
    });

    test('bounds concurrency so public RPCs are not flooded', () async {
      final web3 = _FakeWeb3(latency: const Duration(milliseconds: 1));
      final cubit = PortfolioCubit(
        daemon: _daemon(),
        accounts: _FakeAccounts(account: _account, accountCount: 1),
        web3: web3,
      );
      await cubit.loadChains();
      expect(web3.calls, _evmChainCount);
      expect(web3.maxInFlight, lessThanOrEqualTo(6));
      await cubit.close();
    });

    test('a second load is a no-op until forced', () async {
      final web3 = _FakeWeb3();
      final cubit = PortfolioCubit(
        daemon: _daemon(),
        accounts: _FakeAccounts(account: _account, accountCount: 1),
        web3: web3,
      );
      await cubit.loadChains();
      await cubit.loadChains();
      expect(web3.calls, _evmChainCount);
      await cubit.loadChains(force: true);
      expect(web3.calls, _evmChainCount * 2);
      await cubit.close();
    });

    test('emitting after close does not throw', () async {
      final web3 = _FakeWeb3(latency: const Duration(milliseconds: 5));
      final cubit = PortfolioCubit(
        daemon: _daemon(),
        accounts: _FakeAccounts(account: _account, accountCount: 1),
        web3: web3,
      );
      final pending = cubit.loadChains();
      await cubit.close();
      await pending;
    });
  });
}
