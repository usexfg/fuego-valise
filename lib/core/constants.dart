/// Inlined from fuego_core — only what the wallet actually uses.

/// Default RPC port for Fuego daemon.
const int defaultRpcPort = 18180;

/// Atomic units per XFG coin (10^7).
const int atomicPerCoin = 10000000;

/// Decimal places for XFG display.
const int decimalPlaces = 7;

/// ΗΞΔŦ peg in USD, CPI-adjusted from Q1 2009.
///
/// fuego-suite carries this as prose, not a constant
/// (`CryptoNoteConfig.h`: "1,000 HEAT pool side (10:1 ratio, 10 XFG = 1 HEAT
/// @ \$1.58 CPI-adj)"). It tracks inflation, so it is a snapshot that will
/// drift — it belongs in a daemon field, and every display built on it is
/// only as current as this number. Tracked in the audit as a follow-up.
const double kHeatPegUsd = 1.58;

/// Average block time in seconds.
const int avgBlockTime = 480;

/// Network minimum fee in atomic units.
///
/// fuego-suite `CryptoNoteConfig.h`:
///   MINIMUM_FEE = MINIMUM_FEE_8KH = 8000  (0.0008 XFG, BMv10+ flat fee)
/// The retired V2 fee was 80000 (0.008 XFG) — screens that hardcode 0.008 are
/// quoting and reserving ten times the real fee.
const int txFee = 8000;

/// Network minimum fee in display units (0.0008 XFG).
const double txFeeXfg = txFee / atomicPerCoin;

/// Format atomic units to XFG string.
String formatXfg(int atomic) {
  return (atomic / atomicPerCoin).toStringAsFixed(decimalPlaces);
}

/// Parse a human decimal string ("1.5", "0.0000001") into atomic units
/// without going through a double.
///
/// `double.parse(x) * 10^d` is wrong twice over: `int.tryParse` rejects any
/// decimal outright (silently yielding 0), and `(x * 1e7).toInt()` truncates
/// roughly 5.5% of 7-decimal amounts down by one atomic unit. This does exact
/// integer math on the digits.
///
/// Returns null for anything that is not a non-negative decimal, or for more
/// fractional digits than [decimals] allows (a caller asking to send precision
/// the chain cannot represent is a bug, not something to round away).
int? parseAtomic(String display, {int decimals = decimalPlaces}) {
  final t = display.trim();
  if (t.isEmpty) return null;
  if (!RegExp(r'^\d*\.?\d*$').hasMatch(t) || t == '.') return null;
  final parts = t.split('.');
  final wholeStr = parts[0].isEmpty ? '0' : parts[0];
  final fracStr = parts.length > 1 ? parts[1] : '';
  if (fracStr.length > decimals) return null;
  final whole = BigInt.tryParse(wholeStr);
  if (whole == null) return null;
  final padded = fracStr.padRight(decimals, '0');
  final frac = padded.isEmpty ? BigInt.zero : BigInt.tryParse(padded);
  if (frac == null) return null;
  final value = whole * BigInt.from(10).pow(decimals) + frac;
  // The daemon carries every amount as a uint64, and a Dart int is 64-bit
  // signed, so anything past this is not representable on either side. It
  // bites first on 18-decimal chains, where the ceiling is ~9.22 tokens.
  if (value > _maxInt64) return null;
  return value.toInt();
}

final BigInt _maxInt64 = BigInt.parse('9223372036854775807');

/// Display-unit double to atomic units. Rounds half-away-from-zero; prefer
/// [parseAtomic] when the value came from text, since this still inherits
/// whatever error the double already carries.
int xfgToAtomic(double amount) => (amount * atomicPerCoin).round();

/// Atomic units to a display string with full precision.
String atomicToDisplay(int atomic, {int decimals = decimalPlaces}) {
  var scale = 1;
  for (var i = 0; i < decimals; i++) {
    scale *= 10;
  }
  final whole = atomic ~/ scale;
  final frac = (atomic % scale).abs().toString().padLeft(decimals, '0');
  return '$whole.$frac';
}
