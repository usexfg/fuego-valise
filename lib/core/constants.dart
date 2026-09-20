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

// ── HEAT mint ──

/// CryptoNoteConfig.h HEAT_LAUNCH_RATIO_NUM/DENOM — 10 XFG per 1 ΗΞΔŦ — on
/// the canonical mint price scale (ΗΞΔŦ atomics per XFG atomic x COIN).
///
/// The Hearth pool cannot hold ΗΞΔŦ before any is minted, and minting needs
/// a price, so at launch there is no pool price to mint against. This fixed
/// ratio breaks that deadlock until the pool carries one of its own.
const int heatLaunchRatioXfgPerHeat = 10;
const int heatLaunchMintPrice = atomicPerCoin ~/ heatLaunchRatioXfgPerHeat;

/// ΗΞΔŦ to claim for [burnAtomic] at [mintPrice], on the chain's own terms:
/// `expectedHeat = xfgBurned * price / COIN` (HeatMintEngine::expectedHeatFor).
///
/// Exact, with no headroom. A mint pins the height whose price it used
/// (TX_EXTRA_HEAT_MINT_AUTH carries priceHeight), and consensus validates
/// against the price it recorded at that height rather than the price when
/// the transaction is mined. There is no drift left to absorb, so the wallet
/// quotes the full amount and the claim is checked by exact equality.
///
/// Truncating division rounds down, matching the chain's own floor.
int heatMintableFor(int burnAtomic, int mintPrice) {
  return burnAtomic * mintPrice ~/ atomicPerCoin;
}

/// Format atomic units to XFG string.
String formatXfg(int atomic) {
  return (atomic / atomicPerCoin).toStringAsFixed(decimalPlaces);
}
