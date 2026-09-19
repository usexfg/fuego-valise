import 'constants.dart';

class FuegoTransaction {
  final String txHash;
  final int blockHeight;
  final int timestamp;
  final int confirmations;
  final double amount;
  final double fee;
  final int amountAtomic;
  final int feeAtomic;
  final String direction;
  final String? paymentId;
  final List<String> destinations;

  const FuegoTransaction({
    required this.txHash,
    required this.blockHeight,
    required this.timestamp,
    required this.confirmations,
    required this.amount,
    required this.fee,
    required this.amountAtomic,
    required this.feeAtomic,
    required this.direction,
    this.paymentId,
    this.destinations = const [],
  });

  /// Tolerant numeric read. A hard `as int` threw on any daemon that emits
  /// `1.0e7`, and the only caller wraps this in `catch (_) {}` — so one float
  /// made the entire transaction history disappear with no message.
  static int _intOf(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) {
      return int.tryParse(v) ?? double.tryParse(v)?.toInt() ?? 0;
    }
    return 0;
  }

  factory FuegoTransaction.fromJson(Map<String, dynamic> json) {
    final amountAtom = _intOf(json['amount'] ?? json['total_received']);
    final feeAtom = _intOf(json['fee']);
    return FuegoTransaction(
      txHash: json['transactionHash']?.toString() ?? json['tx_hash']?.toString() ?? json['hash']?.toString() ?? '',
      blockHeight: _intOf(json['blockIndex'] ?? json['block_height']),
      timestamp: _intOf(json['timestamp']),
      confirmations: _intOf(json['confirmations']),
      amount: amountAtom / atomicPerCoin,
      fee: feeAtom / atomicPerCoin,
      amountAtomic: amountAtom,
      feeAtomic: feeAtom,
      direction: json['direction']?.toString() ??
          (amountAtom > 0 ? 'in' : 'out'),
      paymentId: json['paymentId']?.toString() ?? json['payment_id']?.toString(),
      destinations: (json['destinations'] as List<dynamic>?)
              ?.map((d) => d.toString())
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() => {
        'tx_hash': txHash,
        'block_height': blockHeight,
        'timestamp': timestamp,
        'confirmations': confirmations,
        'amount': amountAtomic,
        'fee': feeAtomic,
        'direction': direction,
        if (paymentId != null) 'payment_id': paymentId,
        'destinations': destinations,
      };

  bool get isIncoming => direction == 'in';
  bool get isOutgoing => direction == 'out';
  bool get isPending => direction == 'pending';
  bool get isFailed => direction == 'failed';

  DateTime get dateTime =>
      DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);

  @override
  String toString() =>
      'FuegoTransaction($txHash, $amount XFG, $direction)';
}

class SendTransactionRequest {
  final String address;
  final double amount;
  final double fee;
  final int mixin;
  final String? paymentId;

  const SendTransactionRequest({
    required this.address,
    required this.amount,
    required this.fee,
    this.mixin = 0,
    this.paymentId,
  });

  Map<String, dynamic> toJson() => {
        'destinations': [
          {
            'amount': (amount * atomicPerCoin).round(),
            'address': address,
          }
        ],
        'fee': (fee * atomicPerCoin).round(),
        'mixin': mixin,
        if (paymentId != null && paymentId!.isNotEmpty) 'payment_id': paymentId,
      };
}
