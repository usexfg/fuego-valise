import 'package:flutter/material.dart';
import '../../core/transaction.dart';
import '../../utils/theme.dart';

class TransactionDetailsScreen extends StatelessWidget {
  final FuegoTransaction transaction;

  const TransactionDetailsScreen({super.key, required this.transaction});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transaction Details'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDetailRow('Transaction ID', transaction.txHash),
            _buildDetailRow('Date', transaction.dateTime.toString()),
            _buildDetailRow('Amount', '${transaction.amount.toStringAsFixed(8)} XFG'),
            _buildDetailRow('Fee', '${transaction.fee.toStringAsFixed(8)} XFG'),
            _buildDetailRow('Block Height', transaction.blockHeight.toString()),
            _buildDetailRow('Confirmations', transaction.confirmations.toString()),
            _buildDetailRow('Direction', transaction.isIncoming ? 'Incoming' : 'Outgoing'),
            if (transaction.paymentId != null)
              _buildDetailRow('Payment ID', transaction.paymentId!),
            if (transaction.destinations.isNotEmpty)
              _buildDetailRow('Destinations', transaction.destinations.join(', ')),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(String title, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          SelectableText(value, style: const TextStyle(color: AppTheme.textSecondary, fontFamily: 'IBMPlexMono')),
        ],
      ),
    );
  }
}
