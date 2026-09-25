import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

/// Native Fuego library bindings via dart:ffi.
class FuegoNative {
  late final DynamicLibrary _lib;

  FuegoNative() {
    _lib = _openLibrary();
  }

  DynamicLibrary _openLibrary() {
    if (Platform.isMacOS) {
      final appDir = Directory(Platform.resolvedExecutable).parent.path;
      final candidates = [
        '$appDir/Frameworks/libfuego_ffi.dylib',
        '$appDir/Resources/libfuego_ffi.dylib',
        '$appDir/libfuego_ffi.dylib',
        '${Directory.current.path}/macos/Runner/libfuego_ffi.dylib',
      ];
      for (final path in candidates) {
        if (File(path).existsSync()) {
          return DynamicLibrary.open(path);
        }
      }
      return DynamicLibrary.open('libfuego_ffi.dylib');
    }
    if (Platform.isLinux) {
      final bundled =
          '${File(Platform.resolvedExecutable).parent.path}/lib/libfuego_ffi.so';
      return DynamicLibrary.open(
          File(bundled).existsSync() ? bundled : 'libfuego_ffi.so');
    }
    if (Platform.isWindows) return DynamicLibrary.open('fuego_ffi.dll');
    if (Platform.isAndroid) return DynamicLibrary.open('libfuego_ffi.so');
    // iOS: libfuego_ffi.a is force-loaded into Runner (see ios/Runner.xcodeproj).
    if (Platform.isIOS) return DynamicLibrary.process();
    throw UnsupportedError('Unsupported platform');
  }

  void _freeString(Pointer<Utf8> ptr) {
    if (ptr != nullptr) {
      _lib.lookupFunction<_FreeStringNative, _FreeStringDart>('fuego_string_free')(ptr);
    }
  }

  void _freeBytes(Pointer<Uint8> ptr, int len) {
    if (ptr != nullptr) {
      _lib.lookupFunction<_FreeBytesNative, _FreeBytesDart>('fuego_bytes_free')(ptr, len);
    }
  }

  String get version {
    final fn = _lib.lookupFunction<_VersionNative, _VersionDart>('fuego_version');
    final ptr = fn();
    final s = ptr.toDartString();
    _freeString(ptr);
    return s;
  }

  /// Generate a random keypair.
  Map<String, dynamic> keypairGenerate() {
    final fn = _lib.lookupFunction<_KeypairGenNative, _KeypairGenDart>('fuego_keypair_generate');
    final ptr = fn();
    final json = ptr.toDartString();
    _freeString(ptr);
    return _parseJson(json);
  }

  /// Create keypair from 32-byte secret.
  Map<String, dynamic> keypairFromSecret(List<int> secret) {
    assert(secret.length == 32);
    final ptr = _allocBytes(secret);
    final fn = _lib.lookupFunction<_KeypairFromSecretNative, _KeypairFromSecretDart>('fuego_keypair_from_secret');
    final result = fn(ptr);
    final json = result.toDartString();
    _freeString(result);
    calloc.free(ptr);
    return _parseJson(json);
  }

  /// Generate Fuego address from spend + view public keys.
  String makeAddress(List<int> spendPub, List<int> viewPub) {
    assert(spendPub.length == 32 && viewPub.length == 32);
    final spendPtr = _allocBytes(spendPub);
    final viewPtr = _allocBytes(viewPub);
    final fn = _lib.lookupFunction<_MakeAddressNative, _MakeAddressDart>('fuego_make_address');
    final result = fn(spendPtr, viewPtr);
    final addr = result.toDartString();
    _freeString(result);
    calloc.free(spendPtr);
    calloc.free(viewPtr);
    return addr;
  }

  /// Generate a new vault.
  Uint8List vaultGenerate() {
    final fn = _lib.lookupFunction<_VaultGenNative, _VaultGenDart>('fuego_vault_generate');
    final result = fn();
    return _bytesToList(result);
  }

  /// Create vault from 32-byte seed.
  Uint8List vaultFromSeed(List<int> seed) {
    assert(seed.length == 32);
    final ptr = _allocBytes(seed);
    final fn = _lib.lookupFunction<_VaultFromSeedNative, _VaultFromSeedDart>('fuego_vault_from_seed');
    final result = fn(ptr);
    final bytes = _bytesToList(result);
    calloc.free(ptr);
    return bytes;
  }

