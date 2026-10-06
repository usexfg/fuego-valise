import 'package:flutter/material.dart';
import '../../utils/theme.dart';

class TimelockCountdown extends StatelessWidget {
  const TimelockCountdown({
    super.key,
    required this.timeoutHeight,
    required this.currentHeight,
    required this.requiredConfirmations,
    required this.state,
    required this.confirmations,
  });

  final int? timeoutHeight;
  final int? currentHeight;
  final int requiredConfirmations;
  final String state;
  final int? confirmations;

  bool get _isTerminal {
    const Set<String> terminal = {
      'ADAPTOR_XFG_SPENT',
      'ADAPTOR_REFUNDED',
      'AFK_CLAIMED',
      'AFK_REFUNDED',
      'FAILED',
      'XFG_REFUNDED',
      'XFG_CLAIMED',
      'CTR_CLAIMED',
      'CTR_REFUNDED',
    };
    if (terminal.contains(state)) {
      return true;
    }
    return false;
  }

  bool get _isFailed {
    if (state.contains('FAILED')) {
      return true;
    }
    if (state.contains('REFUND')) {
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (timeoutHeight == null || currentHeight == null) {
      return const Text(
        'Timelock — awaiting heights',
        style: TextStyle(
          color: AppTheme.textMuted,
          fontSize: 11,
          fontStyle: FontStyle.italic,
        ),
      );
    }
    final int th = timeoutHeight!;
    final int ch = currentHeight!;
    final int remaining = th - ch;
    final bool isRefundable = remaining <= 0;
    final Color urgency;
    if (remaining < 10) {
      urgency = AppTheme.errorColor;
    } else if (remaining < 50) {
      urgency = AppTheme.warningColor;
    } else {
      urgency = AppTheme.primaryColor;
    }
    final double progress;
    if (th <= 0) {
      progress = 0.0;
    } else {
      final double raw = (th - remaining) / th;
      if (raw < 0.0) {
        progress = 0.0;
      } else if (raw > 1.0) {
        progress = 1.0;
      } else {
        progress = raw;
      }
    }
    final String headline;
    if (isRefundable) {
      headline = 'Refundable now';
    } else {
      headline = 'XFG refundable in $remaining blocks';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.hourglass_bottom, size: 14, color: urgency),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                headline,
                style: TextStyle(
                  color: urgency,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            backgroundColor: AppTheme.surfaceColor,
            valueColor: AlwaysStoppedAnimation<Color>(urgency),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Counterparty must commit before you can refund — CTR timeout is before XFG timeout (safe gap).',
          style: TextStyle(
            color: AppTheme.textMuted,
            fontSize: 10,
            height: 1.35,
            fontStyle: FontStyle.italic,
          ),
        ),
        if (_isTerminal && _isFailed) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.warningColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: AppTheme.warningColor.withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.replay,
                  size: 12,
                  color: AppTheme.warningColor,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    state == 'ADAPTOR_REFUNDED' || state == 'AFK_REFUNDED'
                        ? 'Refunded — funds returned via timelock'
                        : 'Terminal — $state',
                    style: const TextStyle(
                      color: AppTheme.warningColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
