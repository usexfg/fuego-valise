import 'dart:async';
import 'dart:io';

import 'package:device_preview/device_preview.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bloc/app_bloc_observer.dart';
import 'bloc/auth/auth_cubit.dart';
import 'bloc/cd/cd_cubit.dart';
import 'bloc/dex/dex_cubit.dart';
import 'bloc/hearth/hearth_cubit.dart';
import 'bloc/mining/mining_cubit.dart';
import 'bloc/wallet/wallet_cubit.dart';
import 'core/core.dart';
import 'models/network_config.dart';
import 'providers/wallet_provider.dart';
import 'screens/splash_screen.dart';
import 'services/daemon_manager.dart';
import 'services/fuego_daemon_client.dart' as hearth;
import 'services/fuego_rpc_service.dart';
import 'services/fuego_vault_service.dart';
import 'services/node_connection.dart';
import 'services/security_service.dart';
import 'utils/theme.dart';
import 'utils/xfg_ticker.dart';

final _log = Logger('main');
late final DaemonManager daemonManager = DaemonManager(config: _activeConfig);
final Completer<void> _backendReady = Completer<void>();
final SecurityService _securityService = SecurityService();
final FuegoVaultService _vaultService = FuegoVaultService(
  security: _securityService,
);

String? _daemonError;

bool get useTestnet =>
    Platform.environment['FUEGO_TESTNET'] == '1' ||
    Platform.environment['FUEGO_TESTNET'] == 'true';

NetworkConfig get _activeConfig =>
    useTestnet ? NetworkConfig.testnet : NetworkConfig.mainnet;

/// Platform default: desktop → local, mobile → remote.
/// Prefer [nodeConnection.useLocalNode] after prefs load.
bool get useLocalNode => nodeConnection.useLocalNode;

late final int _backendPort = daemonManager.walletdPort;

late final FuegoRPCService rpcService = FuegoRPCService(
  host: '127.0.0.1',
  port: _backendPort,
  networkConfig: _activeConfig,
);

/// Owns mode/host/port, starts daemons, rewires [rpcService].
late final NodeConnection nodeConnection = NodeConnection(
  daemonManager: daemonManager,
  rpcService: rpcService,
  networkConfig: _activeConfig,
);

/// Chain client — host updated after [nodeConnection.connect].
late final FuegoDaemonClient daemon = FuegoDaemonClient(
  host: nodeConnection.remoteHost,
  port: nodeConnection.remotePort,
  walletPort: _backendPort,
);

void _logDebug(String message) {
  if (kDebugMode) {
    debugPrint(message);
  }
}

Future<void> _startBackend() async {
  try {
    await nodeConnection.loadPreferences();
  } catch (e) {
    _log.warning('Failed to load node prefs: $e');
  }

  _logDebug(
    '[backend] Starting (mode=${nodeConnection.mode}, '
    'desktop=${NodeConnection.isDesktop}, mobile=${NodeConnection.isMobile})',
  );
  _logDebug(
    '[backend] Remote seed ${nodeConnection.remoteHost}:'
    '${nodeConnection.remotePort}  walletPort=$_backendPort',
  );

  ConnectionEndpoints endpoints;
  try {
    endpoints = await nodeConnection.connect(useTestnet: useTestnet);
  } catch (e) {
    _daemonError = e.toString();
    _log.warning('Daemon startup crashed: $e');
    if (!_backendReady.isCompleted) _backendReady.complete();
    return;
  }

  _daemonError = endpoints.error;
  if (endpoints.error != null) {
    _log.warning('Node connection: ${endpoints.error}');
  }
  _logDebug(
    '[backend] wallet=${endpoints.walletBaseUrl} '
    'chain=${endpoints.chainBaseUrl} proxy=${endpoints.proxyRunning}',
  );

  // Keep chain client in sync with resolved endpoint
  daemon.updateNode(endpoints.chainHost, newPort: endpoints.chainPort);

  if (!_backendReady.isCompleted) _backendReady.complete();
}

Future<void> stopBackend() async {
  await nodeConnection.disconnect();
  _daemonError = null;
}

