import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../bloc/wallet/wallet_cubit.dart';
import '../../../core/constants.dart';
import '../../../utils/theme.dart';
import '../../../utils/xfg_ticker.dart';

class MintHeatDialog extends StatefulWidget {
  const MintHeatDialog({super.key});

  @override
  State<MintHeatDialog> createState() => _MintHeatDialogState();
}

class _MintHeatDialogState extends State<MintHeatDialog> {
  final _amountController = TextEditingController();
  bool _submitting = false;
  String? _error;
  String? _txHash;
  String? _heatReceived;

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.cardColor,
      title: const Text('Mint ΗΞΔŦ', style: TextStyle(color: AppTheme.textPrimary)),
      content: _txHash != null ? _buildSuccess() : _buildForm(),
      actions: _txHash != null
          ? [
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Done'),
              ),
            ]
          : [
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
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Burn XFG → Mint ΗΞΔŦ'),
              ),
            ],
    );
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Burn XFG to mint ΗΞΔŦ at the live Hearth pool rate.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
          const SizedBox(height: 12),
          TextField(
            controller: _amountController,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'XFG Amount',
              hintText: '100.0',
              filled: true,
              fillColor: AppTheme.surfaceColor,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              suffixText: 'XFG',
            ),
            style: const TextStyle(color: AppTheme.textPrimary),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,7}')),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
              'The daemon sizes the ΗΞΔŦ side from the pool when it builds the '
              'transaction. This action cannot be undone.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: AppTheme.errorColor, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _buildSuccess() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle, color: AppTheme.successColor, size: 48),
        const SizedBox(height: 12),
        const Text('ΗΞΔŦ Minted!', style: TextStyle(
            color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (_heatReceived != null)
          Text('$_heatReceived ΗΞΔŦ minted',
              style: TextStyle(
                  color: AppTheme.successColor,
                  fontSize: 18,
                  fontFamily: AppTheme.numberFontFamily)),
        const SizedBox(height: 4),
        Text('TX: ${_txHash!.substring(0, _txHash!.length > 16 ? 16 : _txHash!.length)}...',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontFamily: 'IBMPlexMono')),
      ],
    );
  }

  /// Same PIN gate as [MintHeatScreen]. This dialog previously called the RPC
  /// service directly, so one of the two mint entry points burned XFG with no
  /// authorization at all.
  Future<String?> _promptPin() async {
    final controller = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        title: const Text('Enter PIN to mint',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: TextField(
          controller: controller,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 12,
          decoration:
              const InputDecoration(labelText: 'PIN', counterText: ''),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Authorize'),
          ),
        ],
      ),
    );
    controller.dispose();
    return pin;
  }

  Future<void> _submit() async {
    final text = _amountController.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Enter an amount');
      return;
    }
    final burnAtomic = parseAtomic(text);
    if (burnAtomic == null || burnAtomic <= 0) {
      setState(() => _error = 'Enter an amount with at most 7 decimals');
      return;
    }
    final pin = await _promptPin();
    if (pin == null || pin.isEmpty) return;
    if (!mounted) return;
    setState(() { _submitting = true; _error = null; });
    try {
      // Only the burn amount is sent; walletd derives the ΗΞΔŦ side from the
      // pool, matching what consensus will accept.
      final result = await context
          .read<WalletCubit>()
          .mintHeat(xfgDisplay: text, pin: pin);
      if (!mounted) return;
      final minted = result['heat_minted'] ?? result['heatMinted'];
      setState(() {
        _txHash = (result['transactionHash'] ??
            result['txHash'] ??
            result['tx_hash']) as String?;
        _heatReceived =
            minted is num ? atomicToDisplay(minted.toInt()) : null;
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _submitting = false; _error = e.toString(); });
    }
  }
}
