import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../models/chain_registry.g.dart';
import '../../services/evm_account_service.dart';
import '../../services/web3_multi_chain_service.dart';
import '../../utils/theme.dart';
import 'create_evm_account_screen.dart';

/// Manage saved EVM accounts. One account can be viewed on any EVM chain.
class EvmWalletsScreen extends StatefulWidget {
  const EvmWalletsScreen({super.key});

  @override
  State<EvmWalletsScreen> createState() => _EvmWalletsScreenState();
}

class _EvmWalletsScreenState extends State<EvmWalletsScreen> {
  late final EvmAccountService _accountService;
  late final Web3MultiChainService _web3;
  List<EvmAccount> _accounts = [];
  final Map<String, double> _balances = {};
  final Set<String> _loadingBalances = {};
  int _balanceGeneration = 0;
  bool _isLoading = true;

  List<ChainEntry> get _evmChains =>
      kChains.where((chain) => chain.family == 'evm').toList();

  @override
  void initState() {
    super.initState();
    _accountService = context.read<EvmAccountService>();
    _web3 = Web3MultiChainService();
    _loadAccounts();
  }

  @override
  void dispose() {
    _balanceGeneration++;
    _web3.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    try {
      await _accountService.init();
      if (!mounted) return;
      setState(() {
        _accounts = _accountService.accounts;
        _isLoading = false;
      });
      await _refreshBalances();
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showMessage('Unable to load EVM wallets: $error', isError: true);
    }
  }

  Future<void> _refreshBalances() async {
    final generation = ++_balanceGeneration;
    final accounts = List<EvmAccount>.from(_accounts);
    for (final account in accounts) {
      if (!mounted || generation != _balanceGeneration) return;
      setState(() => _loadingBalances.add(account.id));
      final balance = await _web3.getBalance(account.address, account.chainKey);
      if (!mounted || generation != _balanceGeneration) return;
      setState(() {
        _balances[account.id] = balance;
        _loadingBalances.remove(account.id);
      });
    }
  }

  Future<void> _changeChain(EvmAccount account, String? chainKey) async {
    if (chainKey == null || chainKey == account.chainKey) return;
    try {
      await _accountService.updateChain(id: account.id, chainKey: chainKey);
      if (!mounted) return;
      setState(() {
        _accounts = _accountService.accounts;
        _balances.remove(account.id);
      });
      await _refreshAccountBalance(account.id);
    } catch (error) {
      _showMessage('Unable to change network view: $error', isError: true);
    }
  }

  Future<void> _refreshAccountBalance(String accountId) async {
    final account = _accounts.cast<EvmAccount?>().firstWhere(
          (entry) => entry?.id == accountId,
          orElse: () => null,
        );
    if (account == null) return;
    final generation = ++_balanceGeneration;
    if (mounted) setState(() => _loadingBalances.add(account.id));
    final balance = await _web3.getBalance(account.address, account.chainKey);
    if (!mounted || generation != _balanceGeneration) return;
    setState(() {
      _balances[account.id] = balance;
      _loadingBalances.remove(account.id);
    });
  }

  Future<void> _selectAccount(EvmAccount account) async {
    try {
      await _accountService.setActive(account.id);
      if (!mounted) return;
      setState(() {});
      _showMessage('${account.name} is now active');
    } catch (error) {
      _showMessage('Unable to select wallet: $error', isError: true);
    }
  }

  Future<void> _removeAccount(EvmAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        title: const Text('Remove EVM wallet'),
        content: Text(
          'Remove ${account.name} from this device? Make sure you have backed up its private key first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorColor),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _accountService.remove(account.id);
      if (!mounted) return;
      setState(() {
        _accounts = _accountService.accounts;
        _balances.remove(account.id);
      });
      _showMessage('${account.name} removed');
    } catch (error) {
      _showMessage('Unable to remove wallet: $error', isError: true);
    }
  }

  Future<void> _copyAddress(EvmAccount account) async {
    await Clipboard.setData(ClipboardData(text: account.address));
    if (mounted) _showMessage('Address copied');
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppTheme.errorColor : AppTheme.successColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EVM Vault'),
        actions: [
          IconButton(
            tooltip: 'Refresh balances',
            onPressed: _isLoading ? null : _refreshBalances,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadAccounts,
              child: _accounts.isEmpty ? _buildEmptyState() : _buildList(),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreate,
        icon: const Icon(Icons.add),
        label: const Text('New Account'),
      ),
    );
  }

  Widget _buildList() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      itemCount: _accounts.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) => _buildAccountCard(_accounts[index]),
    );
  }

  Widget _buildEmptyState() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(28),
      children: [
        const SizedBox(height: 90),
        const Icon(Icons.account_balance_wallet_outlined,
            size: 58, color: AppTheme.primaryColor),
        const SizedBox(height: 18),
        const Text(
          'No accounts on this device',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 21),
        ),
        const SizedBox(height: 10),
        const Text(
          'One account. Every supported EVM network.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: _openCreate,
          child: const Text('New Account'),
        ),
      ],
    );
  }

  Widget _buildAccountCard(EvmAccount account) {
    final chain = kChainByKey[account.chainKey];
    final isActive = _accountService.activeId == account.id;
    final balance = _balances[account.id];
    final isLoading = _loadingBalances.contains(account.id);
    final gasToken = chain?.gasToken.isNotEmpty == true
        ? chain!.gasToken
        : (chain?.ticker ?? 'native');

    return Card(
      color: AppTheme.cardColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    account.name,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (isActive)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppTheme.primaryColor.withOpacity(0.35)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 6,
                          height: 6,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: AppTheme.primaryColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Active',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.primaryColor,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'select') _selectAccount(account);
                    if (value == 'remove') _removeAccount(account);
                  },
                  itemBuilder: (_) => [
                    if (!isActive)
                      const PopupMenuItem(
                        value: 'select',
                        child: Text('Set active'),
                      ),
                    const PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove from device'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    _shortAddress(account.address),
                    style: AppTheme.numericStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy address',
                  onPressed: () => _copyAddress(account),
                  icon: const Icon(Icons.copy, size: 18),
                  color: AppTheme.textSecondary,
                ),
              ],
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: account.chainKey,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Network view',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final evmChain in _evmChains)
                  DropdownMenuItem(
                    value: evmChain.key,
                    child: Text('${evmChain.name} (${evmChain.ticker})'),
                  ),
              ],
              onChanged: (value) => _changeChain(account, value),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Holdings', style: TextStyle(color: AppTheme.textMuted)),
                const Spacer(),
                if (isLoading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Text(
                    '${(balance ?? 0).toStringAsFixed(6)} $gasToken',
                    style: AppTheme.numericStyle(color: AppTheme.textPrimary),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openCreate() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const CreateEvmAccountScreen()),
    );
    if (created == true && mounted) await _loadAccounts();
  }

  static String _shortAddress(String address) {
    if (address.length <= 14) return address;
    return '${address.substring(0, 8)}...${address.substring(address.length - 6)}';
  }
}
