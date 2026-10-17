// Adapter pattern implementation for Fuego wallet operations
// Inspired by the QT wallet's WalletAdapter pattern

import 'dart:async';
import 'package:dio/dio.dart';
import '../models/wallet.dart';
import '../models/network_config.dart';
import 'package:flutter/foundation.dart';

/// Adapter for wallet operations, similar to WalletAdapter in the QT wallet
/// This encapsulates all wallet-related functionality including:
/// - Wallet creation and opening
/// - Balance queries
/// - Transaction operations
/// - Deposit operations
/// - Synchronization
class FuegoWalletAdapter {
  static FuegoWalletAdapter? _instance;
  static FuegoWalletAdapter get instance {
    _instance ??= FuegoWalletAdapter._internal();
    return _instance!;
  }

  final Dio _dio;
  final String _walletRpcUrl;
  // ignore: unused_field — reserved for network-aware routing (mainnet vs testnet)
  final NetworkConfig _networkConfig;
  Wallet? _wallet;
  bool _isOpen = false;
  bool _isSynchronized = false;
  Timer? _syncTimer;
  StreamController<WalletEvent>? _eventController;

  FuegoWalletAdapter._internal()
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
          headers: {'Content-Type': 'application/json'},
        ),
      ),
      _walletRpcUrl = 'http://localhost:18189',
      _networkConfig = NetworkConfig.mainnet;

  /// Open an existing wallet file
  Future<bool> open({
    required String walletPath,
    String? password,
    Function(WalletEvent event)? onEvent,
  }) async {
    try {
      // Setup event stream if callback provided
      if (onEvent != null) {
        _eventController = StreamController<WalletEvent>();
        _eventController!.stream.listen(onEvent);
      }

      // Call wallet RPC to open the wallet
      final response = await _dio.post(
        '$_walletRpcUrl/json_rpc',
        data: {
          'jsonrpc': '2.0',
          'id': 'test',
          'method': 'open_wallet',
          'params': {'filename': walletPath, 'password': password ?? ''},
        },
      );

      if (response.data['error'] != null) {
        _emitEvent(WalletEvent.openFailed(response.data['error']['message']));
        return false;
      }

      _isOpen = true;
      _startSync();
      _emitEvent(WalletEvent.opened());
      return true;
    } catch (e) {
      debugPrint('WalletAdapter open failed: $e');
      _emitEvent(WalletEvent.openFailed('Failed to open wallet: $e'));
      return false;
    }
  }

  /// Create a new wallet
  Future<bool> createWallet({
    String? password,
    Function(WalletEvent event)? onEvent,
  }) async {
    try {
      if (onEvent != null) {
        _eventController = StreamController<WalletEvent>();
        _eventController!.stream.listen(onEvent);
      }

      // Create wallet via wallet RPC
      final response = await _dio.post(
        '$_walletRpcUrl/json_rpc',
        data: {
          'jsonrpc': '2.0',
          'id': 'test',
          'method': 'create_wallet',
          'params': {
            'filename': 'fuego_wallet',
            'password': password ?? '',
            'language': 'English',
          },
        },
      );

      if (response.data['error'] != null) {
        _emitEvent(
          WalletEvent.creationFailed(response.data['error']['message']),
        );
        return false;
      }

      _isOpen = true;
      _startSync();
      _emitEvent(WalletEvent.created());
      return true;
    } catch (e) {
      debugPrint('WalletAdapter createWallet failed: $e');
      _emitEvent(WalletEvent.creationFailed('Failed to create wallet: $e'));
      return false;
    }
  }

  /// Create wallet with given keys
  Future<bool> createWithKeys({
    required String viewKey,
    required String spendKey,
    String? password,
    Function(WalletEvent event)? onEvent,
  }) async {
    try {
      if (onEvent != null) {
        _eventController = StreamController<WalletEvent>();
        _eventController!.stream.listen(onEvent);
      }

      final response = await _dio.post(
        '$_walletRpcUrl/json_rpc',
        data: {
          'jsonrpc': '2.0',
          'id': 'test',
          'method': 'create_wallet',
          'params': {
            'filename': 'fuego_wallet',
            'password': password ?? '',
            'restore_height': 0,
            'restore_deterministic_wallet': true,
            'viewkey': viewKey,
            'spendkey': spendKey,
          },
        },
      );

      if (response.data['error'] != null) {
        _emitEvent(
          WalletEvent.creationFailed(response.data['error']['message']),
        );
        return false;
      }

      _isOpen = true;
      _startSync();
      _emitEvent(WalletEvent.opened());
      return true;
    } catch (e) {
      debugPrint('WalletAdapter createWithKeys failed: $e');
      _emitEvent(
        WalletEvent.creationFailed('Failed to create wallet with keys: $e'),
      );
      return false;
    }
  }

  /// Get wallet address
  Future<String> getAddress() async {
    if (!_isOpen) throw Exception('Wallet is not open');

    try {
      final response = await _dio.post(
        '$_walletRpcUrl/json_rpc',
        data: {'jsonrpc': '2.0', 'id': 'test', 'method': 'getAddress'},
      );

      return response.data['result']['address'] as String;
    } catch (e) {
      debugPrint('getAddress failed: $e');
      rethrow;
    }
  }

  /// Get actual balance (spendable)
  Future<int> getActualBalance() async {
    if (!_isOpen) return 0;

    try {
      final response = await _dio.post(
        '$_walletRpcUrl/json_rpc',
        data: {'jsonrpc': '2.0', 'id': 'test', 'method': 'getBalance'},
      );

      return response.data['result']['balance'] as int;
    } catch (e) {
      debugPrint('getActualBalance failed: $e');
      return 0;
    }
  }

  /// Get pending balance (not yet spendable)
  Future<int> getPendingBalance() async {
    if (!_isOpen) return 0;

    try {
      final response = await _dio.post(
        '$_walletRpcUrl/json_rpc',
        data: {'jsonrpc': '2.0', 'id': 'test', 'method': 'getBalance'},
      );

      return response.data['result']['unlocked_balance'] as int;
    } catch (e) {
      debugPrint('getPendingBalance failed: $e');
      return 0;
    }
  }

  /// Send a transaction
  Future<String> sendTransaction({
    required Map<String, int> destinations, // address -> amount
    int? fee,
    String? paymentId,
    int mixin = 4,
    List<Map<String, String>>? messages,
  }) async {
    if (!_isOpen) throw Exception('Wallet is not open');

    try {
      final response = await _dio.post(
        '$_walletRpcUrl/json_rpc',
        data: {
          'jsonrpc': '2.0',
          'id': 'test',
          'method': 'transfer',
          'params': {
            'destinations': destinations,
            'fee': fee ?? 1000000000, // deprecated default
            'payment_id': paymentId,
            'mixin': mixin,
            'get_tx_key': true,
          },
        },
      );

      final txHash = response.data['result']['tx_hash'] as String;
      _emitEvent(WalletEvent.transactionCreated(txHash));
      return txHash;
    } catch (e) {
      debugPrint('sendTransaction failed: $e');
      throw Exception('Failed to send transaction: $e');
    }
  }

  /// Create a deposit (CD banking)
  Future<String> createDeposit({
    required int term, // in blocks (e.g., 777600 for 90 days @ 1 block/min)
    required int amount,
    int? fee,
    int mixin = 4,
  }) async {
    if (!_isOpen) throw Exception('Wallet is not open');

    try {
      final response = await _dio.post(
        '$_walletRpcUrl/json_rpc',
        data: {
          'jsonrpc': '2.0',
          'id': 'test',
          'method': 'create_deposit',
          'params': {
            'term': term,
            'amount': amount,
            'fee': fee ?? 1000000000,
            'mixin': mixin,
          },
        },
      );

      final txHash = response.data['result']['tx_hash'] as String;
      _emitEvent(WalletEvent.depositCreated(txHash));
      return txHash;
    } catch (e) {
      debugPrint('createDeposit failed: $e');
      throw Exception('Failed to create deposit: $e');
    }
  }

  /// Withdraw deposits
  Future<String> withdrawDeposits({
    required List<String> depositIds,
    int? fee,
  }) async {
    if (!_isOpen) throw Exception('Wallet is not open');

    try {
      final response = await _dio.post(
        '$_walletRpcUrl/json_rpc',
        data: {
          'jsonrpc': '2.0',
          'id': 'test',
          'method': 'withdraw_deposit',
          'params': {'deposit_ids': depositIds, 'fee': fee ?? 1000000000},
        },
      );

      final txHash = response.data['result']['tx_hash'] as String;
      _emitEvent(WalletEvent.depositWithdrawalCreated(txHash));
      return txHash;
    } catch (e) {
      debugPrint('withdrawDeposits failed: $e');
      throw Exception('Failed to withdraw deposits: $e');
    }
  }

  /// Save wallet
  Future<bool> save() async {
    if (!_isOpen) return false;

    try {
      await _dio.post(
        '$_walletRpcUrl/json_rpc',
        data: {'jsonrpc': '2.0', 'id': 'test', 'method': 'store'},
      );
      return true;
    } catch (e) {
      debugPrint('save failed: $e');
      return false;
    }
  }

  /// Close the wallet
  Future<void> close() async {
    if (!_isOpen) return;

    _syncTimer?.cancel();
    _isOpen = false;
    _isSynchronized = false;
    _emitEvent(WalletEvent.closed());
    _eventController?.close();
  }

  void _startSync() {
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      await _updateSyncStatus();
    });
  }

  Future<void> _updateSyncStatus() async {
    try {
      // Check sync status via wallet RPC
      // This would poll for blockchain updates
      // For now, emit a placeholder event
      _emitEvent(WalletEvent.synchronizationProgress(50, 100));
    } catch (e) {
      debugPrint('_updateSyncStatus failed: $e');
    }
  }

  void _emitEvent(WalletEvent event) {
    _eventController?.add(event);
  }

  bool get isOpen => _isOpen;
  bool get isSynchronized => _isSynchronized;
  Wallet? get wallet => _wallet;

  void dispose() {
    _syncTimer?.cancel();
    _eventController?.close();
    _eventController = null;
  }
}

