/// Inlined from fuego_core — only what the wallet actually uses.

/// Default RPC port for Fuego daemon.
const int defaultRpcPort = 18180;

/// Atomic units per XFG coin (10^7).
const int atomicPerCoin = 10000000;

/// Decimal places for XFG display.
const int decimalPlaces = 7;

/// Average block time in seconds (CryptoNoteConfig.h DIFFICULTY_TARGET).
const int avgBlockTime = 480;

/// Blocks per day (CryptoNoteConfig.h EXPECTED_NUMBER_OF_BLOCKS_PER_DAY
/// = 24 * 60 * 60 / DIFFICULTY_TARGET). 86400 / 480 = 180.
const int blocksPerDay = 86400 ~/ avgBlockTime;

/// Default transaction fee in atomic units (transaction_builder.rs
/// MINIMUM_FEE). 0.0008 XFG.
const int txFee = 8000;

/// Default ring size. The wallet advertises 8-32 mixins; 4 was the C++ API
/// default and is below what the product promises.
const int defaultMixin = 8;

// ── HEAT certificates of deposit (CryptoNoteConfig.h) ──

/// EPOCH_DURATION_BLOCKS — 900 blocks, 5 days at 480s.
const int epochBlocks = 900;

/// CD_ALLOWED_TIERS, in epochs. 6 epochs is the minimum term (~1 month).
const List<int> cdTermTiers = [6, 18, 36, 72];

/// DEPOSIT_MIN_TERM / DEPOSIT_MAX_TERM, in blocks.
const int depositMinTerm = 6 * epochBlocks;
const int depositMaxTerm = 72 * epochBlocks;

/// DEPOSIT_MIN_AMOUNT — 8 HEAT, in atomic units.
const int depositMinAmount = 8 * atomicPerCoin;

/// CD creation banking fee, in basis points (heat_cd_core: amount / 1000).
const int cdCreationFeeBps = 10;

/// Format atomic units to XFG string.
String formatXfg(int atomic) {
  return (atomic / atomicPerCoin).toStringAsFixed(decimalPlaces);
}
