// Copyright (c) 2025 Fuego Developers
// Copyright (c) 2025 Elderfire Privacy Group
//
// DEPRECATED — DO NOT USE.
// This file previously sent `private_key` over HTTP to localhost:8080 (plaintext).
// It has been hard-deprecated. Use FuegoRPCService (via NodeConnection /
// walletd proxy on 127.0.0.1:18189) or FuegoDaemonClient instead, which never
// transmit raw secrets over the wire.

import '../models/wallet.dart';
import '../models/transaction_model.dart';

@Deprecated(
  'Insecure legacy service — private_key over HTTP. '
  'Use FuegoRPCService or FuegoDaemonClient via NodeConnection.',
)
class WalletService {
  // Singleton — retained only for import compatibility; all methods throw.
  static final WalletService _instance = WalletService._internal();
  factory WalletService() => _instance;
  WalletService._internal();

  static Never _unavailable(String method) => throw UnsupportedError(
    'WalletService.$method is removed (insecure: private_key over HTTP). '
    'Use FuegoRPCService.sendTransaction / FuegoDaemonClient via NodeConnection.',
  );

  Future<String> getBalance(String address) async => _unavailable('getBalance');

  Future<String> getAddress() async => _unavailable('getAddress');

  Future<Wallet> createWallet() async => _unavailable('createWallet');

  /// Removed: previously sent `private_key` over HTTP.
  Future<String> sendTransaction({
    required String toAddress,
    required String amount,
    required String privateKey,
  }) async => _unavailable('sendTransaction');

  Future<List<Map<String, dynamic>>> getTransactionHistory() async =>
      _unavailable('getTransactionHistory');

  Future<List<TransactionModel>> getTransactions() async =>
      _unavailable('getTransactions');

  bool isBurnTransaction(Map<String, dynamic> transaction) {
    return transaction['type'] == 'burn' ||
        transaction['to_address'] == null ||
        (transaction['to_address'] as String).isEmpty;
  }
}
