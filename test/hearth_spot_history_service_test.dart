import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/bloc/hearth/hearth_cubit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fuego/models/heat_amm.dart';
import 'package:fuego/models/network_config.dart';
import 'package:fuego/services/fuego_daemon_client.dart';
import 'package:fuego/services/hearth_spot_history_service.dart';

PoolInfo _pool(int spotPrice) => PoolInfo(
  reserveXfg: 10000000,
  reserveHeat: 1000000,
  totalLpShares: 1,
  spotPrice: spotPrice,
  epochSwapFees: 0,
  hearthTwap: 0,
  status: 'OK',
);

class _SwitchingDaemon extends FuegoDaemonClient {
  final firstPool = Completer<PoolInfo>();
  int poolCalls = 0;

  _SwitchingDaemon() : super(networkConfig: NetworkConfig.mainnet);

  @override
  Future<PoolInfo> getPoolInfo() {
    poolCalls++;
    return poolCalls == 1 ? firstPool.future : Future.value(_pool(2000000));
  }

  @override
  Future<OrderBookState> getOrderbookState({int depth = 20}) async {
    throw StateError('No order book in test');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Hearth pool fixed-point spot is displayed as HEAT per XFG', () {
    expect(_pool(1000000).heatPerXfg, 0.1);
    expect(_pool(1000000).price, '0.10000000');
  });

  test('pool client tracks the selected network for history partitioning', () {
    final client = FuegoDaemonClient(networkConfig: NetworkConfig.mainnet);
    client.updateNode(
      '127.0.0.1',
      port: NetworkConfig.testnet.daemonRpcPort,
      networkConfig: NetworkConfig.testnet,
    );
    expect(client.networkConfig.networkId, 'fuego-testnet');
  });

  test('pool observations are network-scoped daily samples', () async {
    final history = HearthSpotHistoryService();
    final first = DateTime.utc(2026, 10, 3, 8);
    final later = DateTime.utc(2026, 10, 3, 12);
    final nextDay = DateTime.utc(2026, 10, 4, 8);

    await history.record('fuego-mainnet', _pool(1000000), observedAt: first);
    await history.record('fuego-mainnet', _pool(1100000), observedAt: later);
    final mainnet = await history.record(
      'fuego-mainnet',
      _pool(1200000),
      observedAt: nextDay,
    );

    expect(mainnet, hasLength(2));
    expect(mainnet.first.time, later.millisecondsSinceEpoch ~/ 1000);
    expect(mainnet.first.heatPerXfg, 0.11);
    expect(mainnet.last.heatPerXfg, 0.12);
    expect(await history.load('fuego-testnet'), isEmpty);
    expect(await history.load('fuego-mainnet'), hasLength(2));
  });

  test('unfunded pool creates no observation', () async {
    final history = HearthSpotHistoryService();
    const emptyPool = PoolInfo(
      reserveXfg: 0,
      reserveHeat: 0,
      totalLpShares: 0,
      spotPrice: 0,
      epochSwapFees: 0,
      hearthTwap: 0,
      status: 'OK',
    );

    expect(await history.record('fuego-mainnet', emptyPool), isEmpty);
    expect(await history.load('fuego-mainnet'), isEmpty);
  });

  test('corrupt stored history is not overwritten', () async {
    SharedPreferences.setMockInitialValues({
      'hearth_spot_daily_v1_fuego-mainnet': '{"invalid":true}',
    });
    final history = HearthSpotHistoryService();

    await expectLater(
      history.record('fuego-mainnet', _pool(1000000)),
      throwsFormatException,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('hearth_spot_daily_v1_fuego-mainnet'),
      '{"invalid":true}',
    );
  });

  test(
    'network switch during fetch cannot file pool under old network',
    () async {
      final daemon = _SwitchingDaemon();
      final cubit = HearthCubit(daemon);
      final firstLoad = cubit.loadPool();
      while (daemon.poolCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      final switched = cubit.stream.firstWhere(
        (state) =>
            state.networkId == 'fuego-testnet' &&
            state.spotObservations.isNotEmpty,
      );
      daemon.updateNode(
        '127.0.0.1',
        port: NetworkConfig.testnet.daemonRpcPort,
        networkConfig: NetworkConfig.testnet,
      );
      daemon.firstPool.complete(_pool(1000000));
      await firstLoad;
      final state = await switched;

      expect(state.spotObservations, hasLength(1));
      expect(state.spotObservations.single.heatPerXfg, 0.2);
      expect(await HearthSpotHistoryService().load('fuego-mainnet'), isEmpty);
      expect(
        await HearthSpotHistoryService().load('fuego-testnet'),
        hasLength(1),
      );
      await cubit.close();
      daemon.dispose();
    },
  );
}