  /// Get address from vault at index.
  String vaultGetAddress(Uint8List vaultBytes, int index) {
    final vaultPtr = _allocUint8List(vaultBytes);
    final fn = _lib.lookupFunction<_VaultGetAddrNative, _VaultGetAddrDart>('fuego_vault_get_address');
    final result = fn(vaultPtr, vaultBytes.length, index);
    final addr = result.toDartString();
    _freeString(result);
    calloc.free(vaultPtr);
    return addr;
  }

  /// Get seed from vault.
  String vaultGetSeed(Uint8List vaultBytes) {
    final vaultPtr = _allocUint8List(vaultBytes);
    final fn = _lib.lookupFunction<_VaultGetSeedNative, _VaultGetSeedDart>('fuego_vault_get_seed');
    final result = fn(vaultPtr, vaultBytes.length);
    final seed = result.toDartString();
    _freeString(result);
    calloc.free(vaultPtr);
    return seed;
  }

  /// Derive keypair from vault at index.
  Map<String, dynamic> vaultDeriveKeypair(Uint8List vaultBytes, int index) {
    final vaultPtr = _allocUint8List(vaultBytes);
    final fn = _lib.lookupFunction<_VaultDeriveKPNative, _VaultDeriveKPDart>('fuego_vault_derive_keypair');
    final result = fn(vaultPtr, vaultBytes.length, index);
    final json = result.toDartString();
    _freeString(result);
    calloc.free(vaultPtr);
    return _parseJson(json);
  }

  /// Save vault to file.
  bool vaultSave(Uint8List vaultBytes, String path) {
    final vaultPtr = _allocUint8List(vaultBytes);
    final pathPtr = path.toNativeUtf8();
    final fn = _lib.lookupFunction<_VaultSaveNative, _VaultSaveDart>('fuego_vault_save');
    final result = fn(vaultPtr, vaultBytes.length, pathPtr);
    final ok = result.ok;
    if (result.error != nullptr) _freeString(result.error);
    calloc.free(vaultPtr);
    calloc.free(pathPtr);
    return ok;
  }

  /// Load vault from file.
  Uint8List? vaultLoad(String path) {
    final pathPtr = path.toNativeUtf8();
    final fn = _lib.lookupFunction<_VaultLoadNative, _VaultLoadDart>('fuego_vault_load');
    final result = fn(pathPtr);
    calloc.free(pathPtr);
    if (result.ptr == nullptr) return null;
    return _bytesToList(result);
  }

  /// Generate key derivation.
  String generateKeyDerivation(List<int> key1, List<int> secret2) {
    assert(key1.length == 32 && secret2.length == 32);
    final key1Ptr = _allocBytes(key1);
    final secret2Ptr = _allocBytes(secret2);
    final fn = _lib.lookupFunction<_GenKeyDerivNative, _GenKeyDerivDart>('fuego_generate_key_derivation');
    final result = fn(key1Ptr, secret2Ptr);
    final hex = result.toDartString();
    _freeString(result);
    calloc.free(key1Ptr);
    calloc.free(secret2Ptr);
    return hex;
  }

  /// Derive a one-time public key: P = Hs(D || varint(index)) * G + base.
  /// Returns 64 hex chars, or empty string on invalid base.
  String derivePublicKey(List<int> derivation, int outputIndex, List<int> base) {
    assert(derivation.length == 32 && base.length == 32);
    final derivPtr = _allocBytes(derivation);
    final basePtr = _allocBytes(base);
    final fn = _lib.lookupFunction<_DerivePubKeyNative, _DerivePubKeyDart>('fuego_derive_public_key');
    final result = fn(derivPtr, outputIndex, basePtr);
    final hex = result.toDartString();
    _freeString(result);
    calloc.free(derivPtr);
    calloc.free(basePtr);
    return hex;
  }

