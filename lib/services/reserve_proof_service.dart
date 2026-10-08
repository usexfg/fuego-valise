import 'dart:convert';
import 'dart:typed_data';

import 'package:solana/base58.dart' as b58;
import 'package:solana/solana.dart' as solana;
import 'package:web3dart/web3dart.dart';

/// Builds chain reserve proofs (proof-of-funds) for the orderbook taker flow.
///
/// Formats are verified against the C++ SwapDaemon chain clients'
/// `verifyReserveProof` implementations:
///   EVM chains: "<0x-address>:<130 hex chars recoverable sig>:<offerId>"
///               digest = EIP-191 personal_sign over the offerId.
///   SOL:        "<base58 pubkey>:<base58 64-byte sig>:<offerId>"
///               Ed25519 over the raw offerId bytes.
///
/// Bitcoin-family proofs need the Bitcoin signmessage format and are built
/// elsewhere; XMR proofs require monero-wallet-rpc (`get_reserve_proof`).
class ReserveProofService {
  /// EVM reserve proof. [privateKeyHex] is the 64-hex-char private key of the
  /// funded address (any EVM chain — the scheme is chain-agnostic).
  static String buildEvmProof({
    required String offerId,
    required String privateKeyHex,
  }) {
    final credentials = EthPrivateKey.fromHex(privateKeyHex);
    final messageBytes = Uint8List.fromList(utf8.encode(offerId));
    final sig = credentials.signPersonalMessageToUint8List(messageBytes);
    // web3dart returns 65 bytes: r(32) + s(32) + v(1). The C++ side accepts
    // v as 27/28 or 0/1; normalize to 27/28 for canonical storage.
    final v = sig[64];
    final normalizedV = (v < 27) ? (v + 27) : v;
    final hex =
        sig
            .sublist(0, 64)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join() +
        normalizedV.toRadixString(16).padLeft(2, '0');
    final address = credentials.address.hex; // lowercase "0x..."
    return '$address:$hex:$offerId';
  }

  /// Solana reserve proof. [privateKeyHex] is the 64-hex-char (32-byte)
  /// private key of the funded account.
  static Future<String> buildSolProof({
    required String offerId,
    required String privateKeyHex,
  }) async {
    final keyBytes = _hexToBytes(privateKeyHex);
    final keypair = await solana.Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: keyBytes,
    );
    final messageBytes = Uint8List.fromList(utf8.encode(offerId));
    final signature = await keypair.sign(messageBytes.toList());
    final pub = b58.base58encode(keypair.publicKey.bytes);
    final sigB58 = b58.base58encode(signature.bytes);
    return '$pub:$sigB58:$offerId';
  }

  static List<int> _hexToBytes(String hex) {
    final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
    if (clean.length % 2 != 0) throw ArgumentError('Invalid hex length');
    final out = <int>[];
    for (var i = 0; i < clean.length; i += 2) {
      out.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    return out;
  }
}
