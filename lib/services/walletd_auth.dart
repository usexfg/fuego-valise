import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'security_service.dart';

/// Bearer token holder for the walletd HTTP API.
///
/// walletd requires `Authorization: Bearer <token>` on every state-changing
/// call. Without it any local process can drive the wallet while it is open,
/// and on Android any app holding the INTERNET permission can reach the
/// loopback port.
///
/// The token is the same value [SecurityService.getOrCreateWalletdAuthToken]
/// hands to the spawned walletd via a 0600 file, so it never appears in argv.
/// Desktop caveat: the token lives in the user's own data directory, so it is
/// not a boundary against other processes running as that same user. It is a
/// real boundary on Android, where app-private storage is unreadable by other
/// apps.
class WalletdAuth {
  WalletdAuth._();

  static String? _token;

  /// The token, or null before [load] has run.
  static String? get token => _token;

  static bool get hasToken => (_token ?? '').isNotEmpty;

  /// Read the token written by the spawn path. Failure is not fatal: a walletd
  /// started without `--auth-token-file` accepts unauthenticated calls.
  static Future<void> load() async {
    try {
      _token = await SecurityService().getOrCreateWalletdAuthToken();
    } catch (_) {
      _token = null;
    }
  }

  /// Headers to merge into a request. Empty when no token is available.
  static Map<String, String> headers() {
    final t = _token;
    if (t == null || t.isEmpty) return const {};
    return {'Authorization': 'Bearer $t'};
  }

  /// Headers for a request that is known to target the local walletd.
  static Map<String, String> headersForWallet() => headers();

  /// Headers for a request whose target host is [host].
  ///
  /// The bearer token authorises the local wallet API. It must never leave the
  /// machine: in remote mode `host` is a third-party seed node, and posting
  /// this header there hands that node the key to `open_wallet`, spending and
  /// `close_wallet` on the local walletd — strictly worse than having no token
  /// at all. Only loopback gets the header.
  static Map<String, String> headersForHost(String host) {
    final h = host.trim().toLowerCase();
    final loopback =
        h == '127.0.0.1' || h == 'localhost' || h == '::1' || h == '0.0.0.0';
    return loopback ? headers() : const {};
  }

  /// Dio interceptor applying the token to loopback requests only.
  ///
  /// Host-aware rather than unconditional: the same client is also used to
  /// reach the chain daemon, which in remote mode is a third-party seed node.
  /// Attaching there would leak the wallet API key off the machine.
  static Interceptor interceptor() => InterceptorsWrapper(
        onRequest: (options, handler) {
          final host = options.uri.host;
          if (host.isNotEmpty) options.headers.addAll(headersForHost(host));
          handler.next(options);
        },
      );

  /// A Dio instance that presents the token on every request. Use this instead
  /// of `Dio(...)` in a constructor initializer list, where a cascade is not
  /// allowed mid-list.
  static Dio dio(BaseOptions options) =>
      Dio(options)..interceptors.add(interceptor());

  /// Path of the token file, for the spawn path to write.
  static Future<String> tokenFilePath() async {
    final dir = await getApplicationSupportDirectory();
    final walletDir = p.join(dir.path, 'wallet');
    await Directory(walletDir).create(recursive: true);
    return p.join(walletDir, '.walletd_auth_token');
  }
}