  /// Generate key image.
  String generateKeyImage(List<int> pubkey, List<int> secret) {
    assert(pubkey.length == 32 && secret.length == 32);
    final pkPtr = _allocBytes(pubkey);
    final skPtr = _allocBytes(secret);
    final fn = _lib.lookupFunction<_GenKeyImageNative, _GenKeyImageDart>('fuego_generate_key_image');
    final result = fn(pkPtr, skPtr);
    final hex = result.toDartString();
    _freeString(result);
    calloc.free(pkPtr);
    calloc.free(skPtr);
    return hex;
  }

  /// Reverse key derivation: recover spend public key from output key.
  String underivePublicKey(List<int> derivation, int outputIndex, List<int> outputKey) {
    assert(derivation.length == 32 && outputKey.length == 32);
    final derivPtr = _allocBytes(derivation);
    final okPtr = _allocBytes(outputKey);
    final fn = _lib.lookupFunction<_UnderivePubKeyNative, _UnderivePubKeyDart>('fuego_underive_public_key');
    final result = fn(derivPtr, outputIndex, okPtr);
    final hex = result.toDartString();
    _freeString(result);
    calloc.free(derivPtr);
    calloc.free(okPtr);
    return hex;
  }

  /// Sign a message with a 32-byte secret key. Returns 64-byte Ed25519 signature as hex.
  String sign(List<int> secret, List<int> message) {
    assert(secret.length == 32);
    final skPtr = _allocBytes(secret);
    final msgPtr = _allocBytes(message);
    final fn = _lib.lookupFunction<_SignNative, _SignDart>('fuego_sign');
    final result = fn(skPtr, msgPtr, message.length);
    final hex = result.toDartString();
    _freeString(result);
    calloc.free(skPtr);
    calloc.free(msgPtr);
    return hex;
  }

  /// Verify an Ed25519 signature.
  bool verify(List<int> pubkey, List<int> message, List<int> signature) {
    assert(pubkey.length == 32 && signature.length == 64);
    final pkPtr = _allocBytes(pubkey);
    final msgPtr = _allocBytes(message);
    final sigPtr = _allocBytes(signature);
    final fn = _lib.lookupFunction<_VerifyNative, _VerifyDart>('fuego_verify');
    final result = fn(pkPtr, msgPtr, message.length, sigPtr);
    calloc.free(pkPtr);
    calloc.free(msgPtr);
    calloc.free(sigPtr);
    return result;
  }

  /// cn_fast_hash (keccak256). Returns 32-byte hash as hex.
  String cnFastHash(List<int> data) {
    final dataPtr = _allocBytes(data);
    final fn =
        _lib.lookupFunction<_CnFastHashNative, _CnFastHashDart>('fuego_cn_fast_hash');
    final result = fn(dataPtr, data.length);
    final hex = result.toDartString();
    _freeString(result);
    calloc.free(dataPtr);
    return hex;
  }

  /// CryptoNote Schnorr (c, r) signature over a 32-byte prefix hash.
  /// Returns 64-byte signature as hex, or '' on failure.
  String cryptoNoteSign(List<int> prefixHash, List<int> pubkey, List<int> secret) {
    assert(prefixHash.length == 32 && pubkey.length == 32 && secret.length == 32);
    final hPtr = _allocBytes(prefixHash);
    final pkPtr = _allocBytes(pubkey);
    final skPtr = _allocBytes(secret);
    final fn = _lib.lookupFunction<_CryptoNoteSignNative, _CryptoNoteSignDart>(
        'fuego_crypto_note_sign');
    final result = fn(hPtr, pkPtr, skPtr);
    final hex = result.toDartString();
    _freeString(result);
    calloc.free(hPtr);
    calloc.free(pkPtr);
    calloc.free(skPtr);
    return hex;
  }

  /// Verify a CryptoNote Schnorr (c, r) signature over a 32-byte prefix hash.
  bool cryptoNoteCheck(List<int> prefixHash, List<int> pubkey, List<int> signature) {
    assert(prefixHash.length == 32 && pubkey.length == 32 && signature.length == 64);
    final hPtr = _allocBytes(prefixHash);
    final pkPtr = _allocBytes(pubkey);
    final sigPtr = _allocBytes(signature);
    final fn = _lib.lookupFunction<_CryptoNoteCheckNative, _CryptoNoteCheckDart>(
        'fuego_crypto_note_check');
    final result = fn(hPtr, pkPtr, sigPtr);
    calloc.free(hPtr);
    calloc.free(pkPtr);
    calloc.free(sigPtr);
    return result;
  }

