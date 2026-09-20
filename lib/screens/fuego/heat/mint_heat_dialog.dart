import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../core/constants.dart';
import '../../../services/fuego_daemon_client.dart';
import '../../../services/fuego_rpc_service.dart';
import '../../../utils/theme.dart';
import '../../../utils/xfg_ticker.dart';

/// Unreferenced. [MintHeatScreen] is the maintained mint path — it requires
/// a PIN and reports pool state. This dialog is kept only because it is still
/// imported by the equally unreferenced heat_screen.dart; do not wire it up
/// without adding PIN authorisation first.
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
          Text('Burn XFG to mint ΗΞΔŦ at the current mint price.',
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
          const Text('ΗΞΔŦ received depends on the current mint price',
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
          Text('$_heatReceived ΗΞΔŦ received',
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
    setState(() { _submitting = true; _error = null; });
    try {
      final rpc = context.read<FuegoRPCService>();
      final daemon = context.read<FuegoDaemonClient>();
      // Consensus validates heatMinted <= xfgBurned * mintPrice / COIN
      // (HeatMintEngine::expectedHeatFor). A hardcoded 1:1 is rejected above
      // parity and silently shortchanges the minter below it.
      final pool = await daemon.getPoolInfo();
      final price = pool.mintPrice;
      if (price == null) {
        throw StateError('No pool price available');
      }
      final xfgAtomicAmt = (xfg * xfgAtomic).round();
      final heatAtomic = heatMintableFor(xfgAtomicAmt, price);
      if (heatAtomic <= 0) {
        throw StateError('Amount too small to mint any ΗΞΔŦ at this price');
      }
      final result = await rpc.heatMint(
        xfgBurned: xfgAtomicAmt,
        heatMinted: heatAtomic,
      );
      setState(() {
        _txHash = result['tx_hash'] as String?;
        _heatReceived = (heatAtomic / xfgAtomic).toStringAsFixed(7);
        _submitting = false;
      });
    } catch (e) {
      setState(() { _submitting = false; _error = e.toString(); });
    }
  }
}
