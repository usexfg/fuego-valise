import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/ecc/api.dart' as pcecc;
import 'package:pointycastle/ecc/curves/secp256k1.dart' as pck1;
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/digests/ripemd160.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';
import 'package:pointycastle/api.dart' as pcapi;

/// Bitcoin-family reserve proofs (proof-of-funds) for the orderbook taker
/// flow. Format verified against the C++ chain clients' verifyReserveProof:
///   "address:base64(compact recoverable sig):offerId"
/// signed per the Bitcoin signmessage standard (double-SHA256 over the
/// "\x18Bitcoin Signed Message:\n" + varint(len) + message preimage).
class BitcoinReserveProof {
  static final pcecc.ECDomainParameters _domain = pck1.ECCurve_secp256k1();

  /// Builds the proof. [wif] is the taker's WIF private key.
  /// [p2pkhVersion] is the address prefix byte (BTC/BCH 0x00, LTC 0x30,
  /// KMD 0x3C). DCR's two-byte prefix is handled via [p2pkhVersion2].
  static String build({
    required String wif,
    required String offerId,
    required int p2pkhVersion,
    int? p2pkhVersion2,
  }) {
    final key = _decodeWif(wif);
    final pubCompressed = _privToPubCompressed(key.$1);
    final address = _p2pkhAddress(pubCompressed, p2pkhVersion, p2pkhVersion2);
    final sig = _signMessage(key.$1, key.$2, offerId);
    return '$address:${base64Encode(sig)}:$offerId';
  }

  /// (privkey 32B, compressed flag)
  static (Uint8List, bool) _decodeWif(String wif) {
    final raw = base58decodeChecked(wif);
    if (raw.length == 34) {
      if (raw[33] != 0x01) throw ArgumentError('Unsupported WIF suffix');
      return (Uint8List.fromList(raw.sublist(1, 33)), true);
    }
    if (raw.length == 33) {
      return (Uint8List.fromList(raw.sublist(1, 33)), true);
    }
    if (raw.length == 32) {
      return (Uint8List.fromList(raw), false);
    }
    throw ArgumentError('Invalid WIF length ${raw.length}');
  }

  static Uint8List _privToPubCompressed(Uint8List priv) {
    final d = _bigIntFromBytes(priv);
    if (d <= BigInt.zero || d >= _domain.n)
      throw ArgumentError('Invalid private key');
    final q = _domain.G * d;
    if (q == null) throw StateError('point at infinity');
    return q.getEncoded(true);
  }

  static String _p2pkhAddress(
    Uint8List pubCompressed,
    int version,
    int? version2,
  ) {
    final sha = crypto.sha256.convert(pubCompressed).bytes;
    final h160 = RIPEMD160Digest().process(Uint8List.fromList(sha));
    final payload = <int>[];
    if (version2 != null) payload.add(version2);
    payload.add(version);
    payload.addAll(h160);
    return base58encodeChecked(payload);
  }

  static Uint8List _signMessage(
    Uint8List priv,
    bool compressed,
    String message,
  ) {
    final magic = utf8.encode('\x18Bitcoin Signed Message:\n');
    final msgBytes = utf8.encode(message);
    final varint = _encodeVarInt(msgBytes.length);
    final preimage = <int>[...magic, ...varint, ...msgBytes];
    final digest = Uint8List.fromList(
      crypto.sha256.convert(crypto.sha256.convert(preimage).bytes).bytes,
    );

    final privKey = pcecc.ECPrivateKey(_bigIntFromBytes(priv), _domain);
    // Null digest: sign the 32-byte sha256d digest directly.
    // HMac(SHA256, 64) = RFC6979 nonce derivation.
    final signer = ECDSASigner(null, HMac(SHA256Digest(), 64));
    signer.init(true, pcapi.PrivateKeyParameter(privKey));
    final sig = signer.generateSignature(digest) as pcecc.ECSignature;

    // Low-S normalization (Bitcoin convention).
    var s = sig.s;
    if (s > _domain.n >> 1) s = _domain.n - s;

    final e = _calculateE(_domain.n, digest);
    final recid = _findRecoveryId(_domain.G * privKey.d!, sig.r, s, e);

    final header = 27 + recid + (compressed ? 4 : 0);
    final rBytes = _pad32(_bigIntToBytes(sig.r));
    final sBytes = _pad32(_bigIntToBytes(s));
    return Uint8List.fromList([header, ...rBytes, ...sBytes]);
  }

