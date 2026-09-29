import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../bloc/cd/cd_cubit.dart';
import '../../../utils/theme.dart';

class CreateCdDialog extends StatefulWidget {
  const CreateCdDialog({super.key});

  @override
  State<CreateCdDialog> createState() => _CreateCdDialogState();
}

class _CreateCdDialogState extends State<CreateCdDialog> {
  static const _termTiers = [6, 18, 36, 72];
  static const _amountTiers = [8.0, 80.0, 800.0, 8000.0];
  static const _chipLabels = ['8', '80', '800', '8,000'];

  int _selectedTerm = 6;
  double _selectedAmount = 8.0;
  String _feeAsset = 'HEAT';

  /// 1 HΞΔŦ = 10^7 atomic units (CRYPTONOTE_DISPLAY_DECIMAL_POINT).
  static const _atomicPerHeat = 10000000;
  bool _submitting = false;
  String? _error;

  static const _epochBlocks = 900;

  String _fmtHeat(double value) {
    if (value < 1) {
      return '${value.toStringAsFixed(1)}𐅪';
    }
    if (value >= 100) return value.toStringAsFixed(0);
    return value.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    final totalBlocks = _selectedTerm * _epochBlocks;
    final blockTimeSec = 480;
    final days = (totalBlocks * blockTimeSec) ~/ 86400;
    final bankingFee = _selectedAmount / 1000;

    return AlertDialog(
      backgroundColor: AppTheme.cardColor,
      title: const Text('Create CD', style: TextStyle(color: AppTheme.textPrimary)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Amount (HΞ∆T)', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(_amountTiers.length, (i) => ChoiceChip(
                label: Text('${_chipLabels[i]} HΞ∆T'),
                selected: _selectedAmount == _amountTiers[i],
                selectedColor: AppTheme.primaryColor,
                labelStyle: TextStyle(
                  color: _selectedAmount == _amountTiers[i] ? Colors.white : AppTheme.textPrimary,
                  fontSize: 13,
                ),
                backgroundColor: AppTheme.surfaceColor,
                onSelected: (_) => setState(() => _selectedAmount = _amountTiers[i]),
              )),
            ),
            const SizedBox(height: 20),
            const Text('Term (epochs)', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _termTiers.map((t) => ChoiceChip(
                label: Text('$t epochs'),
                selected: _selectedTerm == t,
                selectedColor: AppTheme.primaryColor,
                labelStyle: TextStyle(
                  color: _selectedTerm == t ? Colors.white : AppTheme.textPrimary,
                ),
                backgroundColor: AppTheme.surfaceColor,
                onSelected: (_) => setState(() => _selectedTerm = t),
              )).toList(),
            ),
            const SizedBox(height: 8),
            Text('≈ $days days — ${_selectedTerm * _epochBlocks} blocks at 8 min/block',
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
            const SizedBox(height: 12),
            const Text('Banking fee paid in', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: ['HEAT', 'XFG'].map((a) => ChoiceChip(
                label: Text(a == 'HEAT' ? 'HΞ∆T' : 'XFG'),
                selected: _feeAsset == a,
                selectedColor: AppTheme.primaryColor,
                labelStyle: TextStyle(
                  color: _feeAsset == a ? Colors.white : AppTheme.textPrimary,
                ),
                backgroundColor: AppTheme.surfaceColor,
                onSelected: (_) => setState(() => _feeAsset = a),
              )).toList(),
            ),
            const SizedBox(height: 12),
            _buildDetailRow('Deposit', _fmtHeat(_selectedAmount) + (_selectedAmount < 1 ? '' : ' HΞ∆T')),
            _buildDetailRow('Banking fee (0.1%)', _feeAsset == 'HEAT'
                ? _fmtHeat(bankingFee) + (bankingFee < 1 ? '' : ' HΞ∆T')
                : 'XFG equivalent at pool TWAP'),
            _buildDetailRow('Network fee', '0.0008 XFG'),
            _buildDetailRow('Interest', 'variable, paid in HΞ∆T from the epoch fee pool'),
            const SizedBox(height: 8),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!, style: const TextStyle(color: AppTheme.errorColor, fontSize: 12)),
              ),
            Text(_feeAsset == 'HEAT'
                ? 'Banking fee goes to the treasury HΞ∆T reserve.'
                : 'Banking fee is burned to the SWF ledger.',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 10, fontStyle: FontStyle.italic)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary)),
        ),
        ElevatedButton(
          onPressed: _submitting ? null : _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryColor,
            foregroundColor: Colors.white,
          ),
          child: _submitting
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Create'),
        ),
      ],
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
          Text(value, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    setState(() { _submitting = true; _error = null; });
    try {
      await context.read<CdCubit>().createCd(
            coin: 'HEAT',
            amount: (_selectedAmount * _atomicPerHeat).round().toString(),
            durationBlocks: _selectedTerm * _epochBlocks,
            feeAsset: _feeAsset,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() { _submitting = false; _error = e.toString(); });
    }
  }
}