import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/swap_daemon_client.dart';
import '../../utils/theme.dart';

enum FailureCause {
  reorg,
  timeout,
  headerPruned,
  notConfigured,
  dust,
  peerOffline,
  spvFailed,
}

FailureCause _cause(SwapInfo swap) {
  final String state = swap.state;
  final String err = (swap.spvError ?? '').toLowerCase();
  final String stateLower = state.toLowerCase();
  if (state.contains('FAILED') && err.contains('reorg')) {
    return FailureCause.reorg;
  }
  if (err.contains('timeout') ||
      state == 'ADAPTOR_REFUNDED' ||
      state == 'AFK_REFUNDED') {
    return FailureCause.timeout;
  }
  if (err.contains('not found') || err.contains('header pruned')) {
    return FailureCause.headerPruned;
  }
  if (err.contains('chain client not configured')) {
    return FailureCause.notConfigured;
  }
  if (err.contains('insufficient') || err.contains('amount')) {
    return FailureCause.dust;
  }
  if (err.contains('peer') ||
      err.contains('offline') ||
      stateLower.contains('offline')) {
    return FailureCause.peerOffline;
  }
  return FailureCause.spvFailed;
}

String _causeLabel(FailureCause cause) {
  switch (cause) {
    case FailureCause.reorg:
      return 'reorg';
    case FailureCause.timeout:
      return 'timeout';
    case FailureCause.headerPruned:
      return 'header pruned';
    case FailureCause.notConfigured:
      return 'not configured';
    case FailureCause.dust:
      return 'dust';
    case FailureCause.peerOffline:
      return 'peer offline';
    case FailureCause.spvFailed:
      return 'spv failed';
  }
}

String _causeDescription(FailureCause cause) {
  switch (cause) {
    case FailureCause.reorg:
      return 'Chain reorg detected — confirmation was rolled back. Retry verification.';
    case FailureCause.timeout:
      return 'Swap timed out — XFG escrow refunded via timelock.';
    case FailureCause.headerPruned:
      return 'Header pruned or not found — daemon cannot verify SPV. Try again or resync.';
    case FailureCause.notConfigured:
      return 'Chain client not configured — start xfg-swapd with --swap-config.';
    case FailureCause.dust:
      return 'Amount too small (dust) or below chain minimum — check fee + dust limit.';
    case FailureCause.peerOffline:
      return 'Peer offline — counterparty unreachable.';
    case FailureCause.spvFailed:
      return 'SPV verification failed — check daemon logs or retry.';
  }
}

bool _isRefundedState(String state) {
  if (state.contains('REFUND')) {
    return true;
  }
  return false;
}

class FailureCard extends StatelessWidget {
  const FailureCard({
    super.key,
    required this.swap,
    required this.onRefund,
    this.onRetry,
    this.onContact,
  });

  final SwapInfo swap;
  final VoidCallback onRefund;
  final VoidCallback? onRetry;
  final VoidCallback? onContact;

  @override
  Widget build(BuildContext context) {
    final FailureCause cause = _cause(swap);
    final String causeLabel = _causeLabel(cause);
    final String description = _causeDescription(cause);
    final bool refunded = _isRefundedState(swap.state);
    final String title = refunded
        ? 'Refunded \u2014 $causeLabel'
        : 'Failed \u2014 $causeLabel';
    final bool hasError = swap.spvError != null && swap.spvError!.isNotEmpty;
    final Color iconColor = refunded
        ? AppTheme.warningColor
        : AppTheme.errorColor;
    const IconData iconData = Icons.error_outline;
    final bool isRefundable = _checkRefundable();
    final int? remaining = _remainingBlocks();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: refunded
              ? AppTheme.warningColor.withValues(alpha: 0.3)
              : AppTheme.errorColor.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(iconData, color: iconColor, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                    if (hasError) ...[
                      const SizedBox(height: 8),
                      SelectableText(
                        swap.spvError!,
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 10,
                          fontFamily: 'IBMPlexMono',
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton(
                onPressed: isRefundable ? onRefund : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.errorColor,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppTheme.surfaceColor,
                  disabledForegroundColor: AppTheme.textMuted,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  minimumSize: const Size(0, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: Text(
                  isRefundable
                      ? 'Refund'
                      : remaining != null
                      ? 'Refundable in $remaining blocks'
                      : 'Refund \u2014 awaiting heights',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (onRetry != null) ...[
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.primaryColor,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Retry verify',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
              if (onContact != null) ...[
                TextButton(
                  onPressed: () {
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
                    onContact!.call();
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.textSecondary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Contact peer',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ],
          ),
          if (!isRefundable && remaining != null) ...[
            const SizedBox(height: 8),
            Text(
              'Current ${swap.currentHeight} / timeout ${swap.timeoutHeight} — $remaining blocks remaining.',
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 10,
                fontStyle: FontStyle.italic,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }

  bool _checkRefundable() {
    final int? ch = swap.currentHeight;
    final int? th = swap.timeoutHeight;
    if (ch == null || th == null) {
      return false;
    }
    if (ch >= th) {
      return true;
    }
    return false;
  }

  int? _remainingBlocks() {
    final int? ch = swap.currentHeight;
    final int? th = swap.timeoutHeight;
    if (ch == null || th == null) {
      return null;
    }
    final int rem = th - ch;
    if (rem <= 0) {
      return 0;
    }
    return rem;
  }
}
