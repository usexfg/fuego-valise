import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../services/fuego_rpc_service.dart';
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

  static const xfgAtomic = 10000000;

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.cardColor,
      title: const Text(
        'Mint ΗΞΔŦ',
        style: TextStyle(color: AppTheme.textPrimary),
      ),
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
                onPressed: _submitting
                    ? null
                    : () => Navigator.of(context).pop(),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
              ),
              ElevatedButton(
                onPressed: _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
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
          Text(
            'Burn XFG to mint ΗΞΔŦ at the PI redemption price.',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
          ),
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
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              suffixText: 'XFG',
            ),
            style: const TextStyle(color: AppTheme.textPrimary),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,7}')),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'ΗΞΔŦ received depends on PI redemption price',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: const TextStyle(
                  color: AppTheme.errorColor,
                  fontSize: 12,
                ),
              ),
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
        const Text(
          'ΗΞΔŦ Minted!',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        if (_heatReceived != null)
          Text(
            '$_heatReceived ΗΞΔŦ received',
            style: TextStyle(
              color: AppTheme.successColor,
              fontSize: 18,
              fontFamily: AppTheme.numberFontFamily,
            ),
          ),
        const SizedBox(height: 4),
        Text(
          'TX: ${_txHash!.substring(0, _txHash!.length > 16 ? 16 : _txHash!.length)}...',
          style: const TextStyle(
            color: AppTheme.textMuted,
            fontSize: 11,
            fontFamily: 'IBMPlexMono',
          ),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final text = _amountController.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Enter an amount');
      return;
    }
    final xfg = double.tryParse(text);
    if (xfg == null || xfg <= 0) {
      setState(() => _error = 'Invalid amount');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final rpc = context.read<FuegoRPCService>();
      final xfgAtomicAmt = (xfg * xfgAtomic).round();
      // heat_minted = xfg_burned (1:1 at launch, server validates ratio)
      final result = await rpc.heatMint(
        xfgBurned: xfgAtomicAmt,
        heatMinted: xfgAtomicAmt,
        fee: 0,
        mixin: 4,
      );
      setState(() {
        _txHash = result['tx_hash'] as String?;
        _heatReceived = (xfgAtomicAmt / xfgAtomic).toStringAsFixed(7);
        _submitting = false;
      });
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = e.toString();
      });
    }
  }
}
