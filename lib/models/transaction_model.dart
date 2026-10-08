class TransactionModel {
  final String id;
  final String fromAddress;
  final String? toAddress;
  final String amount;
  final String fee;
  final String timestamp;
  final String status;
  final String type;
  final String? txHash;
  final String? memo;

  TransactionModel({
    required this.id,
    required this.fromAddress,
    this.toAddress,
    required this.amount,
    required this.fee,
    required this.timestamp,
    required this.status,
    required this.type,
    this.txHash,
    this.memo,
  });

  factory TransactionModel.fromJson(Map<String, dynamic> json) {
    return TransactionModel(
      id: json['id'] ?? '',
      fromAddress: json['from_address'] ?? '',
      toAddress: json['to_address'],
      amount: json['amount'] ?? '0',
      fee: json['fee'] ?? '0',
      timestamp: json['timestamp'] ?? '',
      status: json['status'] ?? 'pending',
      type: json['type'] ?? 'transfer',
      txHash: json['tx_hash'],
      memo: json['memo'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'from_address': fromAddress,
      'to_address': toAddress,
      'amount': amount,
      'fee': fee,
      'timestamp': timestamp,
      'status': status,
      'type': type,
      'tx_hash': txHash,
      'memo': memo,
    };
  }

  /// Check if this is a burn transaction
  bool get isBurnTransaction {
    return type == 'burn' || toAddress == null || toAddress!.isEmpty;
  }

  /// Get formatted amount for display
  String get formattedAmount {
    final amountDouble = double.tryParse(amount) ?? 0.0;
    return '${amountDouble.toStringAsFixed(7)} XFG';
  }

  /// Get formatted fee for display
  String get formattedFee {
    final feeDouble = double.tryParse(fee) ?? 0.0;
    return '${feeDouble.toStringAsFixed(3)} XFG';
  }

  /// Get formatted timestamp for display
  String get formattedTimestamp {
    try {
      final dateTime = DateTime.fromMillisecondsSinceEpoch(
        int.parse(timestamp),
      );
      return '${dateTime.day}/${dateTime.month}/${dateTime.year} ${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return timestamp;
    }
  }

  @override
  String toString() {
    return 'TransactionModel(id: $id, from: $fromAddress, to: $toAddress, amount: $amount, type: $type)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TransactionModel && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
