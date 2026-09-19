import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../bloc/hearth/hearth_cubit.dart';
import '../../../utils/hearth_theme.dart';

class AddLiquidityDialog extends StatefulWidget {
  const AddLiquidityDialog({super.key});

  @override
  State<AddLiquidityDialog> createState() => _AddLiquidityDialogState();
}

class _AddLiquidityDialogState extends State<AddLiquidityDialog> {
  final _xfgController = TextEditingController();
  final _heatController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _xfgController.dispose();
    _heatController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: HearthTheme.bgCard,
      title: Text(
        'Add Liquidity',
        style: HearthTheme.mono(
          size: 16,
          weight: FontWeight.w700,
          color: HearthTheme.textWhite,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dialogInput(_xfgController, 'XFG Amount'),
            const SizedBox(height: 12),
            _dialogInput(_heatController, 'HΞ∆T Amount'),
            const SizedBox(height: 8),
            Text(
              'Provide equal-value amounts of both tokens',
              style: HearthTheme.label(size: 10, color: HearthTheme.textMuted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(
            'Cancel',
            style: HearthTheme.mono(size: 12, color: HearthTheme.textSecondary),
          ),
        ),
        ElevatedButton(
          onPressed: _submitting ? null : _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: HearthTheme.bidPrimary,
            foregroundColor: HearthTheme.textWhite,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: HearthTheme.textWhite,
                  ),
                )
              : const Text('Add'),
        ),
      ],
    );
  }

  Widget _dialogInput(TextEditingController controller, String label) {
    return Container(
      decoration: BoxDecoration(
        color: HearthTheme.bgInput,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: HearthTheme.border, width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        style: HearthTheme.mono(
          size: 14,
          weight: FontWeight.w600,
          color: HearthTheme.textWhite,
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: label,
          hintStyle: HearthTheme.mono(size: 13, color: HearthTheme.textDim),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final xfg = _xfgController.text.trim();
    final heat = _heatController.text.trim();
    if (xfg.isEmpty || heat.isEmpty) return;
    setState(() => _submitting = true);
    // No bare try/finally here: a failure used to close the spinner and show
    // nothing, so a rejected deposit looked identical to a successful one.
    final r = await context.read<HearthCubit>().addLiquidity(
      xfgDisplay: xfg,
      heatDisplay: heat,
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    _reportHearth(context, r, 'Liquidity added');
    if (r.ok) Navigator.of(context).pop();
  }
}

/// Shared result reporter — every Hearth write says what happened.
void _reportHearth(BuildContext context, HearthResult r, String successLabel) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        r.ok
            ? (r.txHash == null || r.txHash!.isEmpty
                  ? successLabel
                  : '$successLabel — ${r.txHash}')
            : (r.error ?? 'Failed'),
      ),
      backgroundColor: r.ok ? HearthTheme.bidPrimary : HearthTheme.askPrimary,
    ),
  );
}

class RemoveLiquidityDialog extends StatefulWidget {
  const RemoveLiquidityDialog({super.key});

  @override
  State<RemoveLiquidityDialog> createState() => _RemoveLiquidityDialogState();
}

class _RemoveLiquidityDialogState extends State<RemoveLiquidityDialog> {
  final _sharesController = TextEditingController();
  final _minXfgController = TextEditingController();
  final _minHeatController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _sharesController.dispose();
    _minXfgController.dispose();
    _minHeatController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: HearthTheme.bgCard,
      title: Text(
        'Withdraw Earnings',
        style: HearthTheme.mono(
          size: 16,
          weight: FontWeight.w700,
          color: HearthTheme.textWhite,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Enter the number of LP shares to burn. Your proportional share of pool reserves will be returned.',
              style: HearthTheme.mono(
                size: 11,
                color: HearthTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            _dialogInput(_sharesController, 'LP Shares to Burn'),
            const SizedBox(height: 12),
            _dialogInput(_minXfgController, 'Min XFG (required)'),
            const SizedBox(height: 12),
            _dialogInput(_minHeatController, 'Min HΞΔŦ (required)'),
            const SizedBox(height: 8),
            Text(
              'Both minimums are required. Leaving them blank sends a floor of '
              'zero, which lets the withdrawal be sandwiched.',
              style: HearthTheme.label(size: 10, color: HearthTheme.textMuted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(
            'Cancel',
            style: HearthTheme.mono(size: 12, color: HearthTheme.textSecondary),
          ),
        ),
        ElevatedButton(
          onPressed: _submitting ? null : _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: HearthTheme.askPrimary,
            foregroundColor: HearthTheme.textWhite,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: HearthTheme.textWhite,
                  ),
                )
              : const Text('Withdraw'),
        ),
      ],
    );
  }

  Widget _dialogInput(TextEditingController controller, String label) {
    return Container(
      decoration: BoxDecoration(
        color: HearthTheme.bgInput,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: HearthTheme.border, width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        style: HearthTheme.mono(
          size: 14,
          weight: FontWeight.w600,
          color: HearthTheme.textWhite,
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: label,
          hintStyle: HearthTheme.mono(size: 13, color: HearthTheme.textDim),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final shares = _sharesController.text.trim();
    final minXfg = _minXfgController.text.trim();
    final minHeat = _minHeatController.text.trim();
    if (shares.isEmpty) return;
    setState(() => _submitting = true);
    final r = await context.read<HearthCubit>().removeLiquidity(
      sharesDisplay: shares,
      minXfgDisplay: minXfg,
      minHeatDisplay: minHeat,
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    _reportHearth(context, r, 'Liquidity withdrawn');
    if (r.ok) Navigator.of(context).pop();
  }
}
