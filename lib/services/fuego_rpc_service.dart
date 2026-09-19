// Copyright (c) 2025 Fuego Developers
// Copyright (c) 2025 Elderfire Privacy Group

import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import '../models/wallet.dart';
import '../models/network_config.dart';
import '../models/cd.dart';

class FuegoRPCService {
  final Dio _dio;
  String _baseUrl;
  NetworkConfig _networkConfig;

  /// Mainnet seed list (derived from [NetworkConfig.mainnet.seedNodes]).
  static List<String> get defaultRemoteNodes =>
      NetworkConfig.mainnet.seedNodes;

  FuegoRPCService({
    String host = 'localhost',
    int? port,
    NetworkConfig? networkConfig,
  }) : _baseUrl = 'http://$host:${port ?? NetworkConfig.mainnet.walletRpcPort}',
       _networkConfig = networkConfig ?? NetworkConfig.mainnet,
       _dio = Dio(BaseOptions(
         connectTimeout: const Duration(seconds: 30),
         receiveTimeout: const Duration(seconds: 30),
         headers: {'Content-Type': 'application/json'},
       ));

  /// Point wallet JSON-RPC at [host]:[port].
  ///
  /// Prefer the local fuego_walletd proxy (`127.0.0.1` + walletRpcPort).
  /// Passing a remote seed node without a local proxy is degraded mode.
  void updateNode(String host, {int? port}) {
    final p = port ?? _networkConfig.walletRpcPort;
    _baseUrl = 'http://$host:$p';
  }

  void updateNetworkConfig(NetworkConfig config) {
    _networkConfig = config;
    final uri = Uri.parse(_baseUrl);
    // Keep the current host; only retarget port when it was a known network port.
    final keepPort = uri.port == NetworkConfig.mainnet.walletRpcPort ||
            uri.port == NetworkConfig.testnet.walletRpcPort ||
            uri.port == NetworkConfig.mainnet.daemonRpcPort ||
            uri.port == NetworkConfig.testnet.daemonRpcPort
        ? config.walletRpcPort
        : uri.port;
    _baseUrl = 'http://${uri.host}:$keepPort';
  }

  NetworkConfig get networkConfig => _networkConfig;
  String get currentNodeUrl => _baseUrl;

  // ── Daemon RPC (prefer wallet proxy; fall back to direct chain) ──

  Future<Map<String, dynamic>> getInfo() async {
    // Proxy remaps /json_rpc getinfo → fuegod (works in local and remote-proxy modes).
    try {
      return await _makeRPCCall('getinfo', {});
    } catch (_) {
      return _makeDaemonRPCCall('getinfo', {});
    }
  }

  Future<int> getHeight() async {
    final response = await _makeRPCCall('getheight', {});
    return response['height'] as int;
  }

  Future<Map<String, dynamic>> getBlockHash(int height) async {
    return _makeRPCCall('on_getblockhash', [height]);
  }

  Future<Map<String, dynamic>> getBlock(String hash) async {
    return _makeRPCCall('getblock', {'hash': hash});
  }

  // ── Wallet RPC (routed through Rust proxy → walletd) ──

  Future<Wallet> getBalance() async {
    try {
      // getBalance → proxy remaps to walletd's "getbalance"
      final response = await _makeRPCCall('getBalance', {});
      final info = await getInfo();
      final bchainHeight = info['height'] as int;

      int localHeight = 0;
      try {
        // getStatus → proxy remaps to walletd's "get_height"
        final status = await _makeRPCCall('getStatus', {});
        localHeight = status['height'] as int? ?? 0;
      } catch (_) {}

      final available = response['available_balance'] ?? response['availableBalance'] ?? response['balance'] ?? 0;
      final locked = response['locked_amount'] ?? response['lockedAmount'] ?? 0;

      final effectiveLocal = localHeight > 0 ? localHeight : bchainHeight;

      final availableBal = available as int;
      final lockedBal = locked as int;
      return Wallet(
        address: '',
        viewKey: '',
        spendKey: '',
        // total ≈ available (unlocked) + locked
        balance: availableBal + lockedBal,
        unlockedBalance: availableBal,
        blockchainHeight: bchainHeight,
        localHeight: effectiveLocal,
        synced: (bchainHeight - effectiveLocal) <= 1,
      );
    } catch (e) {
      throw FuegoRPCException('Failed to get balance: $e');
    }
  }

