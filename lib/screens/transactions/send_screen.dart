import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:dns_client/dns_client.dart' hide DnsClient;
import 'package:dns_client/src/dns_over_https.dart';
import '../../bloc/wallet/wallet_cubit.dart';
import '../../core/constants.dart';
import '../../utils/theme.dart';
import '../../utils/xfg_ticker.dart';

class SendScreen extends StatefulWidget {
  const SendScreen({super.key});

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  final _formKey = GlobalKey<FormState>();
  final _addressController = TextEditingController();
  final _amountController = TextEditingController();
  final _addressFocusNode = FocusNode();
  final _amountFocusNode = FocusNode();

  bool _isLoading = false;
  String? _errorMessage;
  bool _isHeat = false; // false = XFG, true = ΗΞΔŦ

  bool _isResolvingAlias = false;
  String? _resolvedAddress;

  @override
  void initState() {
    super.initState();
    _addressFocusNode.addListener(_onAddressFocusChange);
  }

  @override
  void dispose() {
    _addressController.dispose();
    _amountController.dispose();
    _addressFocusNode.removeListener(_onAddressFocusChange);
    _addressFocusNode.dispose();
    _amountFocusNode.dispose();
    super.dispose();
  }

  void _onAddressFocusChange() {
    if (!_addressFocusNode.hasFocus) {
      _resolveOpenAlias();
    }
  }

