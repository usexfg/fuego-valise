import '../core/constants.dart' as k;

/// A HEAT certificate of deposit, as reported by walletd `list_cds`.
///
/// Amounts are HEAT decimal strings, not atomic units. Yield is realized
/// swap-fee revenue distributed per epoch, so there is no rate to quote —
/// only interest accrued so far, and how much of it the yield pool can
/// currently back.
class CdInfo {
  final String cdId;
  final String owner;
  final String coin;
  final String amount;

  /// Interest accrued so far as a percent of principal. NOT an APY: nothing
  /// annualizes it, and accrual stops at maturity.
  final String accruedPct;

  final int termBlocks;
  final int termEpochs;
  final int maturityHeight;
  final int depositHeight;

  /// Interest a claim can actually take — the pool- and vault-capped figure
  /// consensus accepts.
  final String accruedInterest;

  /// What the interest formula alone would give. Exceeds [accruedInterest]
  /// when the yield pool cannot back the full amount.
  final String uncappedInterest;
  final bool interestIsCapped;

  final String feePoolBalance;
  final String cdApyVaultBalance;
  final int effectiveEpochs;
  final String totalValue;
  final int blocksToMaturity;
  final bool matured;

  const CdInfo({
    required this.cdId,
    required this.owner,
    required this.coin,
    required this.amount,
    required this.accruedPct,
    required this.termBlocks,
    required this.termEpochs,
    required this.maturityHeight,
    required this.depositHeight,
    required this.accruedInterest,
    required this.uncappedInterest,
    required this.interestIsCapped,
    required this.feePoolBalance,
    required this.cdApyVaultBalance,
    required this.effectiveEpochs,
    required this.totalValue,
    required this.blocksToMaturity,
    required this.matured,
  });

  factory CdInfo.fromJson(Map<String, dynamic> json) {
    String str(String key, [String fallback = '0']) =>
        json[key]?.toString() ?? fallback;
    int num_(String key) => (json[key] as num?)?.toInt() ?? 0;
    return CdInfo(
      cdId: str('cd_id', ''),
      owner: str('owner', ''),
      coin: str('coin', 'HEAT'),
      amount: str('amount'),
      accruedPct: str('accrued_pct'),
      termBlocks: num_('term_blocks'),
      termEpochs: num_('term_epochs'),
      maturityHeight: num_('maturity_height'),
      depositHeight: num_('deposit_height'),
      accruedInterest: str('accrued_interest'),
      uncappedInterest: str('uncapped_interest'),
      interestIsCapped: json['interest_is_capped'] as bool? ?? false,
      feePoolBalance: str('fee_pool_balance'),
      cdApyVaultBalance: str('cd_apy_vault_balance'),
      effectiveEpochs: num_('effective_epochs'),
      totalValue: str('total_value'),
      blocksToMaturity: num_('blocks_to_maturity'),
      matured: json['matured'] as bool? ?? false,
    );
  }

  /// Whole days until maturity at 180 blocks/day.
  int get daysToMaturity => blocksToMaturity ~/ k.blocksPerDay;

  /// Fraction of the term elapsed, clamped to 0..1.
  double get progress {
    if (termBlocks <= 0) return 0;
    return (1.0 - blocksToMaturity / termBlocks).clamp(0.0, 1.0);
  }
}

class CdListResult {
  final List<CdInfo> cds;
  const CdListResult({required this.cds});

