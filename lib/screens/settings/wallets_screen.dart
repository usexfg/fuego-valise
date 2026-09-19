import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';
import '../../bloc/wallet/wallet_cubit.dart';
import '../../providers/wallet_provider.dart';
import '../../services/fuego_vault_service.dart';
import '../../services/security_service.dart';
import '../../utils/theme.dart';
import 'create_new_wallet_screen.dart';
import 'restore_wallet_screen.dart';

/// Manage saved wallets on this device: switch between them, add new ones,
/// import from a mnemonic, or remove them.
class WalletsScreen extends StatefulWidget {
  const WalletsScreen({super.key});

  @override
  State<WalletsScreen> createState() => _WalletsScreenState();
}

class _WalletsScreenState extends State<WalletsScreen> {
  List<WalletEntry> _wallets = [];
  String? _activeId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final vault = context.read<FuegoVaultService>();
    setState(() {
      _wallets = vault.wallets;
      _activeId = vault.activeWalletId;
    });
  }

  Future<String?> _promptSecret(
    String title,
    String subtitle, {
    bool numeric = false,
  }) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        title: Text(title, style: const TextStyle(color: AppTheme.textPrimary)),
        content: TextField(
          controller: controller,
          obscureText: true,
          keyboardType: numeric ? TextInputType.number : null,
          maxLength: 64,
          decoration: InputDecoration(
            labelText: subtitle,
            counterText: '',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
            ),
            child: const Text('Authorize'),
          ),
        ],
      ),
    ).then((value) {
      controller.dispose();
      return value;
    });
  }

  Future<void> _switchTo(WalletEntry entry) async {
    final password = await _promptSecret(
      'Switch Wallet',
      'Password for ${entry.name}',
    );
    if (password == null || password.isEmpty || !mounted) return;

    final provider = Provider.of<WalletProvider>(context, listen: false);
    final ok = await provider.switchWallet(id: entry.id, password: password);
    if (!mounted) return;

    if (ok) {
      try {
        await context.read<WalletCubit>().onUnlocked();
      } catch (_) {}
      _load();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Switched to ${entry.name}'),
          backgroundColor: AppTheme.successColor,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(provider.error ?? 'Failed to switch wallet'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  Future<void> _removeWallet(WalletEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        title: const Text(
          'Remove Wallet',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: Text(
          'Delete "${entry.name}" from this device? The wallet file will be '
          'permanently removed. You can only recover it with its seed phrase.',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.errorColor,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Device-level destructive action — gate on the app PIN when one exists.
    // Self-heal: installs that predate PIN setup have nothing to verify.
    final hasPin = await SecurityService().hasPIN();
    if (!mounted) return;
    if (hasPin) {
      final pin = await _promptSecret(
        'Confirm App PIN',
        'Enter your app PIN',
        numeric: true,
      );
      if (pin == null || pin.isEmpty || !mounted) return;
      final pinOk = await SecurityService().verifyPIN(pin);
      if (!mounted) return;
      if (!pinOk) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invalid PIN'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
        return;
      }
    }

    final wasActive = entry.id == _activeId;
    final provider = Provider.of<WalletProvider>(context, listen: false);
    final ok = await provider.removeWallet(id: entry.id);
    if (!mounted) return;

    if (ok) {
      if (wasActive) {
        // Unlock the newly active wallet with its own password.
        final vault = context.read<FuegoVaultService>();
        final next = vault.activeWallet;
        if (next != null) {
          final password = await _promptSecret(
            'Unlock ${next.name}',
            'Password for ${next.name}',
          );
          if (password != null && password.isNotEmpty && mounted) {
            await provider.switchWallet(id: next.id, password: password);
          }
        }
      }
      if (!mounted) return;
      try {
        await context.read<WalletCubit>().onUnlocked();
      } catch (_) {}
      _load();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${entry.name} removed'),
          backgroundColor: AppTheme.successColor,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(provider.error ?? 'Failed to remove wallet'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  Future<void> _openCreate() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const CreateNewWalletScreen()),
    );
    if (mounted) _load();
  }

  Future<void> _openRestore() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const RestoreWalletScreen()),
    );
    if (mounted) _load();
  }

  String _formatDate(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '$dd/$mm/${d.year}';
  }

  String _truncate(String address) {
    if (address.isEmpty) return '—';
    if (address.length <= 20) return address;
    return '${address.substring(0, 10)}...${address.substring(address.length - 10)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallets'),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final entry in _wallets) _buildWalletCard(entry),
          const SizedBox(height: 24),
          SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _openCreate,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.add),
              label: const Text(
                'Create New Wallet',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 52,
            child: OutlinedButton.icon(
              onPressed: _openRestore,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primaryColor,
                side: const BorderSide(color: AppTheme.primaryColor),
              ),
              icon: const Icon(Icons.download_outlined),
              label: const Text(
                'Import Wallet (Mnemonic)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWalletCard(WalletEntry entry) {
    final isActive = entry.id == _activeId;
    final date = _formatDate(entry.createdAt);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive
              ? AppTheme.primaryColor.withOpacity(0.6)
              : AppTheme.textMuted.withOpacity(0.3),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: isActive ? null : () => _switchTo(entry),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        gradient: AppTheme.primaryGradient,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.account_balance_wallet,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.name,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            entry.address.isEmpty
                                ? 'Address shown after unlock'
                                : _truncate(entry.address),
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSecondary,
                              fontFamily: 'IBMPlexMono',
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isActive)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.successColor.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.check_circle,
                              size: 14,
                              color: AppTheme.successColor,
                            ),
                            SizedBox(width: 4),
                            Text(
                              'Active',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.successColor,
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      IconButton(
                        tooltip: 'Remove wallet',
                        onPressed: () => _removeWallet(entry),
                        icon: const Icon(
                          Icons.delete_outline,
                          color: AppTheme.errorColor,
                          size: 20,
                        ),
                      ),
                  ],
                ),
                if (date.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Added $date',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
