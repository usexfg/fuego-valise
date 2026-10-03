/// Inlined from fuego_core — only what the wallet actually uses.

/// Default RPC port for Fuego daemon.
const int defaultRpcPort = 18180;

/// Atomic units per XFG coin (10^7).
const int atomicPerCoin = 10000000;

/// Decimal places for XFG display.
const int decimalPlaces = 7;

/// Average block time in seconds.
const int avgBlockTime = 480;

/// Default transaction fee in atomic units.
const int txFee = 8000;

/// Network fee of a ΗΞΔŦ transaction (send, CD, claim, rollover), in XFG
/// atomic units. fuego-suite conserves ΗΞΔŦ exactly in these transactions,
/// so walletd pays MINIMUM_FEE in XFG. ΗΞΔŦ-paid fees wait for the v12
/// shielded pool: a fee asset would reveal the transaction type.
const int heatTxFeeXfgAtomic = 8000;

/// Format atomic units to XFG string.
String formatXfg(int atomic) {
  return (atomic / atomicPerCoin).toStringAsFixed(decimalPlaces);
}