  Future<String> getAddress() async {
    try {
      // getAddresses → proxy remaps to walletd's "get_address"
      final response = await _makeRPCCall('getAddresses', {});
      return response['address'] as String? ?? '';
    } catch (e) {
      throw FuegoRPCException('Failed to get address: $e');
    }
  }

  Future<List<WalletTransaction>> getTransactions({
    int blockCount = 1000000,
    int firstBlockIndex = 0,
  }) async {
    try {
      // getTransactions → proxy remaps to walletd's "get_transfers"
      final response = await _makeRPCCall('getTransactions', {});

      final transfers = response['transfers'] as List? ?? [];
      return transfers.map((tx) {
        final txMap = tx as Map<String, dynamic>;
        return WalletTransaction(
          txid: txMap['transactionHash'] ?? txMap['transaction_hash'] ?? '',
          amount: (txMap['amount'] ?? 0) as int,
          fee: (txMap['fee'] ?? 0) as int,
          paymentId: txMap['paymentId'] ?? txMap['payment_id'] ?? '',
          blockHeight: txMap['blockIndex'] ?? txMap['block_index'] ?? 0,
          timestamp: (txMap['time'] ?? 0) as int,
          isSpending: ((txMap['amount'] ?? 0) as int) < 0,
          address: txMap['address'] as String?,
          confirmations: 0,
        );
      }).toList();
    } catch (e) {
      throw FuegoRPCException('Failed to get transactions: $e');
    }
  }

  Future<String> sendTransaction(SendTransactionRequest request) async {
    try {
      // sendTransaction → proxy remaps to walletd's "transfer"
      // Proxy also converts anonymity → mixin, adds unlock_time
      final response = await _makeRPCCall('sendTransaction', {
        'destinations': [{
          'amount': request.amount,
          'address': request.address,
        }],
        'fee': request.fee,
        'anonymity': request.mixins,
        'paymentId': request.paymentId.isNotEmpty ? request.paymentId : null,
      });

      return response['tx_hash'] as String? ?? response['transactionHash'] as String? ?? '';
    } catch (e) {
      throw FuegoRPCException('Failed to send transaction: $e');
    }
  }

  Future<String> createIntegratedAddress(String paymentId) async {
    try {
      if (paymentId.length != 64 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(paymentId)) {
        throw FuegoRPCException('Invalid payment ID: must be 64 hex characters');
      }

      final address = await getAddress();

      final response = await _makeRPCCall('create_integrated', {
        'address': address,
        'payment_id': paymentId,
      });

      return response['integrated_address'] as String;
    } catch (e) {
      throw FuegoRPCException('Failed to create integrated address: $e');
    }
  }

  Future<String> generatePaymentId() async {
    final bytes = List<int>.generate(32, (i) =>
        DateTime.now().millisecondsSinceEpoch + i);
    return sha256.convert(bytes).toString().substring(0, 64);
  }

  Future<String> registerAlias(String alias, {String? address}) async {
    try {
      final params = <String, dynamic>{'alias': alias};
      if (address != null && address.isNotEmpty) {
        params['address'] = address;
      }
      final response = await _makeRPCCall('register_alias', params);
      return response['tx_hash'] as String? ?? response['transactionHash'] as String? ?? '';
    } catch (e) {
      throw FuegoRPCException('Failed to register alias: $e');
    }
  }


  // ── Mining (routed through proxy → fuegod) ──

  Future<bool> startMining({
    String? address,
    int threads = 1,
  }) async {
    try {
      final minerAddress = address ?? await getAddress();
      await _makeRPCCall('start_mining', {
        'miner_address': minerAddress,
        'threads_count': threads,
      });
      return true;
    } catch (e) {
      throw FuegoRPCException('Failed to start mining: $e');
    }
  }

  Future<bool> stopMining() async {
    try {
      await _makeRPCCall('stop_mining', {});
      return true;
    } catch (e) {
      throw FuegoRPCException('Failed to stop mining: $e');
    }
  }

