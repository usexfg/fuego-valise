import 'dart:typed_data';

import '../ffi/fuego_native.dart';
import 'security_service.dart';

/// Single source of truth for the CryptoNote keypair that signs swap offers.
///
/// The same keypair is needed by two callers that previously disagreed:
///
///  * `DexCubit` signs `/submitswap` and `/cancelswap` with the maker identity.
///  * `xfg-swapd` signs managed offers with `xfg_secret_key` from its swap
///    config, and rejects any offer whose `makerPubKey` is not its own
///    (`SwapDaemon.cpp:4710`).
///
/// Both now read and write the same secure-storage entry
/// (`dex_maker_swap_secret`), so they cannot drift. Generating here is
/// idempotent: the first caller creates the key, everyone else adopts it.
class SwapIdentityService {
  SwapIdentityService._();

  /// Opened lazily — constructing this throws when libfuego_ffi is absent,
  /// which must not break a config save.
  static FuegoNative? _native;

  static FuegoNative? _tryNative() {
    return _native ??= (() {
      try {
        return FuegoNative();
      } catch (_) {
        return null;
      }
    })();
  }

  static List<int> _hexToBytes(String hex) {
    final out = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  /// Adopt the existing maker identity, or mint one on first use.
  /// Returns the 64-char hex spend key, or null if the key is unavailable.
  static Future<String?> ensureMakerSecret() async {
    final stored = await SecurityService.readMakerSwapSecret();
    if (stored != null && stored.length == 64) return stored;

    final native = _tryNative();
    if (native == null) return null;

    try {
      final keys = native.keypairGenerate();
      final secret = keys['secret'];
      if (secret is! String || secret.length != 64) return null;
      await SecurityService.writeMakerSwapSecret(secret);
      return secret;
    } catch (_) {
      return null;
    }
  }

  /// Public spend key for [secret], or '' if it cannot be derived.
  static String publicKeyFor(String secret) {
    if (secret.length != 64) return '';
    final native = _tryNative();
    if (native == null) return '';
    try {
      final kp =
          native.keypairFromSecret(Uint8List.fromList(_hexToBytes(secret)));
      final pub = kp['public'];
      return pub is String ? pub : '';
    } catch (_) {
      return '';
    }
  }
}