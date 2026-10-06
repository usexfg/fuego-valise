import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../ffi/fuego_native.dart';

class PoolMiningService {
  Socket? _socket;
  bool _mining = false;
  String _poolHost;
  int _poolPort;
  String _walletAddress;
  int _hashrate = 0;
  Timer? _hashrateTimer;
  int _sharesSubmitted = 0;
  int _sharesAccepted = 0;
  String? _sessionId;
  String? _jobId;
  Uint8List? _blob;
  Uint8List? _target;
  String? _blobHex;
  String _recvBuffer = '';
  int _subscriptionId = 0;
  bool _authorized = false;
  final Random _random = Random();
  VoidCallback? onAuthorized;
  VoidCallback? onDisconnected;
  int _reconnectAttempts = 0;
  Timer? _mineTimer;
  bool _batchBusy = false;
  int _coreCount = 1;

  // Mining stats
  int _totalHashes = 0;
  DateTime? _miningStartTime;

  bool get isMining => _mining;
  int get hashrate => _hashrate;
  int get sharesAccepted => _sharesAccepted;
  int get coreCount => _coreCount;

  PoolMiningService({
    String poolHost = 'loudmining.com',
    int poolPort = 4200,
    String walletAddress = '',
  }) : _poolHost = poolHost,
       _poolPort = poolPort,
       _walletAddress = walletAddress;

  Future<bool> start({
    required String walletAddress,
    String? poolHost,
    int? poolPort,
    int coreCount = 1,
  }) async {
    if (_mining) return true;

    _walletAddress = walletAddress;
    if (poolHost != null) _poolHost = poolHost;
    if (poolPort != null) _poolPort = poolPort;
    final hw = Platform.numberOfProcessors;
    final cap = hw > 0 ? (hw > 8 ? 8 : hw) : 4;
    _coreCount = coreCount.clamp(1, cap);

    return _connect();
  }

  Future<bool> _connect() async {
    try {
      debugPrint('[pool] Connecting to $_poolHost:$_poolPort');
      _socket = await Socket.connect(
        _poolHost,
        _poolPort,
        timeout: const Duration(seconds: 10),
      );

      _socket!.listen(
        _onData,
        onError: (Object e) => debugPrint('[pool] Socket error: $e'),
        onDone: () {
          debugPrint('[pool] Connection closed');
          _handleDisconnect();
        },
      );

      _mining = true;
      _authorized = false;
      _recvBuffer = '';
      _jobId = null;
      _blob = null;
      _target = null;

      // CryptoNote login
      _subscriptionId++;
      _send({
        'id': _subscriptionId,
        'jsonrpc': '2.0',
        'method': 'login',
        'params': {
          'login': _walletAddress,
          'pass': 'x',
          'agent': 'fuego_walletd/1.0',
        },
      });
      debugPrint('[pool] Sent login for $_walletAddress');

      _hashrateTimer?.cancel();
      _hashrateTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        _updateHashrate();
      });

