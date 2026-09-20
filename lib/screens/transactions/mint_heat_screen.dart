import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../bloc/wallet/wallet_cubit.dart';
import '../../models/heat_amm.dart';
import '../../core/constants.dart';
import '../../utils/theme.dart';
import '../../utils/xfg_ticker.dart' as xt;

class MintHeatScreen extends StatefulWidget {
  const MintHeatScreen({super.key});

  @override
  State<MintHeatScreen> createState() => _MintHeatScreenState();
}

class _MintHeatScreenState extends State<MintHeatScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _amountFocusNode = FocusNode();

  bool _isLoading = false;
  bool _isLoadingRate = true;
  String? _errorMessage;
  HeatMetrics? _metrics;
  PoolInfo? _pool;
  String? _rateError;

  @override
  void initState() {
    super.initState();
    _loadMetrics();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _amountFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadMetrics() async {
    setState(() {
      _isLoadingRate = true;
      _rateError = null;
    });
    try {
      final cubit = context.read<WalletCubit>();
      // Pool info carries the mint price; metrics carry supply and treasury
      // figures for display.
      final results = await Future.wait([
        cubit.getHeatMetrics(),
        cubit.getPoolInfo(),
      ]);
      if (mounted) {
        setState(() {
          _metrics = results[0] as HeatMetrics;
          _pool = results[1] as PoolInfo;
          _isLoadingRate = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _rateError = 'Failed to load rate: $e';
          _isLoadingRate = false;
        });
      }
    }
  }

  /// The price consensus validates a mint against: the rolling 8-block TWAP,
  /// or the AMM spot price when the window is too short. Null when neither
  /// exists — the chain fails closed there, so the quote must too.
  int? get _mintPrice => _pool?.mintPrice;

  /// HEAT received per whole XFG burned, for display.
  double? get _heatPerXfg => _pool?.heatPerXfg;

  /// Quote on the chain's own terms:
  /// `expectedHeat = xfgBurned * mintPrice / COIN`, truncated down. Computed
  /// in atomic units so the displayed figure is the one the transaction will
  /// carry.
  double? get _estimatedHeat {
    final price = _mintPrice;
    if (price == null) return null;
    final xfg = double.tryParse(_amountController.text) ?? 0;
    if (xfg <= 0) return 0;
    final burnAtomic = (xfg * atomicPerCoin).round();
    return (burnAtomic * price ~/ atomicPerCoin) / atomicPerCoin;
  }

  void _onAmountChanged() {
    setState(() {}); // Rebuild to update estimated ΗΞΔŦ
  }

  void _showConfirmDialog() {
    if (!_formKey.currentState!.validate()) return;

    final cubit = context.read<WalletCubit>();
    final amountStr = _amountController.text.trim();
    final xfgAmount = double.tryParse(amountStr) ?? 0;
    final estimatedHeat = _estimatedHeat;

    if (xfgAmount <= 0) {
      setState(() => _errorMessage = 'Amount must be positive');
      return;
    }

    // Without a mint price there is no valid mint: consensus rejects on a
    // zero price. Quoting zero ΗΞΔŦ and submitting anyway burns XFG for a
    // transaction that cannot be accepted.
    if (estimatedHeat == null) {
      setState(() => _errorMessage =
          'No pool price available — the Hearth pool has no price yet. '
          'Minting is not possible until it does.');
      return;
    }

    // txFee atomic units (8000) expressed in XFG.
    const fee = txFee / atomicPerCoin;
    final totalXfg = xfgAmount + fee;

    if (totalXfg > cubit.state.unlockedBalanceXfg) {
      setState(() {
        _errorMessage =
            'Insufficient XFG balance (need ${totalXfg.toStringAsFixed(7)} XFG including fee)';
      });
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        title: const Text(
          'Confirm Mint ΗΞΔŦ',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _confirmRow('You burn', '${xfgAmount.toStringAsFixed(7)} XFG'),
            const SizedBox(height: 8),
            _confirmRow('Network fee', '${fee.toStringAsFixed(7)} XFG'),
            const Divider(color: AppTheme.textMuted),
            _confirmRow(
              'Total XFG',
              '${totalXfg.toStringAsFixed(7)} XFG',
              bold: true,
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'You will receive',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${estimatedHeat.toStringAsFixed(7)} ΗΞΔŦ',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                      fontFamily: AppTheme.numberFontFamily,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Rate: 1 XFG = ${(_heatPerXfg ?? 0).toStringAsFixed(4)} ΗΞΔŦ '
                    '(${_pool!.hearthTwap > 0 ? "TWAP" : "spot"})',
                    style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _promptPinAndMint();
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor),
            child: const Text('Confirm & Mint'),
          ),
        ],
      ),
    );
  }

  Future<void> _promptPinAndMint() async {
    final pinController = TextEditingController();
    final pin = await showDialog<String?>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppTheme.cardColor,
          title: const Text(
            'Enter PIN to mint',
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
    await _mintHeat(pin);
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

  Future<void> _mintHeat(String pin) async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final cubit = context.read<WalletCubit>();
      final amountStr = _amountController.text.trim();
      final xfgAmount = double.tryParse(amountStr) ?? 0;
      final price = _mintPrice;
      if (price == null) {
        throw StateError('Mint price unavailable');
      }
      // Snapshot the quote: the field stays editable during the await, and
      // the success dialog must report what was actually minted.
      final quotedHeat = _estimatedHeat ?? 0;

      final result = await cubit.mintHeat(
        xfgAmount: xfgAmount,
        mintPrice: price,
        pin: pin,
      );

      if (mounted) {
        final txHash = result['tx_hash'] as String? ?? '';
        _showSuccessDialog(txHash, xfgAmount, quotedHeat);
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

  void _showSuccessDialog(String txHash, double xfgAmount, double estimatedHeat) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: AppTheme.cardColor,
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: AppTheme.successColor),
              SizedBox(width: 8),
              Text('ΗΞΔŦ Minted', style: TextStyle(color: AppTheme.textPrimary)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              xt.xfgAmount(
                '${xfgAmount.toStringAsFixed(7)}',
                plainTail: ' XFG burned',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontFamily: AppTheme.numberFontFamily,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '+${estimatedHeat.toStringAsFixed(7)} ΗΞΔŦ received',
                style: TextStyle(
                  color: AppTheme.successColor,
                  fontSize: 16,
                  fontFamily: AppTheme.numberFontFamily,
                ),
              ),
              if (txHash.isNotEmpty) ...[
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

  void _setMaxAmount() {
    final state = context.read<WalletCubit>().state;
    final available = state.unlockedBalanceXfg;
    // Reserve 0.008 XFG for network fee
    final maxAmount = (available - 0.008).clamp(0.0, available);
    _amountController.text = maxAmount.toStringAsFixed(7);
    setState(() {}); // Update estimated ΗΞΔŦ
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mint ΗΞΔŦ'),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: BlocBuilder<WalletCubit, WalletState>(
        builder: (context, state) {
          final availableXfg = state.unlockedBalanceXfg;

          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // XFG balance card
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
                        Text(
                          'Available XFG Balance',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            xt.xfgAmount(
                              '${availableXfg.toStringAsFixed(7)}',
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

                  // Rate info card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceColor,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppTheme.textMuted.withOpacity(0.3),
                      ),
                    ),
                    child: _isLoadingRate
                        ? const Row(
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 12),
                              Text(
                                'Loading TWAP rate...',
                                style: TextStyle(color: AppTheme.textMuted),
                              ),
                            ],
                          )
                        : _rateError != null
                            ? Row(
                                children: [
                                  const Icon(
                                    Icons.warning_amber,
                                    color: AppTheme.warningColor,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _rateError!,
                                      style: const TextStyle(
                                        color: AppTheme.warningColor,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: _loadMetrics,
                                    child: const Text('Retry'),
                                  ),
                                ],
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    'Minting Rate (TWAP)',
                                    style: TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 14,
                                    ),
                                  ),
                                  Flexible(
                                    child: Text(
                                      _mintPrice == null
                                          ? 'Unavailable'
                                          : '1 XFG = ${_heatPerXfg!.toStringAsFixed(4)} ΗΞΔŦ',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.right,
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: AppTheme.textPrimary,
                                        fontFamily: AppTheme.numberFontFamily,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                  ),
                  const SizedBox(height: 24),

                  // XFG amount input
                  Text(
                    'XFG Amount to Burn',
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
                    onChanged: (_) => _onAmountChanged(),
                    decoration: InputDecoration(
                      hintText: '0.0000000',
                      prefixText: xt.XfgTicker.isGlyph ? xt.XfgTicker.glyph : 'XFG ',
                      prefixStyle: xt.XfgTicker.isGlyph
                          ? xt.XfgTicker.glyphStyle(const TextStyle(
                              color: AppTheme.primaryColor,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ))
                          : const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Please enter amount';
                      }
                      final amount = double.tryParse(value);
                      if (amount == null || amount <= 0) {
                        return 'Please enter a valid amount';
                      }
                      if (amount + 0.008 > availableXfg) {
                        return 'Insufficient XFG balance (incl. 0.008 fee)';
                      }
                      return null;
                    },
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^\d*\.?\d{0,7}'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Estimated ΗΞΔŦ output
                  if (_estimatedHeat != null && _amountController.text.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppTheme.primaryColor.withOpacity(0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Estimated ΗΞΔŦ to receive',
                            style: TextStyle(
                              fontSize: 14,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_estimatedHeat!.toStringAsFixed(7)} ΗΞΔŦ',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                              fontFamily: AppTheme.numberFontFamily,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
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

                  // Mint button
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: _isLoading ||
                              availableXfg <= 0 ||
                              _mintPrice == null
                          ? null
                          : _showConfirmDialog,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accentColor,
                        foregroundColor: Colors.black,
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.black,
                                ),
                              ),
                            )
                          : const Text(
                              'Mint ΗΞΔŦ',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Info notice
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
                            'Minting burns XFG to create ΗΞΔŦ at the current mint price. '
                            'The rate is updated each block. This action cannot be undone.',
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
