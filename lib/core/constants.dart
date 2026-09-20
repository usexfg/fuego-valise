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

/// How far below the current mint price to quote, in basis points.
///
/// Consensus rejects a mint claiming MORE ΗΞΔŦ than the price at the block
/// that includes it allows (HeatMintEngine: `heatOutputs > expectedHeat`),
/// and that check is exact. Quoting at exactly the current price therefore
/// fails on any downward drift at all — even a tenth of a percent — between
/// building the transaction and it being mined. Roughly half of all mints,
/// since prices move both ways.
///
/// Quoting slightly under buys headroom for that drift. The cost is
/// symmetric and explicit: the minter gives up this much ΗΞΔŦ, and in
/// exchange a price fall of up to this much no longer voids the mint.
///
/// 100 bps covers about an 8% single-block swing in the pool, because the
/// 8-block TWAP absorbs only about an eighth of a spot move per block.
///
/// Must stay well below HEAT_MINT_SHORTFALL_TOLERANCE_BPS (500), or the
/// headroom itself trips the consensus shortfall floor.
const int heatMintQuoteHeadroomBps = 100;

/// ΗΞΔŦ to claim for [burnAtomic] at [mintPrice], on the chain's own terms:
/// `expectedHeat = xfgBurned * price / COIN` (HeatMintEngine::expectedHeatFor),
/// less [heatMintQuoteHeadroomBps] of drift headroom.
///
/// Truncating division rounds down, which is required — consensus rejects a
/// claim one atomic unit over the cap.
int heatMintableFor(int burnAtomic, int mintPrice) {
  final expected = burnAtomic * mintPrice ~/ atomicPerCoin;
  return expected * (10000 - heatMintQuoteHeadroomBps) ~/ 10000;
}

/// Format atomic units to XFG string.
String formatXfg(int atomic) {
  return (atomic / atomicPerCoin).toStringAsFixed(decimalPlaces);
}
