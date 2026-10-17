import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../models/network_config.dart';
import '../models/wallet.dart';
import '../services/fuego_rpc_service.dart';
import '../services/fuego_vault_service.dart';
import '../services/security_service.dart';

/// Wallet UI/session facade. Secrets live in [FuegoVaultService] + [SecurityService].
/// Never stores placeholder keys. Spend key is never exposed without PIN.
class WalletProvider extends ChangeNotifier {
  static final Logger _logger = Logger('WalletProvider');
  final FuegoRPCService _rpcService;
  final SecurityService _securityService;
  final FuegoVaultService? _vault;

  Wallet? _wallet;
  List<WalletTransaction> _transactions = [];
  bool _isLoading = false;
  bool _isConnected = false;
  bool _isSyncing = false;
  bool _isMining = false;
  bool _isUnlocked = false;
  String? _error;
  String? _nodeUrl;
  Timer? _syncTimer;
  NetworkConfig _networkConfig = NetworkConfig.mainnet;

  int _miningSpeed = 0;
  int _miningThreads = 1;
  ConnectivityResult _connectivityResult = ConnectivityResult.none;

  WalletProvider({
    FuegoRPCService? rpcService,
    SecurityService? securityService,
    FuegoVaultService? vault,
  }) : _rpcService = rpcService ?? FuegoRPCService(),
       _securityService = securityService ?? SecurityService(),
       _vault = vault {
    _initConnectivity();
  }

  Future<void> waitForBackend(Future<void> backendReady) async {
    await backendReady;
    _checkConnection();
  }

  Wallet? get wallet => _wallet;
  List<WalletTransaction> get transactions => _transactions;
  bool get isLoading => _isLoading;
  bool get isConnected => _isConnected;
  bool get isSyncing => _isSyncing;
  bool get isMining => _isMining;
  bool get isUnlocked => _isUnlocked;
  String? get error => _error;
  String? get nodeUrl => _nodeUrl;
  int get miningSpeed => _miningSpeed;
  int get miningThreads => _miningThreads;
  ConnectivityResult get connectivityResult => _connectivityResult;
  NetworkConfig get networkConfig => _networkConfig;

  bool get hasWallet => _wallet != null || (_vault?.existsOnDisk ?? false);
  bool get isWalletSynced => _wallet?.synced ?? false;
  double get syncProgress => _wallet?.syncProgress ?? 0.0;

  /// Spend key for burn / advanced ops — requires the wallet password.
  Future<String?> getPrivateKeyForBurn(String password) async {
    try {
      final keys = await _securityService.getWalletKeys(password);
      if (keys != null) {
        return keys['spendKey'];
      }
      final v = _vault;
      if (v != null && v.isUnlocked) {
        return v.deriveKeypair(0)['secret'] as String?;
      }
      throw Exception('Wallet keys not found');
    } catch (e) {
      _logger.severe('Failed to get private key (auth)');
      _setError('Failed to get private key');
      return null;
    }
  }

  /// Removed insecure unauthenticated access — use [getPrivateKeyForBurn].
  @Deprecated(
    'Use getPrivateKeyForBurn(password) — unauthenticated access removed',
  )
  String? getPrivateKey() {
    _setError('PIN required to access private keys');
    return null;
  }

  bool isValidPrivateKey(String privateKey) {
    final hex = RegExp(r'^[0-9a-fA-F]{64}$');
    return hex.hasMatch(privateKey);
  }

  void clearSensitiveData() {
    _wallet = null;
    _isUnlocked = false;
    _vault?.lock();
    notifyListeners();
  }

  void _initConnectivity() {
    Connectivity().onConnectivityChanged.listen((ConnectivityResult result) {
      _connectivityResult = result;
      notifyListeners();
      if (result != ConnectivityResult.none) {
        _checkConnection();
      } else {
        _isConnected = false;
        notifyListeners();
      }
    });
  }

  Future<bool> createWallet({
    required String password,
    String? mnemonic,
    String? name,
    FuegoVaultService? vault,
  }) async {
    _setLoading(true);
    _clearError();
    try {
      final v = vault ?? _vault;
      if (v == null) {
        throw StateError('Vault service required to create wallet');
      }
      final phrase = mnemonic ?? SecurityService.generateMnemonic();
      if (!SecurityService.validateMnemonic(phrase)) {
        throw Exception('Invalid mnemonic phrase');
      }
      await v.createNew(password: password, mnemonic: phrase, name: name);
      _isUnlocked = true;
      await refreshWallet();
      _setLoading(false);
      return true;
    } catch (e) {
      _setError(e.toString());
      _setLoading(false);
      return false;
    }
  }