  Future<void> _resolveOpenAlias() async {
    final address = _addressController.text.trim();
    if (!address.contains('@')) return;

    setState(() {
      _isResolvingAlias = true;
      _errorMessage = null;
      _resolvedAddress = null;
    });

    try {
      final parts = address.split('@');
      if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) {
        throw Exception('Invalid OpenAlias format. Use: user@domain.com');
      }
      final domain = parts[1];

      final client = DnsOverHttps.cloudflare();
      final records = await client.lookupDataByRRType(domain, RRType.TXT);

      String? fuegoAddress;
      for (final record in records) {
        final oaPos = record.indexOf('oa1:xfg');
        if (oaPos == -1) continue;

        final addrStart = record.indexOf('recipient_address=', oaPos);
        if (addrStart == -1) continue;

        final valueStart = addrStart + 'recipient_address='.length;
        final addrEnd = record.indexOf(';', valueStart);

        if (addrEnd == -1 || (addrEnd - valueStart) != 98) continue;

        fuegoAddress = record.substring(valueStart, addrEnd);
        break;
      }

      if (fuegoAddress != null) {
        if (!mounted) return;
        setState(() {
          _resolvedAddress = fuegoAddress;
          _addressController.text = fuegoAddress!;
        });
      } else {
        throw Exception('No valid Fuego address found for this OpenAlias');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to resolve OpenAlias';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isResolvingAlias = false;
        });
      }
    }
  }

  Future<void> _showConfirmDialog() async {
    // Resolve before validating. Resolution used to fire on focus-loss, which
    // races the tap: the dialog could show `alice@example.com` while the send
    // used whatever DNS returned a moment later.
    if (_addressController.text.trim().contains('@')) {
      await _resolveOpenAlias();
      if (!mounted) return;
      if (_resolvedAddress == null) {
        setState(
          () => _errorMessage =
              _errorMessage ??
              'Could not resolve that alias — check it and retry.',
        );
        return;
      }
    }
    if (!_formKey.currentState!.validate()) return;

    final wallet = context.read<WalletCubit>().state;
    final address = _addressController.text.trim();
    if (address.contains('@')) {
      setState(() => _errorMessage = 'Alias is unresolved — cannot send.');
      return;
    }
    final amountStr = _amountController.text.trim();
    final amount = double.tryParse(amountStr) ?? 0;
    final coin = _isHeat ? 'ΗΞΔŦ' : 'XFG';
    final fee = txFeeXfg;
    final total = amount + fee;

    if (_isHeat) {
      if (total > wallet.unlockedHeatXfg) {
        setState(() {
          _errorMessage =
              'Insufficient $coin balance (need ${total.toStringAsFixed(7)} $coin including fee)';
        });
        return;
      }
    } else {
      final totalAtomic = xfgToAtomic(total);
      if (totalAtomic > wallet.unlockedBalance) {
        setState(() {
          _errorMessage =
              'Insufficient unlocked balance (need ${total.toStringAsFixed(7)} $coin including fee)';
        });
        return;
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        title: Text(
          'Confirm Send $coin',
          style: const TextStyle(color: AppTheme.textPrimary),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Recipient',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
              ),
              const SizedBox(height: 4),
              // Full address — a truncated middle hides exactly the bytes an
              // address-swap attack changes.
              SelectableText(
                address,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                  fontFamily: 'IBMPlexMono',
                ),
              ),
              if (_resolvedAddress != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Resolved from an OpenAlias TXT record. DNSSEC is not '
                  'validated — confirm the address out of band for large sends.',
                  style: TextStyle(
                    color: AppTheme.warningColor,
                    fontSize: 10,
                    height: 1.3,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              const SizedBox(height: 8),
              _confirmRow('Amount', '${amount.toStringAsFixed(7)} $coin'),
              const SizedBox(height: 8),
              _confirmRow('Fee', '${fee.toStringAsFixed(7)} $coin'),
              const Divider(color: AppTheme.textMuted),
              _confirmRow(
                'Total',
                '${total.toStringAsFixed(7)} $coin',
                bold: true,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppTheme.textMuted),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _promptPinAndSend();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
            ),
            child: const Text('Confirm & Send'),
          ),
        ],
      ),
    );
  }

  Future<void> _promptPinAndSend() async {
    final pinController = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppTheme.cardColor,
          title: const Text(
            'Enter PIN to send',
            style: TextStyle(color: AppTheme.textPrimary),
          ),
          content: TextField(
            controller: pinController,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: const InputDecoration(
              labelText: 'PIN',
              counterText: '',
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(pinController.text),
              child: const Text('Authorize'),
            ),
          ],
        );
      },
    );
    pinController.dispose();
    if (pin == null || pin.isEmpty) return;
    await _sendTransaction(pin);
  }

  Widget _confirmRow(String label, String value, {bool bold = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: AppTheme.textMuted, fontSize: 13)),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: bold ? AppTheme.textPrimary : AppTheme.textSecondary,
              fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
              fontSize: 15,
              fontFamily: AppTheme.numberFontFamily,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _sendTransaction(String pin) async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final cubit = context.read<WalletCubit>();
      final amount = double.tryParse(_amountController.text.trim()) ?? 0;
      final address = _addressController.text.trim();
      String txHash;

      if (_isHeat) {
        txHash = await cubit.sendHeat(
          address: address,
          amount: amount,
          fee: txFeeXfg,
          pin: pin,
        );
      } else {
        txHash = await cubit.sendTransaction(
          address: address,
          amount: amount,
          fee: txFeeXfg,
          pin: pin,
          mixin: 7,
        );
      }

      if (txHash.isNotEmpty && mounted) {
        _showSuccessDialog(txHash);
      } else if (mounted) {
        setState(() {
          _errorMessage = cubit.state.error ?? 'Transaction failed';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showSuccessDialog(String txHash) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: AppTheme.cardColor,
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: AppTheme.successColor),
              SizedBox(width: 8),
              Text(
                'Transaction Sent',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Your transaction has been broadcast to the network.',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Transaction ID:',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppTheme.textMuted.withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          txHash,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 12,
                            fontFamily: 'IBMPlexMono',
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: txHash));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Transaction ID copied'),
                              backgroundColor: AppTheme.successColor,
                            ),
                          );
                        },
                        icon: const Icon(
                          Icons.copy,
                          size: 16,
                          color: AppTheme.primaryColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).pop();
              },
              child: const Text('Done'),
            ),
          ],
        );
      },
    );
  }

  void _pasteFromClipboard() async {
    final clipboardData = await Clipboard.getData('text/plain');
    if (clipboardData?.text != null) {
      _addressController.text = clipboardData!.text!;
    }
  }

  void _setMaxAmount() {
    final state = context.read<WalletCubit>().state;
    final availableBalance = _isHeat
        ? state.unlockedHeatXfg
        : state.unlockedBalanceXfg;
    final maxAmount = (availableBalance - txFeeXfg).clamp(
      0.0,
      availableBalance,
    );
    _amountController.text = maxAmount.toStringAsFixed(7);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isHeat ? 'Send ΗΞΔŦ' : 'Send XFG'),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: BlocBuilder<WalletCubit, WalletState>(
        builder: (context, state) {
          final availableBalance = _isHeat
              ? state.unlockedHeatXfg
              : state.unlockedBalanceXfg;
          final coin = _isHeat ? 'ΗΞΔŦ' : 'XFG';

          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Coin selector toggle
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _isHeat = false),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: !_isHeat
                                    ? AppTheme.primaryColor
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                'XFG',
                                style: TextStyle(
                                  color: !_isHeat
                                      ? Colors.white
                                      : AppTheme.textSecondary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _isHeat = true),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: _isHeat
                                    ? AppTheme.primaryColor
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                'ΗΞΔŦ',
                                style: TextStyle(
                                  color: _isHeat
                                      ? Colors.white
                                      : AppTheme.textSecondary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Available balance
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppTheme.cardColor,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppTheme.primaryColor.withOpacity(0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Available Balance',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '${availableBalance.toStringAsFixed(7)} $coin',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary,
                                fontFamily: AppTheme.numberFontFamily,
                              ),
                            ),
                            TextButton(
                              onPressed: _setMaxAmount,
                              child: const Text('MAX'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Recipient address or alias
                  const Text(
                    'Recipient Address or Alias',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _addressController,
                    focusNode: _addressFocusNode,
                    onChanged: (_) {
                      if (_resolvedAddress != null) {
                        setState(() => _resolvedAddress = null);
                      }
                    },
                    decoration: InputDecoration(
                      hintText: 'fire... or user@domain.com',
                      suffixIcon: _isResolvingAlias
                          ? const Padding(
                              padding: EdgeInsets.all(12.0),
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: _pasteFromClipboard,
                                  icon: const Icon(Icons.paste),
                                  tooltip: 'Paste',
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 40,
                                    minHeight: 40,
                                    maxWidth: 40,
                                    maxHeight: 40,
                                  ),
                                ),
                                IconButton(
                                  onPressed: () {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('QR scanner coming soon'),
                                      ),
                                    );
                                  },
                                  icon: const Icon(Icons.qr_code_scanner),
                                  tooltip: 'Scan QR',
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 40,
                                    minHeight: 40,
                                    maxWidth: 40,
                                    maxHeight: 40,
                                  ),
                                ),
                              ],
                            ),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Please enter recipient address';
                      }
                      final v = value.trim();
                      if (v.contains('@')) {
                        // Accepted only as input; resolution happens before
                        // the confirm dialog and rewrites this field.
                        return _resolvedAddress == null
                            ? 'Alias not resolved yet — leave the field to resolve it'
                            : null;
                      }
                      if (!v.startsWith('fire') || v.length != 98) {
                        return 'Invalid address (must be fire... and 98 chars)';
                      }
                      return null;
                    },
                    maxLines: 3,
                    minLines: 1,
                  ),
                  if (_resolvedAddress != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Text(
                        'Resolved to: $_resolvedAddress',
                        style: const TextStyle(color: AppTheme.successColor),
                      ),
                    ),
                  const SizedBox(height: 24),

                  // Amount
                  const Text(
                    'Amount',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _amountController,
                    focusNode: _amountFocusNode,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      hintText: '0.0000000',
                      suffixText: coin,
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Please enter amount';
                      }
                      final amount = double.tryParse(value);
                      if (amount == null || amount <= 0) {
                        return 'Please enter a valid amount';
                      }
                      if (amount > availableBalance) {
                        return 'Insufficient balance';
                      }
                      return null;
                    },
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^\d*\.?\d{0,7}'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),

                  // Error message
                  if (_errorMessage != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.errorColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppTheme.errorColor.withOpacity(0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.error_outline,
                            color: AppTheme.errorColor,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: const TextStyle(
                                color: AppTheme.errorColor,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Send button
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: _isLoading || availableBalance <= 0
                          ? null
                          : _showConfirmDialog,
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                              ),
                            )
                          : Text(
                              'Send $coin',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Security notice
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppTheme.warningColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppTheme.warningColor.withOpacity(0.3),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.info_outline,
                          color: AppTheme.warningColor,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Transactions cannot be reversed. Please double-check the recipient address before sending.',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 14,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
