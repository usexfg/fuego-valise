import 'dart:convert';

/// What the native parser found in an address string: a standard address
/// (fire / TEST) or a funsa sub-address (funsa / Tsub), and its network.
class ParsedFuegoAddress {
  final bool isSubaddress;
  final bool testnet;

  const ParsedFuegoAddress({required this.isSubaddress, required this.testnet});

  /// Decodes `fuego_parse_address` output. Anything but a well-formed valid
  /// result is null, so a malformed reply never passes as an address.
  static ParsedFuegoAddress? fromNativeJson(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic> || decoded['valid'] != true) {
      return null;
    }
    final isSubaddress = decoded['is_subaddress'];
    final testnet = decoded['testnet'];
    if (isSubaddress is! bool || testnet is! bool) return null;
    return ParsedFuegoAddress(isSubaddress: isSubaddress, testnet: testnet);
  }
}

/// Why [parsed] cannot receive a payment from a wallet on the given network,
/// or null when it can.
String? recipientAddressProblemFor(
  ParsedFuegoAddress? parsed, {
  required bool walletOnTestnet,
}) {
  if (parsed == null) {
    return 'Invalid address (expected a fire… address or a funsa… sub-address)';
  }
  if (parsed.testnet != walletOnTestnet) {
    return walletOnTestnet
        ? 'This is a mainnet address; the wallet is on testnet'
        : 'This is a testnet address; the wallet is on mainnet';
  }
  return null;
}