  Future<bool> restoreWallet({
    required String mnemonic,
    required String password,
    String? name,
    FuegoVaultService? vault,
  }) async {
    _setLoading(true);
    _clearError();
    try {
      final v = vault ?? _vault;
      if (v == null) {
        throw StateError('Vault service required to restore wallet');
      }
      if (!SecurityService.validateMnemonic(mnemonic)) {
        throw Exception('Invalid mnemonic phrase');
      }
      await v.restoreFromMnemonic(
        mnemonic: mnemonic,
        password: password,
        name: name,
      );
      _isUnlocked = true;
      await refreshWallet();
      _setLoading(false);
      return true;
    } catch (e) {
      _setError(e.toString());
      _setLoading(false);
      return false;
    }
  }

  /// Decrypt and activate a saved wallet file with that wallet's password.
  Future<bool> switchWallet({
    required String id,
    required String password,
  }) async {
    _setLoading(true);
    _clearError();
    try {
      final v = _vault;
      if (v == null) {
        throw StateError('Vault service required to switch wallet');
      }
      await v.switchWallet(id, password);
      await refreshWallet();
      _setLoading(false);
      return true;
    } catch (e) {
      _setError(e.toString());
      _setLoading(false);
      return false;
    }
  }

  /// Delete a saved wallet file (refuses to remove the last one). Removal
  /// is a device-level action gated by the app PIN at the UI layer.
  Future<bool> removeWallet({required String id}) async {
    _setLoading(true);
    _clearError();
    try {
      final v = _vault;
      if (v == null) {
        throw StateError('Vault service required to remove wallet');
      }
      await v.removeWallet(id);
      await refreshWallet();
      _setLoading(false);
      return true;
    } catch (e) {
      _setError(e.toString());
      _setLoading(false);
      return false;
    }
  }

  Future<bool> unlockWallet(String password, {FuegoVaultService? vault}) async {
    _setLoading(true);
    _clearError();
    try {
      final v = vault ?? _vault;
      if (v == null) {
        throw StateError('Vault service required to unlock wallet');
      }
      final ok = await v.unlockActive(password);
      if (!ok) {
        throw Exception('Invalid password');
      }
      _isUnlocked = true;
      await refreshWallet();
      _setLoading(false);
      return true;
    } catch (e) {
      _setError(e.toString());
      _setLoading(false);
      return false;
    }
  }

  Future<bool> unlockWithBiometrics({FuegoVaultService? vault}) async {
    _setLoading(true);
    _clearError();
    try {
      final v = vault ?? _vault;
      if (v == null) throw StateError('Vault service required');
      final bioOk = await _securityService.authenticateWithBiometrics(
        reason: 'Unlock your Fuego wallet',
      );
      if (!bioOk) {
        throw Exception('Biometric authentication failed');
      }
      final unlocked = await v.unlockWithBiometricKey();
      if (!unlocked) {
        throw Exception(
          'Biometric unlock key missing — enter PIN once to re-enable',
        );
      }
      _isUnlocked = true;
      await refreshWallet();
      _setLoading(false);
      return true;
    } catch (e) {
      _setError(e.toString());
      _setLoading(false);
      return false;
    }
  }

  Future<void> lockWallet() async {
    _wallet = null;
    _transactions.clear();
    _isUnlocked = false;
    _vault?.lock();
    _stopSyncTimer();
    notifyListeners();
  }

  Future<bool> hasWalletData() async {
    if (_vault != null) {
      await _vault!.init();
      if (_vault!.existsOnDisk) return true;
    }
    return _securityService.hasWalletData();
  }

  Future<void> refreshWallet() async {
    if (!_isConnected) {
      await _checkConnection();
      if (!_isConnected) {
        // Still allow local address from vault when offline
        if (_vault != null &&
            _vault!.isUnlocked &&
            _vault!.address.isNotEmpty) {
          _wallet = Wallet(
            address: _vault!.address,
            viewKey: '',
            spendKey: '',
            balance: 0,
            unlockedBalance: 0,
            blockchainHeight: 0,
            localHeight: 0,
            synced: false,
          );
          notifyListeners();
        }
        return;
      }
    }

    try {
      _setLoading(true);
      _clearError();

      final balance = await _rpcService.getBalance();
      var address = '';
      if (_vault != null && _vault!.isUnlocked && _vault!.address.isNotEmpty) {
        address = _vault!.address;
      } else {
        address = await _rpcService.getAddress();
      }

      // Never put secret keys into the Wallet model
      _wallet = balance.copyWith(address: address, viewKey: '', spendKey: '');

      if (!isWalletSynced) {
        _startSyncTimer();
      }
      notifyListeners();
    } catch (e) {
      _setError(e.toString());
    } finally {
      _setLoading(false);
    }
  }

  Future<void> refreshTransactions() async {
    try {
      final txs = await _rpcService.getTransactions();
      _transactions = txs;
      notifyListeners();
    } catch (e) {
      _setError('Failed to refresh transactions');
    }
  }

