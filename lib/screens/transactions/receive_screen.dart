import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../bloc/wallet/wallet_cubit.dart';
import '../../core/constants.dart';
import '../../models/subaddress.dart';
import '../../utils/theme.dart';

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen>
    with TickerProviderStateMixin {
  final _amountController = TextEditingController();
  final _labelController = TextEditingController();

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  String? _selectedAddress;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fadeController, curve: Curves.easeInOut),
    );
    _fadeController.forward();
    _loadAddress();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _labelController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _loadAddress() async {
    try {
      final cubit = context.read<WalletCubit>();
      final address = cubit.state.address ?? await cubit.getAddress();
      setState(() {
        _selectedAddress = address;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  void _selectAddress(String address) {
    setState(() => _selectedAddress = address);
  }

  void _selectMasterAddress() {
    final cubit = context.read<WalletCubit>();
    setState(() => _selectedAddress = cubit.state.address);
  }

  Future<void> _generateSubaddress() async {
    final label = _labelController.text.trim();
    if (label.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a label for this subaddress'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
      return;
    }

    final cubit = context.read<WalletCubit>();
    final sub = await cubit.createSubaddress(label);
    if (sub != null && mounted) {
      _labelController.clear();
      setState(() => _selectedAddress = sub.address);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Subaddress "$label" created'),
          backgroundColor: AppTheme.successColor,
        ),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to create subaddress'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied'),
        backgroundColor: AppTheme.successColor,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _generateQRData() {
    if (_selectedAddress == null || _selectedAddress!.isEmpty) return '';

    final uri = StringBuffer('fuego:$_selectedAddress');
    final amount = _amountController.text.trim();
    final params = <String>[];

    if (amount.isNotEmpty) {
      params.add('amount=$amount');
    }

    if (params.isNotEmpty) {
      uri.write('?${params.join('&')}');
    }

    return uri.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Receive XFG'),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryColor),
              ),
            )
          : FadeTransition(
              opacity: _fadeAnimation,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // QR Code
                    _buildQRCode(),
                    const SizedBox(height: 24),

                    // Master Address
                    _buildMasterAddress(),
                    const SizedBox(height: 8),

                    // Privacy note
                    _buildPrivacyNote(),
                    const SizedBox(height: 24),

                    // Subaddress section
                    _buildSubaddressSection(),
                    const SizedBox(height: 24),

                    // Request amount
                    _buildAmountField(),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildQRCode() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryColor.withOpacity(0.15),
            blurRadius: 15,
            spreadRadius: 2,
          ),
        ],
      ),
      child: _selectedAddress != null && _selectedAddress!.isNotEmpty
          ? QrImageView(
              data: _generateQRData(),
              version: QrVersions.auto,
              size: 200,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            )
          : Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                color: AppTheme.surfaceColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: Text(
                  'No address available',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
              ),
            ),
    );
  }

  Widget _buildMasterAddress() {
    final cubit = context.read<WalletCubit>();
    final masterAddress = cubit.state.address ?? '';
    final isSelected = _selectedAddress == masterAddress;

    return GestureDetector(
      onTap: _selectMasterAddress,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? AppTheme.primaryColor
                : AppTheme.primaryColor.withOpacity(0.3),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Text(
                      'Master Address',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    if (isSelected) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryColor.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'SELECTED',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.primaryColor,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                IconButton(
                  onPressed: () => _copyToClipboard(masterAddress, 'Master address'),
                  icon: const Icon(Icons.copy, color: AppTheme.primaryColor, size: 20),
                  tooltip: 'Copy master address',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.surfaceColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                masterAddress.isEmpty ? 'Loading...' : masterAddress,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 13,
                  fontFamily: 'IBMPlexMono',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPrivacyNote() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.warningColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.warningColor.withOpacity(0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.shield_outlined, color: AppTheme.warningColor, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Use a new subaddress per payer to tell payments apart. Every '
              'subaddress carries this wallet\'s view key, so anyone who sees two '
              'of them can tell they belong to the same wallet.',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubaddressSection() {
    return BlocBuilder<WalletCubit, WalletState>(
      builder: (context, state) {
        final subaddresses = state.subaddresses.where((s) => !s.legacy).toList();
        final legacy = state.subaddresses.where((s) => s.legacy).toList();

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.textMuted.withOpacity(0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Subaddresses',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Payments to any subaddress arrive in this wallet\'s balance.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 12),

              // Generate new subaddress
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _labelController,
                      decoration: const InputDecoration(
                        hintText: 'Label (e.g. "exchange", "friend-alice")',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      onSubmitted: (_) => _generateSubaddress(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _generateSubaddress,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                    child: const Text('Generate', style: TextStyle(fontSize: 13)),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              if (subaddresses.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No subaddresses yet. Generate one to receive funds privately.',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                  ),
                )
              else
                ...subaddresses.map((sub) => _buildSubaddressTile(sub)),
              if (legacy.isNotEmpty) ...[
                const SizedBox(height: 12),
                _buildLegacyNotice(state.legacySubaddressBalance),
                const SizedBox(height: 8),
                ...legacy.map((sub) => _buildSubaddressTile(sub)),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildLegacyNotice(int balance) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.errorColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.errorColor.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Old-format subaddresses — stop sharing these',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'They were created with keys that overlap your main keys: funds on the '
            'first one can be spent by anyone holding your view key. The wallet now '
            'scans them and can move what is there to your main address.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12, height: 1.4),
          ),
          if (balance > 0) ...[
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _sweepLegacy,
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorColor),
              child: Text('Move ${(balance / atomicPerCoin).toStringAsFixed(7)} XFG to main address'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _sweepLegacy() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final tx = await context.read<WalletCubit>().sweepLegacySubaddresses();
      messenger.showSnackBar(SnackBar(
        content: Text(tx == null
            ? 'Nothing confirmed on old subaddresses yet'
            : 'Moved to main address (tx ${tx.substring(0, 12)}…)'),
        backgroundColor: tx == null ? AppTheme.warningColor : AppTheme.successColor,
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Could not move funds: $e'),
        backgroundColor: AppTheme.errorColor,
      ));
    }
  }

  Widget _buildSubaddressTile(Subaddress sub) {
    final isSelected = _selectedAddress == sub.address;

    return GestureDetector(
      // Old-format addresses must not be handed out again.
      onTap: sub.legacy ? null : () => _selectAddress(sub.address),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.primaryColor.withOpacity(0.08) : AppTheme.surfaceColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? AppTheme.primaryColor : AppTheme.textMuted.withOpacity(0.15),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        sub.label,
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                        ),
                      ),
                      if (sub.legacy) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppTheme.errorColor.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: const Text(
                            'OLD FORMAT',
                            style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppTheme.errorColor),
                          ),
                        ),
                      ],
                      if (isSelected) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: const Text(
                            'ACTIVE',
                            style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppTheme.primaryColor),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sub.addressShort,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                      fontFamily: 'IBMPlexMono',
                    ),
                  ),
                ],
              ),
            ),
            if (!sub.legacy)
              IconButton(
                onPressed: () => _copyToClipboard(sub.address, 'Subaddress'),
                icon: const Icon(Icons.copy, size: 16),
                tooltip: 'Copy',
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            IconButton(
              // Legacy entries are the only record of which old keys to scan.
              onPressed: sub.legacy ? null : () => _showDeleteDialog(sub),
              icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.errorColor),
              tooltip: 'Delete',
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteDialog(Subaddress sub) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        title: const Text('Delete Subaddress', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          'Delete "${sub.label}"? Any funds sent to this address will still be accessible from your wallet.',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              context.read<WalletCubit>().removeSubaddress(sub);
              if (_selectedAddress == sub.address) {
                _selectMasterAddress();
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorColor),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Widget _buildAmountField() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primaryColor.withOpacity(0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Request Specific Amount (Optional)',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amountController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              hintText: '0.0000000',
              suffixText: 'XFG',
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,7}')),
            ],
          ),
        ],
      ),
    );
  }
}
