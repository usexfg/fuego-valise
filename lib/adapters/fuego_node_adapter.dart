// Adapter pattern implementation for Fuego node communication
// Inspired by the QT wallet's NodeAdapter pattern

import 'dart:async';
import 'package:dio/dio.dart';
import '../models/network_config.dart';
import 'package:flutter/foundation.dart';

/// Adapter for communicating with the Fuego daemon (fuegod)
/// This abstracts the RPC communication layer, similar to NodeAdapter in the QT wallet
class FuegoNodeAdapter {
  static FuegoNodeAdapter? _instance;
  static FuegoNodeAdapter get instance {
    _instance ??= FuegoNodeAdapter._internal();
    return _instance!;
  }

  final Dio _dio;
  String _nodeUrl;
  NetworkConfig _networkConfig;
  bool _isInitialized = false;
  StreamController<NodeEvent>? _eventController;

  FuegoNodeAdapter._internal()
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
          headers: {'Content-Type': 'application/json'},
        ),
      ),
      _nodeUrl = 'http://localhost:18180',
      _networkConfig = NetworkConfig.mainnet;

  /// Initialize the adapter with a specific node
  Future<bool> init({
    required String nodeUrl,
    NetworkConfig? networkConfig,
    Function(NodeEvent event)? onEvent,
  }) async {
    _nodeUrl = nodeUrl;
    _networkConfig = networkConfig ?? NetworkConfig.mainnet;

    // Setup event stream if callback provided
    if (onEvent != null) {
      _eventController = StreamController<NodeEvent>();
      _eventController!.stream.listen(onEvent);
    }

    try {
      // Test connection
      final response = await _dio.get(
        '$_nodeUrl/getinfo',
        options: Options(responseType: ResponseType.json),
      );

      if (response.statusCode == 200) {
        _isInitialized = true;
        _emitEvent(NodeEvent.initCompleted());
        return true;
      }

      return false;
    } catch (e) {
      debugPrint('NodeAdapter init failed: $e');
      _emitEvent(NodeEvent.initFailed('Failed to connect: $e'));
      return false;
    }
  }

  /// Get network configuration
  NetworkConfig get networkConfig => _networkConfig;

  /// Get current node URL
  String get nodeUrl => _nodeUrl;

  /// Check if adapter is initialized
  bool get isInitialized => _isInitialized;

  /// Get last known block height (remote)
  Future<int> getLastKnownBlockHeight() async {
    try {
      final response = await _dio.get('$_nodeUrl/getinfo');
      return response.data['height'] as int;
    } catch (e) {
      debugPrint('getLastKnownBlockHeight failed: $e');
      return 0;
    }
  }

  /// Get last local block height (what wallet is synced to)
  Future<int> getLastLocalBlockHeight() async {
    // This would typically come from wallet RPC
    // For now, delegate to getLastKnownBlockHeight
    return await getLastKnownBlockHeight();
  }

  /// Get last local block timestamp
  Future<DateTime> getLastLocalBlockTimestamp() async {
    try {
      final response = await _dio.get('$_nodeUrl/getinfo');
      final timestamp = response.data['timestamp'] as int?;
      if (timestamp != null) {
        return DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
      }
    } catch (e) {
      debugPrint('getLastLocalBlockTimestamp failed: $e');
    }
    return DateTime.now();
  }

  /// Get peer count from node
  Future<int> getPeerCount() async {
    try {
      final response = await _dio.get('$_nodeUrl/getinfo');
      return response.data['incoming_connections_count'] as int? ?? 0;
    } catch (e) {
      debugPrint('getPeerCount failed: $e');
      return 0;
    }
  }

  /// Get block hash for a given height
  Future<String?> getBlockHash(int height) async {
    try {
      final response = await _dio.post(
        '$_nodeUrl/json_rpc',
        data: {
          'jsonrpc': '2.0',
          'id': 'test',
          'method': 'on_getblockhash',
          'params': [height],
        },
      );
      return response.data['result'] as String?;
    } catch (e) {
      debugPrint('getBlockHash failed: $e');
      return null;
    }
  }

  /// Get block information by hash
  Future<Map<String, dynamic>?> getBlock(String hash) async {
    try {
      final response = await _dio.post(
        '$_nodeUrl/json_rpc',
        data: {
          'jsonrpc': '2.0',
          'id': 'test',
          'method': 'getblock',
          'params': {'hash': hash},
        },
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('getBlock failed: $e');
      return null;
    }
  }

  /// Convert payment ID string to byte format
  String convertPaymentId(String paymentId) {
    // Implement payment ID conversion logic
    // This is similar to the QT wallet's convertPaymentId
    return paymentId;
  }

  /// Extract payment ID from extra data
  String extractPaymentId(String extra) {
    // Implement payment ID extraction
    // This is similar to the QT wallet's extractPaymentId
    return extra;
  }

  /// Update connection to a new node
  void updateNode(String host, {int? port}) {
    _nodeUrl = 'http://$host:${port ?? _networkConfig.daemonRpcPort}';
    _isInitialized = false;
    init(nodeUrl: _nodeUrl, networkConfig: _networkConfig);
  }

  /// Deinitialize the adapter
  Future<void> deinit() async {
    _isInitialized = false;
    _emitEvent(NodeEvent.deinitCompleted());
    _eventController?.close();
    _eventController = null;
  }

  void _emitEvent(NodeEvent event) {
    _eventController?.add(event);
  }

  void dispose() {
    _eventController?.close();
    _eventController = null;
  }
}

/// Events emitted by the node adapter
class NodeEvent {
  final NodeEventType type;
  final String? message;
  final Map<String, dynamic>? data;

  NodeEvent({required this.type, this.message, this.data});

  factory NodeEvent.initCompleted() =>
      NodeEvent(type: NodeEventType.initCompleted);
  factory NodeEvent.initFailed(String message) =>
      NodeEvent(type: NodeEventType.initFailed, message: message);
  factory NodeEvent.deinitCompleted() =>
      NodeEvent(type: NodeEventType.deinitCompleted);
  factory NodeEvent.peerCountUpdated(int count) =>
      NodeEvent(type: NodeEventType.peerCountUpdated, data: {'count': count});
  factory NodeEvent.blockchainUpdated(int height) => NodeEvent(
    type: NodeEventType.blockchainUpdated,
    data: {'height': height},
  );
}

enum NodeEventType {
  initCompleted,
  initFailed,
  deinitCompleted,
  peerCountUpdated,
  blockchainUpdated,
}
