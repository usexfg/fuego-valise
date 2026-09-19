import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../bloc/erc20/erc20_cubit.dart';
import '../../models/erc20_token.dart';
import '../../services/custom_token_store.dart';
import '../../utils/theme.dart';

class TokenOverviewScreen extends StatefulWidget {
  const TokenOverviewScreen({super.key});

  @override
  State<TokenOverviewScreen> createState() => _TokenOverviewScreenState();
}

class _TokenOverviewScreenState extends State<TokenOverviewScreen> {
  final _addrCtrl = TextEditingController();
  final _pkCtrl = TextEditingController();
  final _toCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  EvmChainKey _chain = EvmChainKey.eth;

  /// This is the manage-everything screen, so it opens on All; the chips
  /// below isolate stables from the rest.
  Erc20Filter _filter = Erc20Filter.all;

  @override
  void dispose() {
    _addrCtrl.dispose();
    _pkCtrl.dispose();
    _toCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => Erc20Cubit(),
      child: Scaffold(
        backgroundColor: AppTheme.backgroundColor,
        appBar: AppBar(
          title: const Text('Tokens'),
          backgroundColor: AppTheme.backgroundColor,
        ),
        body: BlocBuilder<Erc20Cubit, Erc20State>(
          builder: (context, state) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _addressField(context, state),
              const SizedBox(height: 12),
              _chainSelector(context),
              const SizedBox(height: 10),
              _filterRow(state),
              const SizedBox(height: 12),
              if (state.error != null)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.errorColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    state.error!,
                    style: const TextStyle(
                      color: AppTheme.errorColor,
                      fontSize: 12,
                    ),
                  ),
                ),
              if (state.isLoading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: CircularProgressIndicator(
                      color: AppTheme.primaryColor,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              ..._tokenRows(context, state),
              const SizedBox(height: 24),
              _transferCard(context, state),
            ],
          ),
        ),
      ),
    );
  }

  Widget _addressField(BuildContext context, Erc20State state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _addrCtrl,
          decoration: InputDecoration(
            labelText: 'EVM address (watch-only)',
            hintText: '0x...',
            suffixIcon: IconButton(
              icon: const Icon(Icons.search, color: AppTheme.primaryColor),
              onPressed: () =>
                  context.read<Erc20Cubit>().setAddress(_addrCtrl.text.trim()),
            ),
          ),
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontFamily: 'IBMPlexMono',
            fontSize: 13,
          ),
          onSubmitted: (v) => context.read<Erc20Cubit>().setAddress(v),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              'Or derive from private key',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
            const Spacer(),
            TextButton(
              onPressed: () {
                final pk = _pkCtrl.text.trim();
                if (pk.isEmpty) return;
                final addr = context.read<Erc20Cubit>().addressFromPrivateKey(
                  pk,
                );
                if (addr.isNotEmpty) {
                  _addrCtrl.text = addr;
                  context.read<Erc20Cubit>().setAddress(addr);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Invalid private key')),
                  );
                }
              },
              child: const Text('Derive', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
        TextField(
          controller: _pkCtrl,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Private key (local only, never sent)',
            hintText: '0x... 64 hex',
          ),
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 12,
            fontFamily: 'IBMPlexMono',
          ),
        ),
      ],
    );
  }

  Widget _chainSelector(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Text(
            'Chain',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: DropdownButton<EvmChainKey>(
              value: _chain,
              dropdownColor: AppTheme.cardColor,
              underline: const SizedBox.shrink(),
              isExpanded: false,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              items: EvmChainKey.values
                  .map(
                    (c) => DropdownMenuItem(
                      value: c,
                      child: Text('${c.key.toUpperCase()} (${c.chainId})'),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _chain = v ?? EvmChainKey.eth),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: TextButton.icon(
              onPressed: () => _showAddTokenDialog(context),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Token', style: TextStyle(fontSize: 12)),
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.refresh,
              color: AppTheme.primaryColor,
              size: 18,
            ),
            onPressed: () {
              final addr = context.read<Erc20Cubit>().state.address;
              if (addr != null && addr.isNotEmpty) {
                context.read<Erc20Cubit>().refreshChain(_chain.key);
              } else {
                context.read<Erc20Cubit>().refresh();
              }
            },
          ),
        ],
      ),
    );
  }

  /// Counts per slice for the chips. Registry + whatever the user added,
  /// so an empty "Tokens" chip is honest about there being nothing there.
  ({int all, int stables, int tokens}) _counts(Erc20State state) {
    final balances = state.balancesFor(_chain.key);
    final source = balances.isNotEmpty
        ? balances.map((b) => b.token)
        : Erc20Registry.forChainKey(_chain);
    final stables = source.where((t) => t.isStable).length;
    return (
      all: source.length,
      stables: stables,
      tokens: source.length - stables,
    );
  }

  Widget _filterRow(Erc20State state) {
    final c = _counts(state);
    Widget chip(String label, int count, Erc20Filter f) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text('$label ($count)', style: const TextStyle(fontSize: 11)),
        selected: _filter == f,
        onSelected: (_) => setState(() => _filter = f),
        backgroundColor: AppTheme.surfaceColor,
        selectedColor: AppTheme.primaryColor.withValues(alpha: 0.2),
        labelStyle: TextStyle(
          color: _filter == f ? AppTheme.primaryColor : AppTheme.textMuted,
          fontWeight: _filter == f ? FontWeight.w700 : FontWeight.w500,
        ),
        side: BorderSide(
          color: _filter == f
              ? AppTheme.primaryColor.withValues(alpha: 0.4)
              : AppTheme.surfaceColor,
        ),
        showCheckmark: false,
      ),
    );
    return Row(
      children: [
        chip('All', c.all, Erc20Filter.all),
        chip('Stables', c.stables, Erc20Filter.stables),
        chip('Tokens', c.tokens, Erc20Filter.tokens),
      ],
    );
  }

  List<Widget> _tokenRows(BuildContext context, Erc20State state) {
    final balances = state.balancesFor(_chain.key);
    // Show merged registry+custom tokens for chain even before first load
    final all = balances.isNotEmpty
        ? balances
        : Erc20Registry.forChainKey(_chain)
              .map(
                (t) => Erc20Balance(
                  token: t,
                  raw: BigInt.zero,
                  decimals: t.decimals,
                  display: 0,
                ),
              )
              .toList();
    final tokens = all.where((b) => _filter.accepts(b.token.kind)).toList();
    if (tokens.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            _filter == Erc20Filter.stables
                ? 'No stablecoin verified on ${_chain.key.toUpperCase()} yet.'
                : 'Nothing here for ${_chain.key.toUpperCase()} — use Add Token.',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
          ),
        ),
      ];
    }
    return tokens.map((b) {
      final token = b.token;
      final isSelected = state.selectedToken == token;
      final isCustom = !CustomTokenStore.instance.isRegistry(token);
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primaryColor.withValues(alpha: 0.08)
              : AppTheme.surfaceColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? AppTheme.primaryColor.withValues(alpha: 0.3)
                : Colors.transparent,
          ),
        ),
        child: ListTile(
          onLongPress: isCustom
              ? () => _confirmRemoveToken(context, token)
              : null,
          onTap: () => context.read<Erc20Cubit>().selectToken(token),
          leading: CircleAvatar(
            backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.15),
            child: Text(
              token.symbol[0],
              style: const TextStyle(
                color: AppTheme.primaryColor,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  token.symbol,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                token.chainKey.toUpperCase(),
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
              ),
              if (isCustom) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'CUSTOM',
                    style: TextStyle(
                      color: AppTheme.primaryColor,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
          subtitle: SelectableText(
            token.address,
            style: const TextStyle(
              color: AppTheme.textMuted,
              fontSize: 10,
              fontFamily: 'IBMPlexMono',
            ),
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                b.display.toStringAsFixed(4),
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                  fontFamily: AppTheme.numberFontFamily,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '${token.symbol} • ${b.decimals} dec',
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }

  void _confirmRemoveToken(BuildContext context, Erc20Token token) {
    showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        title: Text(
          'Remove ${token.symbol}?',
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16),
        ),
        content: Text(
          'Removes it from your list only. On-chain balance is untouched.',
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dctx);
              await CustomTokenStore.instance.remove(
                token.chainKey,
                token.address,
              );
              if (!context.mounted) return;
              await context.read<Erc20Cubit>().refreshChain(_chain.key);
            },
            child: const Text(
              'Remove',
              style: TextStyle(color: AppTheme.errorColor),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddTokenDialog(BuildContext context) async {
    var dialogChain = _chain;
    final addrCtrl = TextEditingController();
    final symCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final decCtrl = TextEditingController(text: '18');
    String? fetchError;
    var fetching = false;
    var fetched = false;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDState) => AlertDialog(
          backgroundColor: AppTheme.cardColor,
          title: const Text(
            'Add Token',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 16),
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButton<EvmChainKey>(
                  value: dialogChain,
                  isExpanded: true,
                  dropdownColor: AppTheme.cardColor,
                  underline: const SizedBox.shrink(),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                  ),
                  items: EvmChainKey.values
                      .map(
                        (c) => DropdownMenuItem(
                          value: c,
                          child: Text(
                            '${Erc20Registry.displayNameFor(c.key)} (${c.chainId})',
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) =>
                      setDState(() => dialogChain = v ?? dialogChain),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: addrCtrl,
                  decoration: InputDecoration(
                    labelText: 'Contract address',
                    hintText: '0x...',
                    suffixIcon: fetching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            icon: const Icon(Icons.download, size: 20),
                            tooltip: 'Fetch symbol/name/decimals from RPC',
                            onPressed: () async {
                              final a = addrCtrl.text.trim();
                              if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(a)) {
                                setDState(
                                  () => fetchError = 'Invalid contract address',
                                );
                                return;
                              }
                              setDState(() {
                                fetching = true;
                                fetchError = null;
                              });
                              try {
                                final svc = context.read<Erc20Cubit>().service;
                                final sym = await svc.symbol(
                                  chainKey: dialogChain.key,
                                  tokenAddress: a,
                                );
                                final name = await svc.name(
                                  chainKey: dialogChain.key,
                                  tokenAddress: a,
                                );
                                final dec = await svc.decimals(
                                  chainKey: dialogChain.key,
                                  tokenAddress: a,
                                );
                                symCtrl.text = sym;
                                nameCtrl.text = name;
                                decCtrl.text = dec.toString();
                                setDState(() {
                                  fetched = true;
                                  fetching = false;
                                });
                              } catch (e) {
                                setDState(() {
                                  fetchError = 'RPC fetch failed: $e';
                                  fetching = false;
                                });
                              }
                            },
                          ),
                  ),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontFamily: 'IBMPlexMono',
                  ),
                ),
                if (fetchError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      fetchError!,
                      style: const TextStyle(
                        color: AppTheme.errorColor,
                        fontSize: 11,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: symCtrl,
                  decoration: const InputDecoration(labelText: 'Symbol'),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Name'),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: decCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Decimals'),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Fetch reads symbol()/name()/decimals() via the chain RPC — verify the address against the project\'s official docs before trusting a balance.',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 10),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final a = addrCtrl.text.trim();
                final sym = symCtrl.text.trim().toUpperCase();
                final dec = int.tryParse(decCtrl.text.trim()) ?? -1;
                if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(a)) {
                  setDState(() => fetchError = 'Invalid contract address');
                  return;
                }
                if (sym.isEmpty || dec < 0 || dec > 36) {
                  setDState(
                    () => fetchError = 'Symbol required; decimals 0-36',
                  );
                  return;
                }
                Navigator.pop(dctx, true);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
              ),
              child: Text(fetched ? 'Save' : 'Save anyway'),
            ),
          ],
        ),
      ),
    );

    if (ok != true) return;
    final token = Erc20Token(
      address: addrCtrl.text.trim(),
      symbol: symCtrl.text.trim().toUpperCase(),
      name: nameCtrl.text.trim().isEmpty
          ? symCtrl.text.trim()
          : nameCtrl.text.trim(),
      decimals: int.tryParse(decCtrl.text.trim()) ?? 18,
      chain: dialogChain,
      kind: Erc20Kind.token,
    );
    final dup = await CustomTokenStore.instance.exists(
      dialogChain.key,
      token.address,
    );
    if (dup) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${token.symbol} already in list')),
      );
      return;
    }
    await CustomTokenStore.instance.add(token);
    setState(() => _chain = dialogChain);
    if (!mounted) return;
    await context.read<Erc20Cubit>().refreshChain(dialogChain.key);
  }

  Widget _transferCard(BuildContext context, Erc20State state) {
    final token = state.selectedToken;
    if (token == null || token.chain != _chain) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.surfaceColor.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text(
          'Select a token above to send',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Send ${token.symbol} on ${token.chainKey.toUpperCase()}',
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _toCtrl,
            decoration: const InputDecoration(
              labelText: 'To address',
              hintText: '0x...',
            ),
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 13,
              fontFamily: 'IBMPlexMono',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Amount (${token.symbol})',
              hintText: '1.5',
            ),
            style: const TextStyle(color: AppTheme.textPrimary),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: state.isLoading
                      ? null
                      : () => _doTransfer(context, token),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                  ),
                  child: state.isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Send',
                          style: TextStyle(color: Colors.white),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: state.isLoading
                      ? null
                      : () => _doApprove(context, token),
                  child: const Text('Approve HTLC'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Send uses your private key locally to sign an ERC20 transfer. Approve grants an HTLC contract allowance — check allowance first.',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Future<void> _doTransfer(BuildContext context, Erc20Token token) async {
    final to = _toCtrl.text.trim();
    final amount = _amountCtrl.text.trim();
    final pk = _pkCtrl.text.trim();
    if (to.isEmpty || amount.isEmpty || pk.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fill to, amount, and private key')),
      );
      return;
    }
    try {
      final cubit = context.read<Erc20Cubit>();
      final tx = await cubit.transfer(
        privateKey: pk,
        token: token,
        toAddress: to,
        amountDisplay: amount,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sent: $tx'),
          backgroundColor: AppTheme.successColor,
        ),
      );
      _amountCtrl.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Send failed: $e'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  Future<void> _doApprove(BuildContext context, Erc20Token token) async {
    final pk = _pkCtrl.text.trim();
    final amount = _amountCtrl.text.trim().isEmpty
        ? '1000000'
        : _amountCtrl.text.trim();
    if (pk.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter private key to approve')),
      );
      return;
    }
    // HTLC address placeholder — user can paste real contract. For demo, approve to self and show allowance check.
    final spender = _toCtrl.text.trim().isEmpty
        ? token.address
        : _toCtrl.text.trim();
    try {
      final cubit = context.read<Erc20Cubit>();
      final tx = await cubit.approveIfNeeded(
        privateKey: pk,
        token: token,
        spender: spender,
        amountDisplay: amount,
      );
      if (!mounted) return;
      final msg = tx == 'already-approved'
          ? 'Already approved for $amount ${token.symbol}'
          : 'Approved: $tx';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: AppTheme.successColor),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Approve failed: $e'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }
}