  static int _findRecoveryId(pcecc.ECPoint? q, BigInt r, BigInt s, BigInt e) {
    if (q == null) throw StateError('q is null');
    final n = _domain.n;
    final rInv = r.modInverse(n);
    // x = r + j*n (j ∈ {0,1}: libsecp256k1's recid bit 1 encodes the
    // overflow case x = r + n). The recid itself = (j << 1) | yParity.
    for (var j = 0; j < 2; ++j) {
      final x = r + BigInt.from(j) * n;
      for (final yTilde in [0, 1]) {
        pcecc.ECPoint? R;
        try {
          R = _domain.curve.decompressPoint(yTilde, x);
        } catch (_) {
          R = null;
        }
        if (R == null) continue;
        final sR = R * s;
        final eG = _domain.G * e;
        if (sR == null || eG == null) continue;
        final diff = sR - eG;
        if (diff == null) continue;
        final qPrime = diff * rInv;
        if (qPrime != null && qPrime == q) return (j << 1) | yTilde;
      }
    }
    throw StateError('recovery id not found');
  }

  static BigInt _calculateE(BigInt n, Uint8List digest) {
    var e = _bigIntFromBytes(digest);
    final excess = digest.length * 8 - n.bitLength;
    if (excess > 0) e = e >> excess;
    return e;
  }

  static List<int> _encodeVarInt(int v) {
    final out = <int>[];
    var value = v;
    while (value >= 0x80) {
      out.add((value & 0x7f) | 0x80);
      value >>= 7;
    }
    out.add(value);
    return out;
  }

  static BigInt _bigIntFromBytes(Uint8List b) {
    var v = BigInt.zero;
    for (final byte in b) v = (v << 8) | BigInt.from(byte);
    return v;
  }

  static Uint8List _bigIntToBytes(BigInt v) {
    final hex = v.toRadixString(16);
    final padded = (hex.length.isOdd ? '0$hex' : hex);
    return Uint8List.fromList(
      List<int>.generate(
        padded.length ~/ 2,
        (i) => int.parse(padded.substring(i * 2, i * 2 + 2), radix: 16),
      ),
    );
  }

  static Uint8List _pad32(Uint8List b) {
    if (b.length == 32) return b;
    if (b.length > 32) return Uint8List.sublistView(b, b.length - 32);
    return Uint8List.fromList([...List<int>.filled(32 - b.length, 0), ...b]);
  }

  static String base58encodeChecked(List<int> payload) {
    final hash = crypto.sha256
        .convert(crypto.sha256.convert(payload).bytes)
        .bytes;
    return base58encode([...payload, ...hash.sublist(0, 4)]);
  }

  static List<int> base58decodeChecked(String s) {
    final raw = base58decode(s);
    if (raw.length < 5) throw ArgumentError('too short');
    final body = raw.sublist(0, raw.length - 4);
    final checksum = raw.sublist(raw.length - 4);
    final hash = crypto.sha256.convert(crypto.sha256.convert(body).bytes).bytes;
    for (var i = 0; i < 4; ++i) {
      if (checksum[i] != hash[i]) throw ArgumentError('bad base58 checksum');
    }
    return body;
  }

  static const _alphabet =
      '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

  static String base58encode(List<int> data) {
    var num = BigInt.zero;
    for (final b in data) num = (num << 8) | BigInt.from(b);
    final chars = <String>[];
    while (num > BigInt.zero) {
      final rem = (num % BigInt.from(58)).toInt();
      chars.add(_alphabet[rem]);
      num ~/= BigInt.from(58);
    }
    for (final b in data) {
      if (b == 0)
        chars.add('1');
      else
        break;
    }
    return chars.reversed.join();
  }

  static List<int> base58decode(String s) {
    var num = BigInt.zero;
    for (final c in s.split('')) {
      final idx = _alphabet.indexOf(c);
      if (idx < 0) throw ArgumentError('invalid base58 char $c');
      num = num * BigInt.from(58) + BigInt.from(idx);
    }
    final bytes = num == BigInt.zero ? <int>[] : _bigIntToBytes(num);
    final leading = <int>[];
    for (final c in s.split('')) {
      if (c == '1')
        leading.add(0);
      else
        break;
    }
    return [...leading, ...bytes];
  }
}
