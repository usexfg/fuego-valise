import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../bloc/dex/dex_cubit.dart';
import '../../main.dart';
import '../../core/constants.dart';
import '../../models/chain_info.dart';
import '../../models/swap_models.dart';
import '../../services/swap_daemon_client.dart';
import '../../services/swap_notification_service.dart';
import '../../utils/theme.dart';
import '../../widgets/swap/success_confetti.dart';
import '../../widgets/swap/confirmation_cluster.dart';
import '../../widgets/swap/contract_inspector_sheet.dart';
import '../../widgets/swap/failure_card.dart';
import '../../widgets/swap/swap_amount_row.dart';
import '../../widgets/swap/swap_card.dart';
import '../../widgets/swap/swap_receipt.dart';
import '../../widgets/swap/swap_timeline_stepper.dart';
import '../../widgets/swap/timelock_countdown.dart';

/// Direct peer-to-peer atomic swaps with a CHOSEN counterparty.
///
/// This is intentionally NOT an orderbook or a swap-widget: there is no
/// automatic liquidity here. Both parties negotiate out-of-band (chat,
/// forum, trade desk) and exchange the swap endpoint + amounts first.
class PeerSwapScreen extends StatefulWidget {
  const PeerSwapScreen({super.key});

  @override
  State<PeerSwapScreen> createState() => _PeerSwapScreenState();
}