  /// Base58-encode data (CryptoNote block-based encoding).
  String base58Encode(List<int> data) {
    final dataPtr = _allocBytes(data);
    final fn = _lib.lookupFunction<_Base58EncodeNative, _Base58EncodeDart>('fuego_base58_encode');
    final result = fn(dataPtr, data.length);
    final hex = result.toDartString();
    _freeString(result);
    calloc.free(dataPtr);
    return hex;
  }

  /// Mine CryptoNight shares: try nonces from startNonce, return first valid nonce.
  /// Returns (found, nonce, hash) - found=true if share found within maxNonces tries.
  (bool found, int nonce, Uint8List hash) mineShare(
      Uint8List blob, Uint8List target, int startNonce, int maxNonces) {
    final blobPtr = _allocBytes(blob);
    final targetPtr = _allocBytes(target);
    final noncePtr = calloc<Uint32>();
    final hashPtr = calloc<Uint8>(32);

    final fn = _lib.lookupFunction<_MineShareNative, _MineShareDart>('fuego_mine_share');
    final result = fn(blobPtr, blob.length, targetPtr, startNonce, maxNonces, noncePtr, hashPtr);

    final found = result == 0;
    final nonce = noncePtr.value;
    final hash = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      hash[i] = hashPtr.elementAt(i).value;
    }

    calloc.free(blobPtr);
    calloc.free(targetPtr);
    calloc.free(noncePtr);
    calloc.free(hashPtr);

    return (found, nonce, hash);
  }

  // ── Helpers ──

  Pointer<Uint8> _allocBytes(List<int> data) {
    final ptr = calloc<Uint8>(data.length);
    for (var i = 0; i < data.length; i++) {
      ptr[i] = data[i];
    }
    return ptr;
  }

  Pointer<Uint8> _allocUint8List(Uint8List data) {
    final ptr = calloc<Uint8>(data.length);
    ptr.asTypedList(data.length).setAll(0, data);
    return ptr;
  }

  Uint8List _bytesToList(FuegoBytes bytes) {
    if (bytes.ptr == nullptr || bytes.len == 0) return Uint8List(0);
    final list = Uint8List.fromList(bytes.ptr.asTypedList(bytes.len));
    _freeBytes(bytes.ptr, bytes.len);
    return list;
  }

  Map<String, dynamic> _parseJson(String json) {
    try {
      final trimmed = json.trim();
      if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) return {};
      final inner = trimmed.substring(1, trimmed.length - 1);
      final map = <String, dynamic>{};
      for (final part in inner.split(',')) {
        final kv = part.split(':');
        if (kv.length == 2) {
          final key = kv[0].trim().replaceAll('"', '');
          final value = kv[1].trim().replaceAll('"', '');
          map[key] = value;
        }
      }
      return map;
    } catch (_) {
      return {};
    }
  }
}

// ── FFI structs ──

final class FuegoBytes extends Struct {
  external Pointer<Uint8> ptr;
  @Size()
  external int len;
}

final class FuegoResult extends Struct {
  @Bool()
  external bool ok;
  external Pointer<Utf8> error;
}

// ── Native/Dart function type pairs ──

typedef _FreeStringNative = Void Function(Pointer<Utf8>);
typedef _FreeStringDart = void Function(Pointer<Utf8>);

typedef _FreeBytesNative = Void Function(Pointer<Uint8>, Int32);
typedef _FreeBytesDart = void Function(Pointer<Uint8>, int);

typedef _VersionNative = Pointer<Utf8> Function();
typedef _VersionDart = Pointer<Utf8> Function();

typedef _KeypairGenNative = Pointer<Utf8> Function();
typedef _KeypairGenDart = Pointer<Utf8> Function();

typedef _KeypairFromSecretNative = Pointer<Utf8> Function(Pointer<Uint8>);
typedef _KeypairFromSecretDart = Pointer<Utf8> Function(Pointer<Uint8>);