  Future<Map<String, dynamic>> getMiningStatus() async {
    try {
      final info = await getInfo();
      return {
        'active': (info['mining_speed'] ?? 0) as int > 0,
        'speed': (info['mining_speed'] ?? 0) as int,
        'threads': (info['threads_count'] ?? 0) as int,
      };
    } catch (e) {
      throw FuegoRPCException('Failed to get mining status: $e');
    }
  }

  // ── ΗΞΔŦ Methods ──

  /// DEPRECATED — naming the HEAT side client-side is what consensus
  /// rejects. Use [mintHeat], which sends only the burn amount and lets
  /// walletd derive the HEAT side from the pool.
  @Deprecated('Use mintHeat(xfgBurnedAtomic:) — see HeatMintEngine::validateMint')
  Future<Map<String, dynamic>> heatMint({
    required int xfgBurned,
    required int heatMinted,
    int fee = 0,
    int mixin = 4,
  }) async {
    try {
      final response = await _makeRPCCall('heat_mint', {
        'xfg_burned': xfgBurned,
        'heat_minted': heatMinted,
        'mixin': mixin,
      });
      return response;
    } catch (e) {
      throw FuegoRPCException('Failed to mint ΗΞΔŦ: $e');
    }
  }

  Future<String> sendHeat({
    required String address,
    required int amount,
    int fee = 0,
    int mixin = 4,
  }) async {
    try {
      final response = await _makeRPCCall('send_heat', {
        'address': address,
        'amount': amount,
        'mixin': mixin,
      });
      return response['tx_hash'] as String? ?? '';
    } catch (e) {
      throw FuegoRPCException('Failed to send ΗΞΔŦ: $e');
    }
  }

  Future<({int unlockedHeat, int lockedHeat})> getHeatBalance() async {
    try {
      final response = await _makeRPCCall('getBalance', {});
      final unlockedHeat = (response['unlockedHeatBalance'] ?? 0) as int;
      final lockedHeat = (response['lockedHeatBalance'] ?? 0) as int;
      return (unlockedHeat: unlockedHeat, lockedHeat: lockedHeat);
    } catch (e) {
      throw FuegoRPCException('Failed to get ΗΞΔŦ balance: $e');
    }
  }

  // ── CD Methods ──
  // cd::list → proxy remaps to walletd "list_cds"
  // cd::create → proxy remaps to walletd "create_cd"
  // cd::claim → proxy remaps to walletd "withdraw_cd"
  // cd::market_list → proxy remaps to fuegod "getcdoffers"
  // cd::sell → proxy remaps to fuegod "submitcd"
  // cd::buy → proxy remaps to fuegod "submitcd"
  // cd::cancel_listing → proxy remaps to fuegod "cancelcd"
  // cd::apy → proxy remaps to fuegod/walletd "estimate_cd_yield"

  Future<CdListResult> cdList() async {
    final response = await _makeRPCCall('cd::list', {});
    return CdListResult.fromJson(response);
  }

  Future<CdCreateResult> cdCreate({
    required String coin,
    required String amount,
    int? durationBlocks,
  }) async {
    // The walletd expects atomic units (COIN = 10^7); convert display HEAT.
    final atomic = (double.tryParse(amount) ?? 0) * 10000000;
    final params = <String, dynamic>{
      'coin': coin,
      'amount': atomic.round().toString(),
    };
    if (durationBlocks != null) {
      params['duration_blocks'] = durationBlocks;
    }
    final response = await _makeRPCCall('create_cd', params);
    return CdCreateResult.fromJson(response);
  }

  Future<Map<String, dynamic>> cdConfig() async {
    final response = await _makeRPCCall('cd::config', {});
    return response;
  }

  Future<CdCreateResult> cdCreateLadder(List<Map<String, dynamic>> rungs) async {
    final response = await _makeRPCCall('cd::create_ladder', {'rungs': rungs});
    // Return first tx as representative; ladder creates multiple
    final hashes = response['tx_hashes'] as List<dynamic>?;
    final tx = hashes != null && hashes.isNotEmpty ? hashes.first as String : '';
    return CdCreateResult.fromJson({
      'cd_id': tx,
      'tx_hash': tx,
      'coin': 'HEAT',
      'amount': '',
      'maturity_at': '',
    });
  }

  Future<CdClaimResult> cdClaim(String cdId) async {
    final response = await _makeRPCCall('claim_cd', {'cd_id': cdId});
    return CdClaimResult.fromJson(response);
  }

