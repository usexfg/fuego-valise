import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../bloc/cd/cd_cubit.dart';
import '../../../core/constants.dart';
import '../../../utils/theme.dart';

/// Create a fixed-term HEAT CD.
///
/// No yield figure is quoted. Interest is a share of realized swap-fee
/// revenue per epoch (`getEpochFeeRate`), so there is no rate to promise
/// before the fact — the previous dialog showed a hardcoded APY beside a flat
/// 2% interest line, and neither corresponded to anything on-chain.
///
/// 8 ΗΞΔŦ is DEPOSIT_MIN_AMOUNT at the 6-epoch minimum term, not a separate
/// product: consensus rejects any term below DEPOSIT_MIN_TERM.
class CreateCdDialog extends StatefulWidget {
  const CreateCdDialog({super.key});

  @override
  State<CreateCdDialog> createState() => _CreateCdDialogState();
}

class _CreateCdDialogState extends State<CreateCdDialog> {
  int? _selectedTerm;
  int? _selectedAmountAtomic;
  bool _submitting = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final config = context.read<CdCubit>().state.config;
    final term = _selectedTerm ?? config.termTiers.first;
    final amountAtomic = _selectedAmountAtomic ?? config.depositMinAmount;

    final totalBlocks = term * config.epochBlocks;
    final days = totalBlocks ~/ config.blocksPerDay;
    final creationFee = amountAtomic * config.creationFeeBps ~/ 10000;

    return AlertDialog(
      backgroundColor: AppTheme.cardColor,
      title: const Text('Create CD',
          style: TextStyle(color: AppTheme.textPrimary)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Amount',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(config.amountTiers.length, (i) {
                final tier = config.amountTiers[i];
                final label = i < config.amountTiersDisplay.length
                    ? config.amountTiersDisplay[i]
                    : _formatHeat(tier);
                return ChoiceChip(
                  label: Text('$label ΗΞΔŦ'),
                  selected: amountAtomic == tier,
                  selectedColor: AppTheme.primaryColor,
                  labelStyle: TextStyle(
                    color: amountAtomic == tier
                        ? Colors.white
                        : AppTheme.textPrimary,
                    fontSize: 13,
                  ),
                  backgroundColor: AppTheme.surfaceColor,
                  onSelected: (_) =>
                      setState(() => _selectedAmountAtomic = tier),
                );
              }),
            ),
            const SizedBox(height: 20),
            const Text('Term',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: config.termTiers
                  .map((t) => ChoiceChip(
                        label: Text('$t epochs'),
                        selected: term == t,
                        selectedColor: AppTheme.primaryColor,
                        labelStyle: TextStyle(
                          color:
                              term == t ? Colors.white : AppTheme.textPrimary,
                        ),
                        backgroundColor: AppTheme.surfaceColor,
                        onSelected: (_) => setState(() => _selectedTerm = t),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 10),
            Text(
              '$totalBlocks blocks — about $days days '
              '(${config.epochBlocks} blocks per epoch, '
              '${config.blocksPerDay} blocks per day)',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
            const SizedBox(height: 12),
            _detailRow('Deposit', '${_formatHeat(amountAtomic)} ΗΞΔŦ'),
            _detailRow(
              'Creation fee (${(config.creationFeeBps / 100).toStringAsFixed(2)}%)',
              '${_formatHeat(creationFee)} ΗΞΔŦ',
            ),
            const SizedBox(height: 10),
            const Text(
              'Interest is a share of realized swap-fee revenue, credited per '
              'epoch and compounding until maturity. There is no fixed rate, '
              'and accrual stops at maturity — roll the CD over or claim it to '
              'keep earning.',
              style: TextStyle(
                  color: AppTheme.textMuted, fontSize: 11, height: 1.4),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: const TextStyle(
                      color: AppTheme.errorColor, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel',
              style: TextStyle(color: AppTheme.textSecondary)),
        ),
        ElevatedButton(
          onPressed: _submitting ? null : () => _submit(term, amountAtomic),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryColor,
            foregroundColor: Colors.white,
          ),
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('Create'),
        ),
      ],
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style:
                  const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
          Text(value,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Future<void> _submit(int term, int amountAtomic) async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    final cubit = context.read<CdCubit>();
    final navigator = Navigator.of(context);
    try {
      await cubit.createCd(
        coin: 'HEAT',
        amount: _formatHeat(amountAtomic),
        durationBlocks: term * cubit.state.config.epochBlocks,
      );
      navigator.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.toString();
      });
    }
  }
}

/// Atomic HEAT to a decimal string, trailing zeros trimmed.
String _formatHeat(int atomic) {
  final whole = atomic ~/ atomicPerCoin;
  final frac = atomic % atomicPerCoin;
  if (frac == 0) return whole.toString();
  final fracStr =
      frac.toString().padLeft(decimalPlaces, '0').replaceFirst(RegExp(r'0+$'), '');
  return '$whole.$fracStr';
}