typedef _MakeAddressNative = Pointer<Utf8> Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _MakeAddressDart = Pointer<Utf8> Function(Pointer<Uint8>, Pointer<Uint8>);

typedef _VaultGenNative = FuegoBytes Function();
typedef _VaultGenDart = FuegoBytes Function();

typedef _VaultFromSeedNative = FuegoBytes Function(Pointer<Uint8>);
typedef _VaultFromSeedDart = FuegoBytes Function(Pointer<Uint8>);

typedef _VaultGetAddrNative = Pointer<Utf8> Function(Pointer<Uint8>, Int32, Int32);
typedef _VaultGetAddrDart = Pointer<Utf8> Function(Pointer<Uint8>, int, int);

typedef _VaultGetSeedNative = Pointer<Utf8> Function(Pointer<Uint8>, Int32);
typedef _VaultGetSeedDart = Pointer<Utf8> Function(Pointer<Uint8>, int);


typedef _VaultDeriveKPNative = Pointer<Utf8> Function(Pointer<Uint8>, Int32, Int32);
typedef _VaultDeriveKPDart = Pointer<Utf8> Function(Pointer<Uint8>, int, int);

typedef _VaultSaveNative = FuegoResult Function(Pointer<Uint8>, Int32, Pointer<Utf8>);
typedef _VaultSaveDart = FuegoResult Function(Pointer<Uint8>, int, Pointer<Utf8>);

typedef _VaultLoadNative = FuegoBytes Function(Pointer<Utf8>);
typedef _VaultLoadDart = FuegoBytes Function(Pointer<Utf8>);

typedef _GenKeyDerivNative = Pointer<Utf8> Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _GenKeyDerivDart = Pointer<Utf8> Function(Pointer<Uint8>, Pointer<Uint8>);

typedef _DerivePubKeyNative = Pointer<Utf8> Function(Pointer<Uint8>, Int64, Pointer<Uint8>);
typedef _DerivePubKeyDart = Pointer<Utf8> Function(Pointer<Uint8>, int, Pointer<Uint8>);

typedef _GenKeyImageNative = Pointer<Utf8> Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _GenKeyImageDart = Pointer<Utf8> Function(Pointer<Uint8>, Pointer<Uint8>);

typedef _UnderivePubKeyNative = Pointer<Utf8> Function(Pointer<Uint8>, Int64, Pointer<Uint8>);
typedef _UnderivePubKeyDart = Pointer<Utf8> Function(Pointer<Uint8>, int, Pointer<Uint8>);

typedef _SignNative = Pointer<Utf8> Function(Pointer<Uint8>, Pointer<Uint8>, Int32);
typedef _SignDart = Pointer<Utf8> Function(Pointer<Uint8>, Pointer<Uint8>, int);

typedef _VerifyNative = Bool Function(Pointer<Uint8>, Pointer<Uint8>, Int32, Pointer<Uint8>);
typedef _VerifyDart = bool Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>);

typedef _CnFastHashNative = Pointer<Utf8> Function(Pointer<Uint8>, Int32);
typedef _CnFastHashDart = Pointer<Utf8> Function(Pointer<Uint8>, int);

typedef _CryptoNoteSignNative = Pointer<Utf8> Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _CryptoNoteSignDart = Pointer<Utf8> Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);

typedef _CryptoNoteCheckNative = Bool Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _CryptoNoteCheckDart = bool Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);

typedef _Base58EncodeNative = Pointer<Utf8> Function(Pointer<Uint8>, Int32);
typedef _Base58EncodeDart = Pointer<Utf8> Function(Pointer<Uint8>, int);

// CryptoNight mining FFI
typedef _MineShareNative = Int32 Function(
    Pointer<Uint8> blob, Int32 blobLen, Pointer<Uint8> target,
    Int32 startNonce, Int32 maxNonces, Pointer<Uint32> outNonce,
    Pointer<Uint8> outHash);
typedef _MineShareDart = int Function(
    Pointer<Uint8> blob, int blobLen, Pointer<Uint8> target,
    int startNonce, int maxNonces, Pointer<Uint32> outNonce,
    Pointer<Uint8> outHash);
