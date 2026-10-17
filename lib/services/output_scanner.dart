import 'dart:typed_data';
import 'dart:convert';
import '../ffi/fuego_native.dart';

/// Scans blockchain outputs belonging to our wallet using native FFI.
/// Fetches blocks from fuegod, derives output keys, checks ownership.
class FuegoOutputScanner {
  final FuegoNative _ffi;

  FuegoOutputScanner(this._ffi);

  /// Scan a batch of transactions for outputs belonging to our keys.
  /// Returns {balance: int, outputs: [...], last_scanned_height: int}
  ///
  /// [viewSecret] - 32-byte view secret key (hex)
  /// [spendPublic] - 32-byte spend public key (hex)
  /// [transactions] - list of fuegod transaction objects from gettransactions RPC
  Map<String, dynamic> scanTransactions({
    required String viewSecret,
    required String spendPublic,
    required List<dynamic> transactions,
  }) {
    final viewSk = _hexToBytes(viewSecret);
    final spendPk = _hexToBytes(spendPublic);
    assert(viewSk.length == 32 && spendPk.length == 32);

    int totalBalance = 0;
    final outputs = <Map<String, dynamic>>[];

    for (final txWrapper in transactions) {
      final tx = txWrapper is Map ? (txWrapper['tx'] ?? txWrapper) : txWrapper;
      if (tx is! Map) continue;

      // Extract tx public key from extra field
      final extraHex = tx['extra'] as String? ?? '';
      if (extraHex.length < 66) continue; // Need at least 01 + 32 bytes

      final extraBytes = _hexToBytes(extraHex);
      final txPubKey = _extractTxPublicKey(extraBytes);
      if (txPubKey == null) continue;

      // Compute key derivation: derivation = 8 * txPubKey * viewSecret
      final derivationHex = _ffi.generateKeyDerivation(txPubKey, viewSk);
      if (derivationHex.isEmpty) continue;
      final derivation = _hexToBytes(derivationHex);

      // Scan each output
      final vout = tx['vout'] as List<dynamic>? ?? [];
      for (var i = 0; i < vout.length; i++) {
        final output = vout[i] as Map<String, dynamic>?;
        if (output == null) continue;

        final amount = output['amount'];
        if (amount == null) continue;
        final amountInt = amount is int
            ? amount
            : int.tryParse(amount.toString()) ?? 0;

        // Actual output key from the transaction (target.key hex).
        final target = output['target'] as Map<String, dynamic>?;
        final outKeyHex = target?['key'] as String? ?? '';
        if (outKeyHex.length != 64) continue;

        // Standard CryptoNote discovery: P == Hs(D || i) * G + B, where B is
        // our spend public key.
        final expectedKeyHex = _ffi.derivePublicKey(derivation, i, spendPk);
        if (expectedKeyHex.isEmpty) continue;

        // Check if it matches the transaction's output key.
        if (outKeyHex.toLowerCase() == expectedKeyHex.toLowerCase()) {
          // Generate key image for spent detection
          final keyImageHex = _ffi.generateKeyImage(spendPk, viewSk);

          totalBalance += amountInt;
          outputs.add({
            'amount': amountInt,
            'output_index': i,
            'tx_hash': txWrapper is Map ? (txWrapper['tx_hash'] ?? '') : '',
            'key_image': keyImageHex,
          });
        }
      }
    }

    return {
      'balance': totalBalance,
      'outputs': outputs,
      'count': outputs.length,
    };
  }

  /// Extract the 32-byte tx public key from the extra field.
  /// Standard CryptoNote format: tag 0x01 followed by 32 bytes.
  Uint8List? _extractTxPublicKey(List<int> extra) {
    for (var i = 0; i < extra.length - 33; i++) {
      if (extra[i] == 0x01) {
        return Uint8List.fromList(extra.sublist(i + 1, i + 33));
      }
    }
    return null;
  }

  Uint8List _hexToBytes(String hex) {
    final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
    final bytes = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
