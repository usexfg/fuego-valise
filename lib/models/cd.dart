class CdInfo {
  final String cdId;
  final String owner;
  final String coin;
  final String amount;
  final String interestRate;
  final int maturityHeight;
  final int depositHeight;
  final String accruedInterest;
  final String totalValue;
  final int blocksToMaturity;
  final bool matured;
  final bool forSale;

  const CdInfo({
    required this.cdId,
    required this.owner,
    required this.coin,
    required this.amount,
    required this.interestRate,
    required this.maturityHeight,
    required this.depositHeight,
    required this.accruedInterest,
    required this.totalValue,
    required this.blocksToMaturity,
    required this.matured,
    this.forSale = false,
  });

  factory CdInfo.fromJson(Map<String, dynamic> json) => CdInfo(
        cdId: json['cd_id'] as String? ?? '',
        owner: json['owner'] as String? ?? '',
        coin: json['coin'] as String? ?? '',
        amount: json['amount'] as String? ?? '0',
        interestRate: json['interest_rate'] as String? ?? '0',
        maturityHeight: (json['maturity_height'] as num?)?.toInt() ?? 0,
        depositHeight: (json['deposit_height'] as num?)?.toInt() ?? 0,
        accruedInterest: json['accrued_interest'] as String? ?? '0',
        totalValue: json['total_value'] as String? ?? '0',
        blocksToMaturity: (json['blocks_to_maturity'] as num?)?.toInt() ?? 0,
        matured: json['matured'] as bool? ?? false,
        forSale: json['for_sale'] as bool? ?? false,
      );
}

class CdListResult {
  final List<CdInfo> cds;
  const CdListResult({required this.cds});

  factory CdListResult.fromJson(Map<String, dynamic> json) => CdListResult(
        cds: (json['cds'] as List<dynamic>?)
                ?.map((e) => CdInfo.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

class CdCreateResult {
  final String cdId;
  final String txHash;
  final String coin;
  final String amount;
  final String maturityAt;

  const CdCreateResult({
    required this.cdId,
    required this.txHash,
    required this.coin,
    required this.amount,
    required this.maturityAt,
  });

  factory CdCreateResult.fromJson(Map<String, dynamic> json) => CdCreateResult(
        cdId: json['cd_id'] as String,
        txHash: json['tx_hash'] as String,
        coin: json['coin'] as String,
        amount: json['amount'] as String,
        maturityAt: json['maturity_at'] as String,
      );
}

class CdClaimResult {
  final String cdId;
  final String txHash;
  final String coin;
  final String principal;
  final String interest;
  final String total;

  const CdClaimResult({
    required this.cdId,
    required this.txHash,
    required this.coin,
    required this.principal,
    required this.interest,
    required this.total,
  });

  factory CdClaimResult.fromJson(Map<String, dynamic> json) => CdClaimResult(
        cdId: json['cd_id'] as String,
        txHash: json['tx_hash'] as String,
        coin: json['coin'] as String,
        principal: json['principal'] as String,
        interest: json['interest'] as String,
        total: json['total'] as String,
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
        cdId: json['cd_id'] as String? ?? '',
        txHash: json['tx_hash'] as String? ?? json['txHash'] as String? ?? '',
        coin: json['coin'] as String? ?? 'HEAT',
        status: json['status'] as String? ?? '',
      );
}

class CdMarketListing {
  final String listingId;
  final String cdId;
  final String seller;
  final String coin;
  final String amount;
  final String price;
  final String interestRate;
  final int blocksRemaining;

  const CdMarketListing({
    required this.listingId,
    required this.cdId,
    required this.seller,
    required this.coin,
    required this.amount,
    required this.price,
    required this.interestRate,
    required this.blocksRemaining,
  });

  factory CdMarketListing.fromJson(Map<String, dynamic> json) =>
      CdMarketListing(
        listingId: json['listing_id'] as String,
        cdId: json['cd_id'] as String,
        seller: json['seller'] as String,
        coin: json['coin'] as String,
        amount: json['amount'] as String,
        price: json['price'] as String,
        interestRate: json['interest_rate'] as String,
        blocksRemaining: (json['blocks_remaining'] as num).toInt(),
      );
}

class CdMarketListResult {
  final List<CdMarketListing> listings;
  const CdMarketListResult({required this.listings});

  factory CdMarketListResult.fromJson(Map<String, dynamic> json) =>
      CdMarketListResult(
        listings: (json['listings'] as List<dynamic>?)
                ?.map((e) => CdMarketListing.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

class CdSellResult {
  final String listingId;
  final String cdId;
  final String txHash;

  const CdSellResult({
    required this.listingId,
    required this.cdId,
    required this.txHash,
  });

  factory CdSellResult.fromJson(Map<String, dynamic> json) => CdSellResult(
        listingId: json['listing_id'] as String,
        cdId: json['cd_id'] as String,
        txHash: json['tx_hash'] as String,
      );
}

class CdBuyResult {
  final String listingId;
  final String cdId;
  final String txHash;
  final String coin;
  final String amount;
  final String pricePaid;

  const CdBuyResult({
    required this.listingId,
    required this.cdId,
    required this.txHash,
    required this.coin,
    required this.amount,
    required this.pricePaid,
  });

  factory CdBuyResult.fromJson(Map<String, dynamic> json) => CdBuyResult(
        listingId: json['listing_id'] as String,
        cdId: json['cd_id'] as String,
        txHash: json['tx_hash'] as String,
        coin: json['coin'] as String,
        amount: json['amount'] as String,
        pricePaid: json['price_paid'] as String,
      );
}

class CdApyResult {
  final String coin;
  final double currentApy;
  final double averageApy;
  final int? epoch;

  const CdApyResult({
    required this.coin,
    required this.currentApy,
    required this.averageApy,
    this.epoch,
  });

  factory CdApyResult.fromJson(Map<String, dynamic> json) => CdApyResult(
        coin: json['coin'] as String? ?? 'XFG',
        currentApy: (json['current_apy'] as num?)?.toDouble() ?? 0.0,
        averageApy: (json['average_apy'] as num?)?.toDouble() ?? 0.0,
        epoch: json['epoch'] as int?,
      );
}