  factory CdListResult.fromJson(Map<String, dynamic> json) => CdListResult(
        cds: (json['cds'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map(CdInfo.fromJson)
                .toList() ??
            const [],
      );
}

class CdCreateResult {
  final String cdId;
  final String txHash;
  final String coin;
  final String amount;
  final int termBlocks;
  final String maturityAt;

  const CdCreateResult({
    required this.cdId,
    required this.txHash,
    required this.coin,
    required this.amount,
    required this.termBlocks,
    required this.maturityAt,
  });

  factory CdCreateResult.fromJson(Map<String, dynamic> json) => CdCreateResult(
        cdId: json['cd_id']?.toString() ?? '',
        txHash: json['tx_hash']?.toString() ??
            json['txHash']?.toString() ??
            json['transactionHash']?.toString() ??
            '',
        coin: json['coin']?.toString() ?? 'HEAT',
        amount: json['amount']?.toString() ?? '0',
        termBlocks: (json['term_blocks'] as num?)?.toInt() ?? 0,
        maturityAt: json['maturity_at']?.toString() ?? '',
      );
}

class CdClaimResult {
  final String cdId;
  final String txHash;
  final String coin;
  final String principal;
  final String interest;
  final String total;
  final String fee;

  /// How many CDs the claim actually spent. Claiming without a cd_id spends
  /// every mature CD, so this can exceed one.
  final int cdsClaimed;

  const CdClaimResult({
    required this.cdId,
    required this.txHash,
    required this.coin,
    required this.principal,
    required this.interest,
    required this.total,
    required this.fee,
    required this.cdsClaimed,
  });

  factory CdClaimResult.fromJson(Map<String, dynamic> json) => CdClaimResult(
        cdId: json['cd_id']?.toString() ?? '',
        txHash: json['tx_hash']?.toString() ??
            json['txHash']?.toString() ??
            json['transactionHash']?.toString() ??
            '',
        coin: json['coin']?.toString() ?? 'HEAT',
        principal: json['principal']?.toString() ?? '0',
        interest: json['interest']?.toString() ?? '0',
        total: json['total']?.toString() ?? '0',
        fee: json['fee']?.toString() ?? '0',
        cdsClaimed: (json['cds_claimed'] as num?)?.toInt() ?? 1,
      );
}

class CdRolloverResult {
  final String cdId;
  final String txHash;
  final String coin;
  final String status;

  const CdRolloverResult({
    required this.cdId,
    required this.txHash,
    required this.coin,
    required this.status,
  });

  factory CdRolloverResult.fromJson(Map<String, dynamic> json) =>
      CdRolloverResult(
        cdId: json['cd_id']?.toString() ?? '',
        txHash: json['tx_hash']?.toString() ??
            json['txHash']?.toString() ??
            json['transactionHash']?.toString() ??
            '',
        coin: json['coin']?.toString() ?? 'HEAT',
        status: json['status']?.toString() ?? '',
      );
}

/// CD yield pool state from `cd::apy`.
///
/// Deliberately carries no APY. Yield is realized swap-fee revenue
/// distributed per epoch (`SWAP_FEE_CD_SHARE_PCT`), topped up in lean epochs
/// to `CD_YIELD_FLOOR_RATE`. Claims are capped by these balances at claim
/// time, so the backing is the honest figure to show.
class CdYieldPool {
  final String coin;
  final String feePoolBalance;
  final String cdApyVaultBalance;

  /// False when the daemon predates pool-aware estimates, in which case the
  /// balances are unknown rather than zero.
  final bool poolInfoPresent;
  final String note;

  const CdYieldPool({
    required this.coin,
    required this.feePoolBalance,
    required this.cdApyVaultBalance,
    required this.poolInfoPresent,
    required this.note,
  });

  factory CdYieldPool.fromJson(Map<String, dynamic> json) => CdYieldPool(
        coin: json['coin']?.toString() ?? 'HEAT',
        feePoolBalance: json['fee_pool_balance']?.toString() ?? '0',
        cdApyVaultBalance: json['cd_apy_vault_balance']?.toString() ?? '0',
        poolInfoPresent: json['pool_info_present'] as bool? ?? false,
        note: json['note']?.toString() ?? '',
      );
}

/// CD product configuration from `cd::config` — the single source of truth
/// for tiers, so the UI does not hardcode them.
class CdConfig {
  final int epochBlocks;
  final int blocksPerDay;
  final List<int> termTiers;
  final List<int> amountTiers;
  final List<String> amountTiersDisplay;
  final int depositMinAmount;
  final int depositMinTerm;
  final int depositMaxTerm;
  final int creationFeeBps;
  final String yieldSource;

  const CdConfig({
    required this.epochBlocks,
    required this.blocksPerDay,
    required this.termTiers,
    required this.amountTiers,
    required this.amountTiersDisplay,
    required this.depositMinAmount,
    required this.depositMinTerm,
    required this.depositMaxTerm,
    required this.creationFeeBps,
    required this.yieldSource,
  });

  /// Falls back to the compiled-in constants, which mirror
  /// CryptoNoteConfig.h, when the daemon does not serve a config.
  static const CdConfig fallback = CdConfig(
    epochBlocks: k.epochBlocks,
    blocksPerDay: k.blocksPerDay,
    termTiers: k.cdTermTiers,
    amountTiers: [
      k.depositMinAmount,
      1000 * k.atomicPerCoin,
      10000 * k.atomicPerCoin,
      100000 * k.atomicPerCoin,
      1000000 * k.atomicPerCoin,
    ],
    amountTiersDisplay: ['8', '1,000', '10,000', '100,000', '1M'],
    depositMinAmount: k.depositMinAmount,
    depositMinTerm: k.depositMinTerm,
    depositMaxTerm: k.depositMaxTerm,
    creationFeeBps: k.cdCreationFeeBps,
    yieldSource: '',
  );

  factory CdConfig.fromJson(Map<String, dynamic> json) {
    List<int> ints(String key, List<int> fallbackValue) {
      final raw = json[key] as List<dynamic>?;
      if (raw == null || raw.isEmpty) return fallbackValue;
      return raw.map((e) => (e as num).toInt()).toList();
    }

    return CdConfig(
      epochBlocks: (json['epoch_blocks'] as num?)?.toInt() ?? k.epochBlocks,
      blocksPerDay: (json['blocks_per_day'] as num?)?.toInt() ?? k.blocksPerDay,
      termTiers: ints('term_tiers', k.cdTermTiers),
      amountTiers: ints('amount_tiers', fallback.amountTiers),
      amountTiersDisplay:
          (json['amount_tiers_display'] as List<dynamic>?)
                  ?.map((e) => e.toString())
                  .toList() ??
              fallback.amountTiersDisplay,
      depositMinAmount:
          (json['deposit_min_amount'] as num?)?.toInt() ?? k.depositMinAmount,
      depositMinTerm:
          (json['deposit_min_term'] as num?)?.toInt() ?? k.depositMinTerm,
      depositMaxTerm:
          (json['deposit_max_term'] as num?)?.toInt() ?? k.depositMaxTerm,
      creationFeeBps:
          (json['creation_fee_bps'] as num?)?.toInt() ?? k.cdCreationFeeBps,
      yieldSource: json['yield_source']?.toString() ?? '',
    );
  }
}