String? get daemonError => _daemonError;

void clearDaemonError() {
  _daemonError = null;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Bloc.observer = AppBlocObserver();

  Logger.root.level = kReleaseMode ? Level.WARNING : Level.INFO;
  Logger.root.onRecord.listen((record) {
    if (kReleaseMode && record.level < Level.WARNING) return;
    // Never log secrets — callers must not put keys in log messages
    debugPrint('${record.level.name}: ${record.time}: ${record.message}');
  });

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Probe vault existence only — do not decrypt or generate secrets
  try {
    await _vaultService.init();
  } catch (e) {
    _log.warning('Vault probe failed (non-fatal)');
  }

  // Apply persisted font preference before the first frame.
  try {
    final prefs = await SharedPreferences.getInstance();
    AppTheme.fontFamily = prefs.getString('app_font_family') ?? 'IBMPlexSans';
    await XfgTicker.load();
  } catch (_) {
    // Default (IBMPlexSans) applies on failure.
  }

  runApp(
    DevicePreview(
      enabled: !kReleaseMode,
      builder: (context) => FuegoApp(
        backendReady: _backendReady.future,
        vaultService: _vaultService,
        securityService: _securityService,
      ),
    ),
  );

  _startBackend();
}

class FuegoApp extends StatefulWidget {
  final Future<void> backendReady;
  final FuegoVaultService vaultService;
  final SecurityService securityService;

  const FuegoApp({
    super.key,
    required this.backendReady,
    required this.vaultService,
    required this.securityService,
  });

  @override
  State<FuegoApp> createState() => _FuegoAppState();
}

class _FuegoAppState extends State<FuegoApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(stopBackend());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // Lock vault when app leaves foreground — keys must not sit in memory
      // while the process is backgrounded or interrupted.
      widget.vaultService.lock();
    }
    if (state == AppLifecycleState.detached) {
      unawaited(stopBackend());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) {
            final wp = WalletProvider(
              rpcService: rpcService,
              securityService: widget.securityService,
              vault: widget.vaultService,
            );
            wp.waitForBackend(widget.backendReady);
            return wp;
          },
        ),
      ],
      child: MultiRepositoryProvider(
        providers: [
          RepositoryProvider<FuegoDaemonClient>.value(value: daemon),
          RepositoryProvider<FuegoRPCService>.value(value: rpcService),
          RepositoryProvider<FuegoVaultService>.value(
            value: widget.vaultService,
          ),
          RepositoryProvider<SecurityService>.value(
            value: widget.securityService,
          ),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthCubit>(create: (_) => AuthCubit()..initialize()),
            BlocProvider<WalletCubit>(
              create: (_) => WalletCubit(
                daemon,
                rpcService: rpcService,
                vault: widget.vaultService,
                backendReady: widget.backendReady,
                security: widget.securityService,
              ),
            ),
            BlocProvider<CdCubit>(
              create: (_) =>
                  CdCubit(rpcService, backendReady: widget.backendReady),
            ),
            BlocProvider<HearthCubit>(
              create: (_) => HearthCubit(
                hearth.FuegoDaemonClient(
                  host: nodeConnection.remoteHost,
                  networkConfig: _activeConfig,
                ),
              ),
            ),
            BlocProvider<DexCubit>(
              create: (_) {
                final dex = DexCubit();
                // Always hit local wallet proxy once backend is up.
                unawaited(
                  widget.backendReady.then((_) {
                    final ep = nodeConnection.lastEndpoints;
                    final host = ep?.walletHost ?? '127.0.0.1';
                    final port = ep?.walletPort ?? _backendPort;
                    return dex.init(host: host, port: port);
                  }),
                );
                return dex;
              },
            ),
            BlocProvider<MiningCubit>(create: (_) => MiningCubit()),
          ],
          child: MaterialApp(
            title: 'Fuego',
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: ThemeMode.dark,
            home: const SplashScreen(),
            debugShowCheckedModeBanner: false,
            useInheritedMediaQuery: true,
          ),
        ),
      ),
    );
  }
}