  Future<CdRolloverResult> cdRollover({
    required String cdId,
    int? newTerm,
  }) async {
    final params = <String, dynamic>{'cd_id': cdId};
    if (newTerm != null) {
      params['new_term'] = newTerm;
    }
    final response = await _makeRPCCall('rollover_cd', params);
    return CdRolloverResult.fromJson(response);
  }

  Future<CdMarketListResult> cdMarketList() async {
    final response = await _makeRPCCall('cd::market_list', {});
    return CdMarketListResult.fromJson(response);
  }

  Future<CdSellResult> cdSell({
    required String cdId,
    required String price,
  }) async {
    final response = await _makeRPCCall('cd::sell', {
      'cd_id': cdId,
      'price': price,
    });
    return CdSellResult.fromJson(response);
  }

  Future<CdBuyResult> cdBuy(String listingId) async {
    final response = await _makeRPCCall('cd::buy', {
      'listing_id': listingId,
    });
    return CdBuyResult.fromJson(response);
  }

  Future<void> cdCancelListing(String listingId) async {
    await _makeRPCCall('cd::cancel_listing', {
      'listing_id': listingId,
    });
  }

  Future<CdApyResult> cdApy() async {
    final response = await _makeRPCCall('cd::apy', {});
    return CdApyResult.fromJson(response);
  }


  // ── Hearth AMM / orderbook ──────────────────────────────────────────
  //
  // Everything here goes through the local fuego_walletd proxy on
  // `walletRpcPort`, never straight at a remote fuegod:
  //   * reads  — the proxy re-POSTs `heat_metrics` / `amm_quote` /
  //              `amm_pool_info` / `get_orderbook_state` to fuegod with a
  //              JSON *body* (core/src/server.rs `is_fuegod_method`).
  //              fuegod's `jsonMethod` handler calls `loadFromJson(req,
  //              request.getBody())`, so query parameters are never read.
  //   * writes — `mint_heat` / `swap` / `add_liq` / `remove_liq` /
  //              `place_limit_order` are wallet methods and need the wallet's
  //              keys (core/src/server.rs `is_wallet_method`). fuegod does not
  //              implement them at all.
  //
  // All amounts crossing this boundary are atomic units (HEAT and XFG both
  // use COIN = 10^7 — see fuego-suite CryptoNoteConfig.h).

  Future<Map<String, dynamic>> heatMetrics() => _makeRPCCall('heat_metrics', {});

  Future<Map<String, dynamic>> ammPoolInfo() => _makeRPCCall('amm_pool_info', {});

  /// [inputAmountAtomic] is atomic units; [direction] is 0 = XFG→HEAT,
  /// 1 = HEAT→XFG, matching `COMMAND_RPC_AMM_QUOTE::request`.
  Future<Map<String, dynamic>> ammQuote({
    required int inputAmountAtomic,
    required bool sellXfg,
  }) =>
      _makeRPCCall('amm_quote', {
        'input_amount': inputAmountAtomic,
        'direction': sellXfg ? 0 : 1,
      });

  Future<Map<String, dynamic>> orderbookState({int pair = 0, int depth = 20}) =>
      _makeRPCCall('get_orderbook_state', {'pair': pair, 'depth': depth});

  /// Burn [xfgBurnedAtomic] XFG to mint HEAT.
  ///
  /// Only the burn amount is sent. walletd derives the HEAT side as
  /// `xfg_burned * spot_price / COIN` from the live pool, which is the same
  /// rule consensus enforces in `HeatMintEngine::validateMint`
  /// (`heatOutputs > expectedHeatFor(xfgBurned, price)` is rejected).
  /// Naming the HEAT amount client-side is how a mint gets rejected or
  /// silently under-mints.
  Future<Map<String, dynamic>> mintHeat({required int xfgBurnedAtomic}) =>
      _makeRPCCall('mint_heat', {'xfg_burned': xfgBurnedAtomic});

  Future<Map<String, dynamic>> ammSwap({
    required bool sellXfg,
    required int inputAmountAtomic,
    required int minOutputAtomic,
  }) =>
      _makeRPCCall('swap', {
        'direction': sellXfg ? 'xfg_to_heat' : 'heat_to_xfg',
        'input_amount': inputAmountAtomic.toString(),
        'min_output': minOutputAtomic.toString(),
      });