      _reconnectAttempts = 0;
      debugPrint('[pool] Connected');
      return true;
    } catch (e) {
      debugPrint('[pool] Failed to connect: $e');
      _mining = false;
      _socket?.destroy();
      _socket = null;
      return false;
    }
  }

  void _handleDisconnect() {
    _mining = false;
    _authorized = false;
    _hashrateTimer?.cancel();
    _mineTimer?.cancel();
    _socket?.destroy();
    _socket = null;

    if (_reconnectAttempts < 5) {
      _reconnectAttempts++;
      final delay = Duration(seconds: _reconnectAttempts * 3);
      debugPrint(
        '[pool] Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts/5)',
      );
      Future.delayed(delay, () async {
        if (_walletAddress.isNotEmpty) {
          await _connect();
        }
      });
    } else {
      debugPrint('[pool] Max reconnect attempts reached');
      onDisconnected?.call();
    }
  }

  static const _kMaxRecvBuffer = 1 << 20; // 1 MiB cap (ADV-06)
  static const _kMaxLineLen = 64 * 1024; // 64 KiB per line
  void _onData(Uint8List data) {
    // Guard against allowMalformed smuggling — strict utf8, drop malformed chunk
    String chunk;
    try {
      chunk = utf8.decode(data, allowMalformed: false);
    } catch (_) {
      debugPrint('[pool] dropped malformed utf8 chunk (${data.length}B)');
      return;
    }
    _recvBuffer += chunk;
    if (_recvBuffer.length > _kMaxRecvBuffer) {
      debugPrint(
        '[pool] recv buffer overflow (${_recvBuffer.length}) — closing',
      );
      _recvBuffer = '';
      _socket?.destroy();
      _handleDisconnect();
      return;
    }
    while (_recvBuffer.contains('\n')) {
      final idx = _recvBuffer.indexOf('\n');
      final line = _recvBuffer.substring(0, idx).trim();
      _recvBuffer = _recvBuffer.substring(idx + 1);
      if (line.isEmpty) continue;
      if (line.length > _kMaxLineLen) {
        debugPrint('[pool] line too long (${line.length}) — dropping');
        continue;
      }
      try {
        final msg = json.decode(line) as Map<String, dynamic>;
        debugPrint('[pool] RECV: $line');
        _handleMessage(msg);
      } catch (e) {
        debugPrint('[pool] Parse error: $e  raw=$line');
      }
    }
  }

  void _handleMessage(Map<String, dynamic> msg) {
    // Unified result handler: login vs submit (fixes dead second branch)
    if (msg.containsKey('result')) {
      final error = msg['error'];
      final Object? id = msg['id'];

      if (error != null) {
        debugPrint('[pool] Error (id=$id): $error');
        return;
      }

      final dynamic rawResult = msg['result'];
      if (rawResult == null) return;

      // Submit response: result is bool/string, not map
      if (rawResult is bool || rawResult is String) {
        if (rawResult == true || rawResult == 'OK') {
          _sharesAccepted++;
          debugPrint('[pool] Share ACCEPTED! Total: $_sharesAccepted');
        } else {
          debugPrint('[pool] Share REJECTED: $rawResult');
        }
        return;
      }

      if (rawResult is! Map<String, dynamic>) return;
      final result = rawResult;

      // Login response
      final status = result['status'] as String?;
      if (status == 'OK') {
        _sessionId = result['id'] as String?;
        debugPrint('[pool] Login OK. Session: $_sessionId');
        _authorized = true;
        onAuthorized?.call();

        // Process initial job
        final job = result['job'] as Map<String, dynamic>?;
        if (job != null) {
          _processJob(job);
        }
      }
      return;
    }

    // New job notification
    if (msg.containsKey('method')) {
      final method = msg['method'] as String?;
      final params = msg['params'];

      if (method == 'job' && params is Map<String, dynamic>) {
        _processJob(params);
      }
    }
  }

  void _processJob(Map<String, dynamic> job) {
    final jobId = job['job_id'] as String?;
    final blobHex = job['blob'] as String?;
    final targetHex = job['target'] as String?;
    final id = job['id'] as String? ?? _sessionId;

    if (jobId == null || blobHex == null || targetHex == null) {
      debugPrint('[pool] Incomplete job: $job');
      return;
    }

    _jobId = jobId;
    _blobHex = blobHex;
    _sessionId = id;

    // Decode blob and target
    _blob = _hexToBytes(blobHex);
    _target = _hexToBytes(targetHex);

    debugPrint('[pool] Job: $jobId  blob=${_blob!.length}B  target=$targetHex');

    // Start mining this job
    _mineJob();
  }

  void _mineJob() {
    if (_blob == null || _target == null || _jobId == null) return;

    _mineTimer?.cancel();
    _miningStartTime = DateTime.now();
    _totalHashes = 0;

    // Mine in a timer-based loop to avoid blocking the UI
    _mineTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      unawaited(_mineBatch());
    });

    unawaited(_mineBatch());
  }

  Future<void> _mineBatch() async {
    if (_blob == null || _target == null || _jobId == null || !_mining) return;
    if (_batchBusy) return;
    _batchBusy = true;

    try {
      // Run one native hash batch per selected core in separate isolates so
      // synchronous FFI work does not block the UI isolate.
      const batchSize = 1000;
      final startNonce = _totalHashes;
      final jobId = _jobId!;
      final blob = Uint8List.fromList(_blob!);
      final target = Uint8List.fromList(_target!);
      final workers = List.generate(_coreCount, (index) {
        return Isolate.run(() {
          final native = FuegoNative();
          return native.mineShare(
            Uint8List.fromList(blob),
            Uint8List.fromList(target),
            startNonce + index * batchSize,
            batchSize,
          );
        });
      });
      final results = await Future.wait(workers);
      _totalHashes += batchSize * _coreCount;

      for (final result in results) {
        if (result.$1 && _mining && _jobId == jobId) {
          debugPrint(
            '[pool] Found share! nonce=${result.$2} hash=${_bytesToHex(result.$3)}',
          );
          _submitShare(result.$2, result.$3);
          break;
        }
      }

      // Update hashrate every second
      if (_miningStartTime != null) {
        final elapsed = DateTime.now().difference(_miningStartTime!).inSeconds;
        if (elapsed > 0) {
          _hashrate = (_totalHashes / elapsed / 1000).round();
        }
      }
    } catch (e) {
      debugPrint('[pool] Mining error: $e');
    } finally {
      _batchBusy = false;
    }
  }

  void _submitShare(int nonce, Uint8List hash) {
    if (_jobId == null || _sessionId == null || _blobHex == null) return;

    _subscriptionId++;
    final msg = {
      'id': _subscriptionId,
      'jsonrpc': '2.0',
      'method': 'submit',
      'params': {
        'id': _sessionId,
        'job_id': _jobId,
        'nonce': _bytesToHex(
          Uint8List(4)..buffer.asByteData().setInt32(0, nonce, Endian.little),
        ),
        'result': _bytesToHex(hash),
      },
    };

    _send(msg);
    _sharesSubmitted++;
    debugPrint('[pool] Submitted share #$_sharesSubmitted (nonce=$nonce)');
  }

  void _updateHashrate() {
    if (_miningStartTime != null && _mining) {
      final elapsed = DateTime.now().difference(_miningStartTime!).inSeconds;
      if (elapsed > 0) {
        _hashrate = (_totalHashes / elapsed / 1000).round();
      }
    }
  }

  void _send(Map<String, dynamic> msg) {
    if (_socket == null) return;
    try {
      final encoded = '${json.encode(msg)}\n';
      _socket!.write(encoded);
      debugPrint('[pool] SEND: ${encoded.trim()}');
    } catch (e) {
      debugPrint('[pool] Send error: $e');
    }
  }

  static Uint8List _hexToBytes(String hex) {
    if (hex.length % 2 != 0) throw FormatException('odd hex length');
    if (!RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex))
      throw FormatException('non-hex char');
    final bytes = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < hex.length; i += 2) {
      bytes[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return bytes;
  }

  static String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> stop() async {
    _mining = false;
    _authorized = false;
    _hashrateTimer?.cancel();
    _mineTimer?.cancel();
    _recvBuffer = '';
    _reconnectAttempts = 999;
    _socket?.destroy();
    _socket = null;
    debugPrint('[pool] Stopped. Shares: $_sharesAccepted/$_sharesSubmitted');
  }
}