/// Events emitted by the wallet adapter
class WalletEvent {
  final WalletEventType type;
  final String? message;
  final Map<String, dynamic>? data;

  WalletEvent({required this.type, this.message, this.data});

  factory WalletEvent.opened() => WalletEvent(type: WalletEventType.opened);
  factory WalletEvent.openFailed(String message) =>
      WalletEvent(type: WalletEventType.openFailed, message: message);
  factory WalletEvent.created() => WalletEvent(type: WalletEventType.created);
  factory WalletEvent.creationFailed(String message) =>
      WalletEvent(type: WalletEventType.creationFailed, message: message);
  factory WalletEvent.closed() => WalletEvent(type: WalletEventType.closed);
  factory WalletEvent.transactionCreated(String txHash) => WalletEvent(
    type: WalletEventType.transactionCreated,
    data: {'txHash': txHash},
  );
  factory WalletEvent.depositCreated(String txHash) => WalletEvent(
    type: WalletEventType.depositCreated,
    data: {'txHash': txHash},
  );
  factory WalletEvent.depositWithdrawalCreated(String txHash) => WalletEvent(
    type: WalletEventType.depositWithdrawalCreated,
    data: {'txHash': txHash},
  );
  factory WalletEvent.synchronizationProgress(int current, int total) =>
      WalletEvent(
        type: WalletEventType.synchronizationProgress,
        data: {'current': current, 'total': total},
      );
}

enum WalletEventType {
  opened,
  openFailed,
  created,
  creationFailed,
  closed,
  transactionCreated,
  depositCreated,
  depositWithdrawalCreated,
  synchronizationProgress,
}