  Future<Map<String, dynamic>> ammAddLiquidity({
    required int xfgAmountAtomic,
    required int heatAmountAtomic,
  }) =>
      _makeRPCCall('add_liq', {
        'xfg_amount': xfgAmountAtomic.toString(),
        'heat_amount': heatAmountAtomic.toString(),
      });

  Future<Map<String, dynamic>> ammRemoveLiquidity({
    required int shares,
    required int minXfgAtomic,
    required int minHeatAtomic,
  }) =>
      _makeRPCCall('remove_liq', {
        'shares': shares.toString(),
        'min_xfg': minXfgAtomic.toString(),
        'min_heat': minHeatAtomic.toString(),
      });

  /// [amountAtomic] is atomic units. [priceDisplay] is a human HEAT-per-XFG
  /// decimal — walletd multiplies it by COIN itself, so pre-scaling it here
  /// would square the scale.
  Future<Map<String, dynamic>> placeLimitOrder({
    required bool sellXfg,
    required int amountAtomic,
    required String priceDisplay,
    int ttlBlocks = 8640,
  }) =>
      _makeRPCCall('place_limit_order', {
        'side': sellXfg ? 'sell' : 'buy',
        'amount': amountAtomic.toString(),
        'price': priceDisplay,
        'ttlBlocks': ttlBlocks,
      });

  // ── Private helpers ──


  Future<Map<String, dynamic>> _makeDaemonRPCCall(
    String method,
    dynamic params,
  ) async {
    try {
      // Get daemon host from current node URL
      final uri = Uri.parse(_baseUrl);
      final daemonUrl = 'http://${uri.host}:${_networkConfig.daemonRpcPort}';
      final response = await _dio.post(
        '$daemonUrl/json_rpc',
        data: json.encode({
          'jsonrpc': '2.0',
          'id': DateTime.now().millisecondsSinceEpoch,
          'method': method,
          'params': params,
        }),
      );

      final data = response.data as Map<String, dynamic>;
      if (data.containsKey('error')) {
        throw FuegoRPCException(data['error']['message'] as String);
      }
      return data['result'] as Map<String, dynamic>;
    } on DioException catch (e) {
      throw FuegoRPCException('Network error: ${e.message}');
    }
  }

  Future<Map<String, dynamic>> _makeRPCCall(
    String method,
    dynamic params,
  ) async {
    try {
      final response = await _dio.post(
        '$_baseUrl/json_rpc',
        data: json.encode({
          'jsonrpc': '2.0',
          'id': DateTime.now().millisecondsSinceEpoch,
          'method': method,
          'params': params,
        }),
      );

      final data = response.data as Map<String, dynamic>;

      if (data.containsKey('error')) {
        throw FuegoRPCException(data['error']['message'] as String);
      }

      return data['result'] as Map<String, dynamic>;
    } on DioException catch (e) {
      throw FuegoRPCException('Network error: ${e.message}');
    }
  }

  Future<bool> testConnection() async {
    // 1) Wallet proxy / full wallet API
    try {
      final result = await _makeRPCCall('getBalance', {});
      if (result.containsKey('availableBalance') ||
          result.containsKey('available_balance') ||
          result.containsKey('balance')) {
        return true;
      }
    } catch (_) {}

    // 2) Health endpoint on the proxy — only a proxy-shaped JSON body counts.
    try {
      final resp = await _dio.get(
        _baseUrl.replaceAll(RegExp(r'/json_rpc/?$'), '') + '/health',
        options: Options(receiveTimeout: const Duration(seconds: 5)),
      );
      if (resp.statusCode == 200) {
        final data = resp.data;
        if (data is Map &&
            (data.containsKey('wallet') ||
                data.containsKey('status') ||
                data.containsKey('ok'))) {
          return true;
        }
      }
    } catch (_) {}

    // 3) getInfo is NOT a success signal: a raw chain node may answer it
    //    while the wallet proxy is dead.
    return false;
  }

  void dispose() {
    _dio.close();
  }
}

class FuegoRPCException implements Exception {
  final String message;

  FuegoRPCException(this.message);

  @override
  String toString() => 'FuegoRPCException: $message';
}
