// Copyright (c) 2025 Fuego Developers
// Copyright (c) 2025 Elderfire Privacy Group

// FFI bindings for native crypto operations
// This will call into a shared library (.so, .dylib, .dll) that implements
// Fuego's crypto primitives directly in the app

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Native crypto library for wallet operations
/// This provides in-process crypto primitives without needing to call fuego's walletd
class NativeCrypto {
  static DynamicLibrary? _library;
  static bool _initialized = false;

  // FFI function signatures
  static late final _GenerateKeys = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<Uint8>,
          Pointer<Uint8>,
          Pointer<Uint8>,
          Pointer<Uint8>,
        ),
        int Function(
          Pointer<Uint8>,
          Pointer<Uint8>,
          Pointer<Uint8>,
          Pointer<Uint8>,
        )
      >('fuego_generate_keys');

  static late final _PrivateToPublic = _lib
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Uint8>),
        int Function(Pointer<Uint8>, Pointer<Uint8>)
      >('fuego_private_to_public');

  static late final _GenerateAddress = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<Uint8>,
          Pointer<Uint8>,
          Pointer<Uint8>,
          Pointer<Int8>,
          Size,
        ),
        int Function(
          Pointer<Uint8>,
          Pointer<Uint8>,
          Pointer<Uint8>,
          Pointer<Int8>,
          int,
        )
      >('fuego_generate_address');

  static late final _ValidateAddress = _lib
      .lookupFunction<
        Int32 Function(Pointer<Uint8>),
        int Function(Pointer<Uint8>)
      >('fuego_validate_address');

  static late final _KeyToMnemonic = _lib
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Int8>, Size),
        int Function(Pointer<Uint8>, Pointer<Int8>, int)
      >('fuego_key_to_mnemonic');

  static late final _MnemonicToKey = _lib
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Uint8>),
        int Function(Pointer<Uint8>, Pointer<Uint8>)
      >('fuego_mnemonic_to_key');

  static late final _ValidateMnemonic = _lib
      .lookupFunction<
        Int32 Function(Pointer<Uint8>),
        int Function(Pointer<Uint8>)
      >('fuego_validate_mnemonic');

  // Add function signatures
  static late final _Hash = _lib
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>),
        int Function(Pointer<Uint8>, int, Pointer<Uint8>)
      >('fuego_hash');

  static late final _Sign = _lib
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Size, Pointer<Uint8>),
        int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>)
      >('fuego_sign');

  static late final _VerifySignature = _lib
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Size, Pointer<Uint8>),
        int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>)
      >('fuego_verify_signature');

  static late final _GenerateKeyImage = _lib
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>),
        int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>)
      >('fuego_generate_key_image');

  static late final DynamicLibrary _lib;

  /// Initialize the native crypto library
  static Future<bool> init() async {
    if (_initialized) return true;

    try {
      // Try to load native library
      String libraryPath;

      if (Platform.isAndroid) {
        libraryPath = 'libfuego_crypto.so';
      } else if (Platform.isIOS || Platform.isMacOS) {
        libraryPath = 'libfuego_crypto.dylib';
      } else if (Platform.isLinux) {
        libraryPath = 'libfuego_crypto.so';
      } else if (Platform.isWindows) {
        libraryPath = 'fuego_crypto.dll';
      } else {
        throw UnsupportedError(
          'Platform not supported: ${Platform.operatingSystem}',
        );
      }

      _library = DynamicLibrary.open(libraryPath);
      _initialized = true;
      return true;
    } catch (e) {
      // if library not available - fallback to RPC
      debugPrint('Native crypto library not available: $e');
      debugPrint('Falling back to RPC-based wallet operations');
      return false;
    }
  }

  /// Check if native crypto is available
  static bool get isAvailable => _initialized && _library != null;

  /// Generate new wallet key pair
  /// Returns: Map with keys or null on failure
  static Map<String, Uint8List>? generateKeys() {
    if (!isAvailable) return null;

    final spendPriv = calloc<Uint8>(32);
    final viewPriv = calloc<Uint8>(32);
    final spendPub = calloc<Uint8>(32);
    final viewPub = calloc<Uint8>(32);

    try {
      final result = _GenerateKeys(spendPriv, viewPriv, spendPub, viewPub);
      if (result != 0) return null;

      return {
        'private_spend_key': Uint8List.fromList(spendPriv.asTypedList(32)),
        'private_view_key': Uint8List.fromList(viewPriv.asTypedList(32)),
        'public_spend_key': Uint8List.fromList(spendPub.asTypedList(32)),
        'public_view_key': Uint8List.fromList(viewPub.asTypedList(32)),
      };
    } finally {
      calloc.free(spendPriv);
      calloc.free(viewPriv);
      calloc.free(spendPub);
      calloc.free(viewPub);
    }
  }

  /// Generate public key from private key
  static Uint8List? generatePublicKey(Uint8List privateKey) {
    if (!isAvailable || privateKey.length != 32) return null;

    final privPtr = calloc<Uint8>(32);
    privPtr.asTypedList(32).setAll(0, privateKey);

    final pubPtr = calloc<Uint8>(32);

    try {
      final result = _PrivateToPublic(privPtr, pubPtr);
      if (result != 0) return null;

      return Uint8List.fromList(pubPtr.asTypedList(32));
    } finally {
      calloc.free(privPtr);
      calloc.free(pubPtr);
    }
  }

  /// Generate wallet address from keys
  static String? generateAddress(
    Uint8List publicSpendKey,
    Uint8List publicViewKey,
    String addressPrefix,
  ) {
    if (!isAvailable ||
        publicSpendKey.length != 32 ||
        publicViewKey.length != 32) {
      return null;
    }

    final spendPtr = calloc<Uint8>(32);
    final viewPtr = calloc<Uint8>(32);
    final prefixCStr = addressPrefix.toNativeUtf8();
    final addrPtr = calloc<Int8>(200);

    spendPtr.asTypedList(32).setAll(0, publicSpendKey);
    viewPtr.asTypedList(32).setAll(0, publicViewKey);

    try {
      final result = _GenerateAddress(
        spendPtr,
        viewPtr,
        addrPtr.cast(),
        prefixCStr.cast(),
        200,
      );
      if (result != 0) return null;

      final address = addrPtr.cast<Utf8>().toDartString();
      return address;
    } finally {
      calloc.free(spendPtr);
      calloc.free(viewPtr);
      calloc.free(addrPtr);
      malloc.free(prefixCStr);
    }
  }

  /// Validate wallet address
  static bool isValidAddress(String address) {
    if (!isAvailable) return false;

    final addrCStr = address.toNativeUtf8();

    try {
      final result = _ValidateAddress(addrCStr.cast());
      return result == 1;
    } finally {
      malloc.free(addrCStr);
    }
  }

  /// Generate seed phrase from private key
  static String? keyToMnemonic(
    Uint8List privateKey, {
    String language = 'english',
  }) {
    if (!isAvailable || privateKey.length != 32) return null;

    final privPtr = calloc<Uint8>(32);
    privPtr.asTypedList(32).setAll(0, privateKey);
    final mnemonicPtr = calloc<Int8>(300);

    try {
      final result = _KeyToMnemonic(privPtr, mnemonicPtr, 300);
      if (result != 0) return null;

      final mnemonic = mnemonicPtr.cast<Utf8>().toDartString();
      return mnemonic;
    } finally {
      calloc.free(privPtr);
      calloc.free(mnemonicPtr);
    }
  }

  /// Derive private key from seed phrase
  static Uint8List? mnemonicToKey(String seedPhrase) {
    if (!isAvailable) return null;

    final mnemonicCStr = seedPhrase.toNativeUtf8();
    final keyPtr = calloc<Uint8>(32);

    try {
      final result = _MnemonicToKey(mnemonicCStr.cast(), keyPtr);
      if (result != 0) return null;

      return Uint8List.fromList(keyPtr.asTypedList(32));
    } finally {
      calloc.free(keyPtr);
      malloc.free(mnemonicCStr);
    }
  }

  /// Validate mnemonic seed phrase
  static bool validateMnemonic(String seedPhrase) {
    if (!isAvailable) return false;

    final mnemonicCStr = seedPhrase.toNativeUtf8();

    try {
      final result = _ValidateMnemonic(mnemonicCStr.cast());
      return result == 1;
    } finally {
      malloc.free(mnemonicCStr);
    }
  }

  /// Generate key image for ring signatures
  static Uint8List? generateKeyImage(
    Uint8List publicKey,
    Uint8List privateKey,
  ) {
    if (!isAvailable) return null;

    // Validate input lengths (must be 32 bytes each)
    if (publicKey.length != 32 || privateKey.length != 32) {
      return null;
    }

    final publicPtr = calloc<Uint8>(32);
    final privatePtr = calloc<Uint8>(32);
    final keyImagePtr = calloc<Uint8>(32);

    publicPtr.asTypedList(32).setAll(0, publicKey);
    privatePtr.asTypedList(32).setAll(0, privateKey);

    try {
      final result = _GenerateKeyImage(publicPtr, privatePtr, keyImagePtr);
      if (result != 0) return null;

      return Uint8List.fromList(keyImagePtr.asTypedList(32));
    } finally {
      calloc.free(publicPtr);
      calloc.free(privatePtr);
      calloc.free(keyImagePtr);
    }
  }

  /// Hash data using SHA512
  static Uint8List? hash(Uint8List data) {
    if (!isAvailable) return null;

    final dataPtr = calloc<Uint8>(data.length);
    final hashPtr = calloc<Uint8>(64); // SHA512 output is 64 bytes

    dataPtr.asTypedList(data.length).setAll(0, data);

    try {
      final result = _Hash(dataPtr, data.length, hashPtr);
      if (result != 0) return null;

      return Uint8List.fromList(hashPtr.asTypedList(64));
    } finally {
      calloc.free(dataPtr);
      calloc.free(hashPtr);
    }
  }

  /// Sign message with private key using Ed25519
  static Uint8List? signMessage(Uint8List privateKey, Uint8List message) {
    if (!isAvailable || privateKey.length != 32) return null;

    final privatePtr = calloc<Uint8>(32);
    final messagePtr = calloc<Uint8>(message.length);
    final signaturePtr = calloc<Uint8>(64); // Ed25519 signature is 64 bytes

    privatePtr.asTypedList(32).setAll(0, privateKey);
    messagePtr.asTypedList(message.length).setAll(0, message);

    try {
      final result = _Sign(
        privatePtr,
        messagePtr,
        message.length,
        signaturePtr,
      );
      if (result != 0) return null;

      return Uint8List.fromList(signaturePtr.asTypedList(64));
    } finally {
      calloc.free(privatePtr);
      calloc.free(messagePtr);
      calloc.free(signaturePtr);
    }
  }

  /// Verify Ed25519 signature
  static bool verifySignature(
    Uint8List publicKey,
    Uint8List message,
    Uint8List signature,
  ) {
    if (!isAvailable || publicKey.length != 32 || signature.length != 64) {
      return false;
    }

    final publicPtr = calloc<Uint8>(32);
    final messagePtr = calloc<Uint8>(message.length);
    final signaturePtr = calloc<Uint8>(64);

    publicPtr.asTypedList(32).setAll(0, publicKey);
    messagePtr.asTypedList(message.length).setAll(0, message);
    signaturePtr.asTypedList(64).setAll(0, signature);

    try {
      final result = _VerifySignature(
        publicPtr,
        messagePtr,
        message.length,
        signaturePtr,
      );
      return result == 1; // 1 = valid, 0 = invalid
    } finally {
      calloc.free(publicPtr);
      calloc.free(messagePtr);
      calloc.free(signaturePtr);
    }
  }
}
