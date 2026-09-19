import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../bloc/cd/cd_cubit.dart';
import '../../../core/constants.dart';
import '../../../utils/theme.dart';

class _Rung {
  int amountAtomic;
  int termEpochs;
  _Rung({required this.amountAtomic, required this.termEpochs});
}

/// Build several CDs at staggered terms in one call.
///
/// Submits the whole rung array to `cd::create_ladder` rather than looping
/// client-side. Rungs still broadcast one at a time and cannot be rolled
/// back, but the server reports which ones already went out when a later one
/// fails, instead of discarding their hashes.
class LadderBuilderDialog extends StatefulWidget {
  const LadderBuilderDialog({super.key});

  @override
  State<LadderBuilderDialog> createState() => _LadderBuilderDialogState();
}

class _LadderBuilderDialogState extends State<LadderBuilderDialog> {
  List<_Rung>? _rungs;
  bool _submitting = false;
  String? _error;

  List<_Rung> _initialRungs(List<int> tiers, int defaultAmount) => tiers
      .map((t) => _Rung(amountAtomic: defaultAmount, termEpochs: t))
      .toList();

  @override
  Widget build(BuildContext context) {
    final config = context.read<CdCubit>().state.config;
    // Default each rung to the second amount tier when there is one, so the
    // ladder is not four minimum-size CDs.
    final defaultAmount = config.amountTiers.length > 1
        ? config.amountTiers[1]
        : config.depositMinAmount;
    final rungs = _rungs ??= _initialRungs(config.termTiers, defaultAmount);
    final total = rungs.fold<int>(0, (s, r) => s + r.amountAtomic);

    return AlertDialog(
      backgroundColor: AppTheme.cardColor,
      title: const Text('Build CD ladder',
          style: TextStyle(color: AppTheme.textPrimary)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Stagger maturities so part of the position frees up regularly. '
              'Each rung is a separate CD and each pays the creation fee.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
            const SizedBox(height: 12),
            ...List.generate(rungs.length, (idx) {
              final rung = rungs[idx];
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('Rung ${idx + 1}',
                            style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close,
                              size: 16, color: AppTheme.textMuted),
                          onPressed: rungs.length > 1
                              ? () => setState(() => rungs.removeAt(idx))
                              : null,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children:
                          List.generate(config.amountTiers.length, (i) {
                        final tier = config.amountTiers[i];
                        final label = i < config.amountTiersDisplay.length
                            ? config.amountTiersDisplay[i]
                            : _formatHeat(tier);
                        return ChoiceChip(
                          label:
                              Text(label, style: const TextStyle(fontSize: 11)),
                          selected: rung.amountAtomic == tier,
                          selectedColor: AppTheme.primaryColor,
                          labelStyle: TextStyle(
                              color: rung.amountAtomic == tier
                                  ? Colors.white
                                  : AppTheme.textPrimary),
                          backgroundColor: AppTheme.backgroundColor,
                          onSelected: (_) =>
                              setState(() => rung.amountAtomic = tier),
                        );
                      }),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      children: config.termTiers
                          .map((t) => ChoiceChip(
                                label: Text('$t',
                                    style: const TextStyle(fontSize: 11)),
                                selected: rung.termEpochs == t,
                                selectedColor: AppTheme.primaryColor,
                                labelStyle: TextStyle(
                                    color: rung.termEpochs == t
                                        ? Colors.white
                                        : AppTheme.textPrimary),
                                backgroundColor: AppTheme.backgroundColor,
                                onSelected: (_) =>
                                    setState(() => rung.termEpochs = t),
                              ))
                          .toList(),
                    ),
                  ],
                ),
              );
            }),
            TextButton.icon(
              onPressed: () => setState(() => rungs.add(_Rung(
                  amountAtomic: defaultAmount,
                  termEpochs: config.termTiers.first))),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add rung', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(height: 8),
            Text(
              'Total: ${_formatHeat(total)} ΗΞΔŦ across ${rungs.length} '
              '${rungs.length == 1 ? "rung" : "rungs"}',
              style:
                  const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: const TextStyle(
                      color: AppTheme.errorColor, fontSize: 11)),
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
          onPressed: _submitting ? null : () => _create(rungs),
          style:
              ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor),
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text('Create ${rungs.length} CDs'),
        ),
      ],
    );
  }

  Future<void> _create(List<_Rung> rungs) async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    final cubit = context.read<CdCubit>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final hashes = await cubit.createLadder([
        for (final r in rungs)
          {'amount': r.amountAtomic, 'term_epochs': r.termEpochs},
      ]);
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(content: Text('Created ${hashes.length} CDs')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.toString();
      });
    }
  }
}

String _formatHeat(int atomic) {
  final whole = atomic ~/ atomicPerCoin;
  final frac = atomic % atomicPerCoin;
  if (frac == 0) return whole.toString();
  final fracStr = frac
      .toString()
      .padLeft(decimalPlaces, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '$whole.$fracStr';
}