class _PeerSwapScreenState extends State<PeerSwapScreen> {
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _ctrAmountController = TextEditingController();
  final TextEditingController _peerController = TextEditingController();
  String _activeFilter = 'All';
  String? _chainFilter;
  String _historyFilter = 'All';
  bool _spvWired = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_spvWired) {
      _spvWired = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        try {
          SwapNotificationService.init(daemonManager.eventBus, context);
        } catch (_) {}
      });
    }
  }

  @override
  void dispose() {
    SwapNotificationService.dispose();
    _amountController.dispose();
    _ctrAmountController.dispose();
    _peerController.dispose();
    super.dispose();
  }

  void _warn(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppTheme.warningColor,
      ),
    );
  }

  void _initiateSwap(DexState state, String ticker) {
    final SwapPairSdk pair = state.selectedPair;
    final int? xfgAtomic = parseAtomic(_amountController.text.trim());
    if (xfgAtomic == null || xfgAtomic <= 0) {
      _warn('Enter the XFG amount (up to 7 decimals).');
      return;
    }
    // Both legs are explicit. Previously the counterparty amount was set to
    // the XFG atomic amount, which is a 1:1 raw-unit swap, not a priced one:
    // 1 XFG became 1e7 of the counterparty base unit (0.1 BTC).
    final int? ctrDecimals = ChainInfo.decimals[pair.ticker];
    if (ctrDecimals == null) {
      _warn('No decimals known for ${pair.ticker} — cannot size its leg.');
      return;
    }
    final int? ctrAtomic = parseAtomic(
      _ctrAmountController.text.trim(),
      decimals: ctrDecimals,
    );
    if (ctrAtomic == null || ctrAtomic <= 0) {
      // The daemon carries ctr_amount as a uint64, which on an 18-decimal
      // chain tops out around 9.22 tokens.
      final ceiling = ctrDecimals >= 18 ? ' and below 9.22' : '';
      _warn(
        'Enter the ${pair.ticker} amount you agreed with your counterparty '
        '(up to $ctrDecimals decimals$ceiling).',
      );
      return;
    }
    final String peer = _peerController.text.trim();
    if (peer.isEmpty) {
      _warn('Enter the peer endpoint your counterparty gave you.');
      return;
    }
    context.read<DexCubit>().initiateCrossChainSwap(
          // Daemon name, not the display ticker — swapPairFromString() does
          // not accept RHC/UNI/XPL/PLS/MON.
          pair: pair.daemonName,
          xfgAmount: xfgAtomic,
          ctrAmount: ctrAtomic,
          peer: peer,
        );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DexCubit, DexState>(
      builder: (BuildContext context, DexState state) {
        final String ticker = state.selectedPair.ticker;
        final List<SwapInfo> allActive =
            state.spvSwaps.where((SwapInfo s) => !s.isTerminal).toList();
        final List<SwapInfo> allHistory =
            state.spvSwaps.where((SwapInfo s) => s.isTerminal).toList();
        final List<SwapInfo> active = _filtered(allActive);
        final List<SwapInfo> history = _filtered(allHistory);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _whatIsThis(),
              const SizedBox(height: 16),
              _chainSelector(state),
              const SizedBox(height: 16),
              _form(state, ticker, allActive),
              if (state.lastResult != null) ...[
                const SizedBox(height: 12),
                _statusCard(state.lastResult!, false),
              ],
              if (state.error != null) ...[
                const SizedBox(height: 12),
                _statusCard(state.error!, true),
              ],
              if (allActive.isNotEmpty || allHistory.isNotEmpty) ...[
                const SizedBox(height: 16),
                _filterBar(),
              ],
              if (active.isNotEmpty) ...[
                const SizedBox(height: 16),
                _activeSection(active),
              ],
              if (history.isNotEmpty) ...[
                const SizedBox(height: 20),
                _historySection(history),
              ],
              if (allActive.isEmpty && allHistory.isEmpty) ...[
                const SizedBox(height: 20),
                const _EmptySwapsHint(),
              ],
            ],
          ),
        );
      },
    );
  }

  List<SwapInfo> _filtered(List<SwapInfo> swaps) {
    List<SwapInfo> out = swaps;
    if (_chainFilter != null) {
      out = out.where((SwapInfo s) => s.pairName == _chainFilter).toList();
    }
    if (_activeFilter == 'Active') {
      out = out.where((SwapInfo s) => !s.isTerminal).toList();
    } else if (_activeFilter == 'Landed') {
      out = out.where((SwapInfo s) => s.isLanded).toList();
    } else if (_activeFilter == 'History') {
      out = out.where((SwapInfo s) => s.isTerminal).toList();
    }
    return out;
  }

  Widget _whatIsThis() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.primaryColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.3)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.handshake_outlined,
                color: AppTheme.primaryColor,
                size: 18,
              ),
              SizedBox(width: 8),
              Text(
                'Direct peer swap',
                style: TextStyle(
                  color: AppTheme.primaryColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text(
            'This is for atomic swaps with a specific counterparty you already know. '
            'You must agree the amounts out-of-band and exchange endpoints first.\n\n'
            'To fill an open offer from the orderbook, use the Accept tab.',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chainSelector(DexState state) {
    return LayoutBuilder(
      builder: (context, constraints) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: ChainInfo.swapableChains.map((String t) {
        final bool selected = t == state.selectedPair.ticker;
        final Color color = ChainInfo.colors[t] ?? AppTheme.primaryColor;
        return GestureDetector(
          onTap: () {
            context.read<DexCubit>().selectPairById(t);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: selected ? color.withValues(alpha: 0.2) : AppTheme.cardColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: selected ? color : AppTheme.surfaceColor),
            ),
            child: Text(
              t,
              style: TextStyle(
                color: selected ? color : AppTheme.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        );
      }).toList(),
      ),
    );
  }

  Widget _filterBar() {
    const List<String> tabs = ['All', 'Active', 'Landed', 'History'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final String tab in tabs) ...[
                ChoiceChip(
                  label: Text(
                    tab,
                    style: TextStyle(
                      color: _activeFilter == tab
                          ? Colors.white
                          : AppTheme.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  selected: _activeFilter == tab,
                  selectedColor: AppTheme.primaryColor,
                  backgroundColor: AppTheme.cardColor,
                  side: BorderSide(
                    color: _activeFilter == tab
                        ? AppTheme.primaryColor
                        : AppTheme.surfaceColor,
                  ),
                  onSelected: (bool v) {
                    if (v) {
                      unawaited(HapticFeedback.selectionClick());
                      setState(() {
                        _activeFilter = tab;
                      });
                    }
                  },
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _chainFilterChip(null, 'All chains'),
            for (final String t in ChainInfo.swapableChains)
              _chainFilterChip(t, t),
          ],
        ),
      ],
    );
  }

  Widget _chainFilterChip(String? chain, String label) {
    final bool selected = _chainFilter == chain;
    final Color base = chain == null
        ? AppTheme.primaryColor
        : (ChainInfo.colors[chain] ?? AppTheme.primaryColor);
    return GestureDetector(
      onTap: () {
        unawaited(HapticFeedback.selectionClick());
        setState(() {
          _chainFilter = chain;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? base.withValues(alpha: 0.18) : AppTheme.cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? base : AppTheme.surfaceColor,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? base : AppTheme.textMuted,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _form(DexState state, String ticker, List<SwapInfo> active) {
    final bool connected = state.isSwapDaemonConnected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!connected)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: AppTheme.errorColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppTheme.errorColor.withValues(alpha: 0.3),
              ),
            ),
            child: const Row(
              children: [
                Icon(Icons.error_outline, color: AppTheme.errorColor, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'xfg-swapd not running — start it from Settings',
                    style: TextStyle(color: AppTheme.errorColor, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        TextField(
          controller: _amountController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'XFG Amount',
            labelStyle: const TextStyle(color: AppTheme.textSecondary),
            hintText: '100.00',
            hintStyle: TextStyle(
              color: AppTheme.textSecondary.withValues(alpha: 0.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(
                color: AppTheme.textSecondary.withValues(alpha: 0.3),
              ),
            ),
            focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: AppTheme.primaryColor),
            ),
          ),
          style: const TextStyle(color: AppTheme.textPrimary),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _ctrAmountController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: '$ticker Amount (agreed with your counterparty)',
            labelStyle: const TextStyle(color: AppTheme.textSecondary),
            hintText: '0.00',
            hintStyle: TextStyle(
              color: AppTheme.textSecondary.withValues(alpha: 0.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(
                color: AppTheme.textSecondary.withValues(alpha: 0.3),
              ),
            ),
            focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: AppTheme.primaryColor),
            ),
          ),
          style: const TextStyle(color: AppTheme.textPrimary),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _peerController,
          decoration: InputDecoration(
            labelText: 'Peer Endpoint (from your counterparty)',
            labelStyle: const TextStyle(color: AppTheme.textSecondary),
            hintText: '192.168.1.100:18901',
            hintStyle: TextStyle(
              color: AppTheme.textSecondary.withValues(alpha: 0.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(
                color: AppTheme.textSecondary.withValues(alpha: 0.3),
              ),
            ),
            focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: AppTheme.primaryColor),
            ),
          ),
          style: const TextStyle(color: AppTheme.textPrimary),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: (state.isSwapInitiating || !connected)
              ? null
              : () => _initiateSwap(state, ticker),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryColor,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: state.isSwapInitiating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text(
                  'INITIATE SWAP',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _statusCard(String text, bool isError) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: (isError ? AppTheme.errorColor : AppTheme.successColor).withValues(
          alpha: 0.1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: isError ? AppTheme.errorColor : AppTheme.successColor,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _activeSection(List<SwapInfo> active) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Active Swaps',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        for (final SwapInfo swap in active) ...[
          SwapCard(
            swap: swap,
            onTap: () => _showSwapDetail(swap),
            onAccept: swap.state == 'INITIATED'
                ? () => context.read<DexCubit>().acceptSwap(swap.swapId)
                : null,
            onRefund: !swap.isTerminal
                ? () => context.read<DexCubit>().refundSpvSwap(swap.swapId)
                : null,
            onInspect: swap.ctrLockTxId != null && swap.ctrLockTxId!.isNotEmpty
                ? () => _showSwapDetail(swap)
                : null,
          ),
          const SizedBox(height: 8),
          SwapTimelineStepper(swap: swap),
          const SizedBox(height: 8),
          ConfirmationCluster(
            chain: swap.pairName,
            confirmations: swap.confirmations,
            requiredConfirmations: swap.requiredConfirmations,
            spvVerified: swap.spvVerified,
            blockHeight: swap.blockHeight,
            txid: swap.ctrLockTxId,
            spvError: swap.spvError,
          ),
          const SizedBox(height: 12),
          const Divider(color: AppTheme.surfaceColor, height: 1),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _historySection(List<SwapInfo> history) {
    final List<SwapInfo> filteredHistory = _filteredHistory(history);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'History',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        _historyFilterChips(),
        const SizedBox(height: 12),
        for (final SwapInfo swap in filteredHistory) ...[
          if (swap.isFailedCommit) ...[
            FailureCard(
              swap: swap,
              onRefund: () {
                context.read<DexCubit>().refundSpvSwap(swap.swapId);
              },
              onRetry: () {
                context.read<DexCubit>().loadSpvSwaps();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Retrying SPV verification…'),
                    backgroundColor: AppTheme.infoColor,
                  ),
                );
              },
              onContact: () {
                unawaited(HapticFeedback.selectionClick());
                final String peer = swap.peerEndpoint;
                if (peer.isNotEmpty) {
                  Clipboard.setData(ClipboardData(text: peer));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Peer endpoint copied'),
                      backgroundColor: AppTheme.successColor,
                    ),
                  );
                }
              },
            ),
          ] else ...[
            Opacity(
              opacity: 0.9,
              child: SwapCard(
                swap: swap,
                onTap: () => _showSwapDetail(swap),
                onInspect: swap.ctrLockTxId != null && swap.ctrLockTxId!.isNotEmpty
                    ? () => _showSwapDetail(swap)
                    : null,
              ),
            ),
          ],
          const SizedBox(height: 8),
        ],
        if (filteredHistory.isEmpty) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.cardColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.surfaceColor),
            ),
            child: Row(
              children: [
                const Icon(Icons.filter_list_off, color: AppTheme.textMuted, size: 16),
                const SizedBox(width: 8),
                Text(
                  'No $_historyFilter swaps',
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  List<SwapInfo> _filteredHistory(List<SwapInfo> history) {
    List<SwapInfo> out = history;
    if (_historyFilter == 'Success') {
      out = out.where((SwapInfo s) {
        if (!s.isTerminal) {
          return false;
        }
        if (s.isFailedCommit) {
          return false;
        }
        // Success: completed claims
        if (s.state.contains('CLAIMED') || s.state.contains('SPENT')) {
          return true;
        }
        // Fallback: terminal but not refunded/failed
        if (!s.state.contains('REFUND') && !s.state.contains('FAILED')) {
          return true;
        }
        return false;
      }).toList();
    } else if (_historyFilter == 'Refunded') {
      out = out.where((SwapInfo s) {
        if (s.state.contains('REFUND')) {
          return true;
        }
        return false;
      }).toList();
    } else if (_historyFilter == 'Failed') {
      out = out.where((SwapInfo s) {
        if (s.state.contains('FAILED')) {
          return true;
        }
        // Also treat spvError-driven failures that are terminal but not refunded
        if (s.isFailedCommit && !s.state.contains('REFUND')) {
          return true;
        }
        return false;
      }).toList();
    }
    // Chain filter still applies inside history if set
    if (_chainFilter != null) {
      out = out.where((SwapInfo s) => s.pairName == _chainFilter).toList();
    }
    return out;
  }

  Widget _historyFilterChips() {
    const List<String> tabs = ['All', 'Success', 'Refunded', 'Failed'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final String tab in tabs) ...[
            ChoiceChip(
              label: Text(
                tab,
                style: TextStyle(
                  color: _historyFilter == tab ? Colors.white : AppTheme.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              selected: _historyFilter == tab,
              selectedColor: AppTheme.primaryColor,
              backgroundColor: AppTheme.cardColor,
              side: BorderSide(
                color: _historyFilter == tab ? AppTheme.primaryColor : AppTheme.surfaceColor,
              ),
              onSelected: (bool v) {
                if (v) {
                  unawaited(HapticFeedback.selectionClick());
                  setState(() {
                    _historyFilter = tab;
                  });
                }
              },
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  void _showSwapDetail(SwapInfo swap) {
    final bool isSuccess =
        swap.state == 'ADAPTOR_XFG_SPENT' || swap.state == 'AFK_CLAIMED';
    if (isSuccess) {
      unawaited(HapticFeedback.mediumImpact());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        showSuccessConfetti(context);
      });
    }
    final String ts = swap.updatedAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(swap.updatedAt * 1000)
            .toIso8601String()
        : '';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.72,
          minChildSize: 0.4,
          maxChildSize: 0.92,
          expand: false,
          builder: (BuildContext context, ScrollController scrollController) {
            return SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppTheme.textMuted.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Swap ${swap.swapId.length > 12 ? '${swap.swapId.substring(0, 12)}…' : swap.swapId}',
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'IBMPlexMono',
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          swap.displayState,
                          style: const TextStyle(
                            color: AppTheme.primaryColor,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (ts.isNotEmpty)
                    Text(
                      ts,
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 10,
                        fontFamily: 'IBMPlexMono',
                      ),
                    ),
                  const SizedBox(height: 16),
                  const Text(
                    'Timeline',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwapTimelineStepper(swap: swap),
                  const SizedBox(height: 16),
                  const Text(
                    'Confirmation',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ConfirmationCluster(
                    chain: swap.pairName,
                    confirmations: swap.confirmations,
                    requiredConfirmations: swap.requiredConfirmations,
                    spvVerified: swap.spvVerified,
                    blockHeight: swap.blockHeight,
                    txid: swap.ctrLockTxId,
                    spvError: swap.spvError,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Amounts & fees',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwapAmountRow(swap: swap),
                  const SizedBox(height: 16),
                  const Text(
                    'Timelock',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TimelockCountdown(
                    timeoutHeight: swap.timeoutHeight,
                    currentHeight: swap.currentHeight,
                    requiredConfirmations: swap.requiredConfirmations,
                    state: swap.state,
                    confirmations: swap.confirmations,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            showContractInspectorSheet(ctx, swap);
                          },
                          icon: const Icon(Icons.search, size: 16),
                          label: const Text(
                            'Inspect contract',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.primaryColor,
                            side: const BorderSide(color: AppTheme.primaryColor),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            showSwapReceiptSheet(ctx, swap);
                          },
                          icon: const Icon(Icons.receipt_long, size: 16),
                          label: const Text(
                            'Receipt',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.primaryColor,
                            side: const BorderSide(color: AppTheme.primaryColor),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (swap.ctrLockTxId != null && swap.ctrLockTxId!.isNotEmpty) ...[
                    const Text(
                      'Counterparty TX',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      swap.ctrLockTxId!,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 11,
                        fontFamily: 'IBMPlexMono',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          onPressed: () async {
                            unawaited(HapticFeedback.selectionClick());
                            await Clipboard.setData(
                              ClipboardData(text: swap.ctrLockTxId!),
                            );
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                  content: Text('Transaction ID copied'),
                                  backgroundColor: AppTheme.successColor,
                                ),
                              );
                            }
                          },
                          icon: const Icon(Icons.copy, size: 14),
                          label: const Text(
                            'Copy',
                            style: TextStyle(fontSize: 11),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.surfaceColor,
                            foregroundColor: AppTheme.textPrimary,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: () async {
                            unawaited(HapticFeedback.selectionClick());
                            final String? url = swap.explorerUrl;
                            if (url == null || url.isEmpty) {
                              return;
                            }
                            final Uri uri = Uri.parse(url);
                            final bool ok = await launchUrl(
                              uri,
                              mode: LaunchMode.externalApplication,
                            );
                            if (!ok && ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(
                                  content: Text('Could not open $url'),
                                  backgroundColor: AppTheme.errorColor,
                                ),
                              );
                            }
                          },
                          icon: const Icon(Icons.open_in_new, size: 14),
                          label: const Text(
                            'Explorer',
                            style: TextStyle(fontSize: 11),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryColor,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Pair: ${swap.pairName}  •  XFG ${swap.xfgAmountDecimal.toStringAsFixed(2)} → ${swap.ctrAmountDecimal?.toStringAsFixed(4) ?? '—'} ${swap.pairName}',
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (swap.state == 'INITIATED')
                        ElevatedButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            context.read<DexCubit>().acceptSwap(swap.swapId);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.successColor,
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Accept'),
                        ),
                      if (!swap.isTerminal)
                        OutlinedButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            context.read<DexCubit>().refundSpvSwap(swap.swapId);
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.errorColor,
                            side: const BorderSide(color: AppTheme.errorColor),
                          ),
                          child: const Text('Refund'),
                        ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text(
                          'Close',
                          style: TextStyle(color: AppTheme.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _EmptySwapsHint extends StatelessWidget {
  const _EmptySwapsHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.surfaceColor),
      ),
      child: const Row(
        children: [
          Icon(Icons.inbox_outlined, color: AppTheme.textMuted, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'No swaps yet — initiate one above or accept an offer from the Accept tab.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