  Future<String?> sendTransaction({
    required String address,
    required double amount,
    required String pin,
    String? paymentId,
    int mixins = 7,
    double feeXfg = 0.008,
  }) async {
    _setLoading(true);
    _clearError();
    try {
      final valid = await _securityService.verifyPIN(pin);
      if (!valid) {
        throw Exception('Invalid PIN');
      }
      if (!_isUnlocked) {
        throw Exception('Wallet is locked');
      }
      final atomicAmount = (amount * 10000000).round();
      final fee = (feeXfg * 10000000).round();
      final unlocked = _wallet?.unlockedBalance ?? 0;
      if (atomicAmount + fee > unlocked) {
        throw Exception('Insufficient unlocked balance (including fee)');
      }

      final request = SendTransactionRequest(
        address: address,
        amount: atomicAmount,
        paymentId: paymentId ?? '',
        fee: fee,
        mixins: mixins,
      );

      final txHash = await _rpcService.sendTransaction(request);
      if (txHash.isEmpty) {
        throw Exception('Empty transaction hash');
      }
      await refreshWallet();
      await refreshTransactions();
      _setLoading(false);
      return txHash;
    } catch (e) {
      _setError(e.toString());
      _setLoading(false);
      return null;
    }
  }

  Future<String> generatePaymentId() async {
    return _rpcService.generatePaymentId();
  }

  Future<String> createIntegratedAddress(String paymentId) async {
    return _rpcService.createIntegratedAddress(paymentId);
  }

  Future<void> startMining({int threads = 1}) async {
    try {
      _miningThreads = threads;
      final success = await _rpcService.startMining(threads: threads);
      if (success) {
        _isMining = true;
        _startMiningStatusTimer();
      }
      notifyListeners();
    } catch (e) {
      _setError('Failed to start mining');
    }
  }

  Future<void> stopMining() async {
    try {
      await _rpcService.stopMining();
      _isMining = false;
      _miningSpeed = 0;
      notifyListeners();
    } catch (e) {
      _setError('Failed to stop mining');
    }
  }

  Future<void> refreshMiningStatus() async {
    try {
      final status = await _rpcService.getMiningStatus();
      _isMining = status['active'] as bool;
      _miningSpeed = status['speed'] as int;
      _miningThreads = status['threads'] as int;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> connectToNode(String url) async {
    _setLoading(true);
    try {
      final uri = Uri.parse(url);
      final host = uri.host;
      final port = uri.port == 80 || uri.port == 443
          ? _networkConfig.daemonRpcPort
          : uri.port;
      _rpcService.updateNode(host, port: port);
      _nodeUrl = url;
      await _checkConnection();
      if (_isConnected && _isUnlocked) {
        await refreshWallet();
      }
    } catch (e) {
      _setError('Invalid node URL');
    }
    _setLoading(false);
  }

  Future<void> updateNetworkConfig(NetworkConfig config) async {
    _networkConfig = config;
    _rpcService.updateNetworkConfig(config);
    if (_nodeUrl != null) {
      final uri = Uri.parse(_nodeUrl!);
      _nodeUrl = '${uri.scheme}://${uri.host}:${config.daemonRpcPort}';
    }
    notifyListeners();
  }

  Future<void> _checkConnection() async {
    try {
      _isConnected = await _rpcService.testConnection();
    } catch (_) {
      _isConnected = false;
    }
    notifyListeners();
  }

  void _startSyncTimer() {
    if (_syncTimer?.isActive == true) return;
    _syncTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_wallet != null && !isWalletSynced) {
        _refreshSyncStatus();
      } else {
        _stopSyncTimer();
      }
    });
  }

  void _stopSyncTimer() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _isSyncing = false;
    notifyListeners();
  }

  void _startMiningStatusTimer() {
    Timer.periodic(const Duration(seconds: 3), (timer) {
      if (_isMining) {
        refreshMiningStatus();
      } else {
        timer.cancel();
      }
    });
  }

  Future<void> _refreshSyncStatus() async {
    try {
      _isSyncing = true;
      final info = await _rpcService.getInfo();
      final balance = await _rpcService.getBalance();
      if (_wallet != null) {
        final height = (info['height'] as num?)?.toInt() ?? 0;
        _wallet = _wallet!.copyWith(
          blockchainHeight: height,
          localHeight: balance.localHeight,
          balance: balance.balance,
          unlockedBalance: balance.unlockedBalance,
          synced: (height - balance.localHeight) <= 1,
        );
      }
      _isSyncing = false;
      notifyListeners();
    } catch (_) {
      _isSyncing = false;
      notifyListeners();
    }
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void _setError(String error) {
    _error = error;
    notifyListeners();
  }

  void _clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _rpcService.dispose();
    super.dispose();
  }
}
