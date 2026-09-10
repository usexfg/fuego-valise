import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/chain_info.dart';
import '../../services/swap_daemon_client.dart';
import '../../utils/theme.dart';
import '../../utils/xfg_ticker.dart';

/// Theatre card: chain icon, pair badge, lockType badge, amounts, status,
/// shortTxid, confirmation mini bar, and action buttons.
class SwapCard extends StatelessWidget {
  const SwapCard({
    super.key,
    required this.swap,
    required this.onTap,
    this.onRefund,
    this.onAccept,
    this.onInspect,
  });

  final SwapInfo swap;
  final VoidCallback onTap;
  final VoidCallback? onRefund;
  final VoidCallback? onAccept;
  final VoidCallback? onInspect;

  Color get _lockColor {
    final String name = swap.lockTypeName.toUpperCase();
    if (name == 'PTLC') {
      return AppTheme.primaryColor;
    }
    if (name == 'BRIDGE') {
      return AppTheme.primaryVariant;
    }
    return AppTheme.textMuted;
  }

  Color get _statusColor {
    if (swap.isTerminal) {
      if (swap.state.contains('REFUND') || swap.state.contains('FAILED')) {
        return AppTheme.warningColor;
      }
      return AppTheme.successColor;
    }
    if (swap.isLanded) {
      return AppTheme.successColor;
    }
    if (swap.isWaitingSpv || swap.isSecretConfirmedSpv) {
      return AppTheme.primaryColor;
    }
    return AppTheme.textSecondary;
  }

  Future<void> _copyShort(BuildContext context) async {
    final String? id = swap.ctrLockTxId;
    if (id == null || id.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: id));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Transaction ID copied'),
          backgroundColor: AppTheme.successColor,
        ),
      );
    }
  }

  Future<void> _openExplorer(BuildContext context) async {
    final String? url = swap.explorerUrl;
    if (url == null || url.isEmpty) {
      return;
    }
    final Uri uri = Uri.parse(url);
    final bool ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open $url'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final String pairName = swap.pairName;
    final Color chainColor = ChainInfo.colors[pairName] ?? AppTheme.primaryColor;
    final String? iconAsset = ChainInfo.icons[pairName];
    final Color lockColor = _lockColor;
    final String lockLabel = swap.lockTypeLabel.isEmpty ? 'HTLC' : swap.lockTypeLabel;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: swap.isTerminal
                ? AppTheme.surfaceColor
                : AppTheme.surfaceColor.withValues(alpha: 0.6),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: iconAsset != null
                      ? Image.asset(
                          iconAsset,
                          width: 28,
                          height: 28,
                          errorBuilder: (BuildContext c, Object e, StackTrace? s) {
                            return _fallbackIcon(pairName, chainColor);
                          },
                        )
                      : _fallbackIcon(pairName, chainColor),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: chainColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: chainColor.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      pairName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: chainColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: lockColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: lockColor, width: 0.8),
                  ),
                  child: Text(
                    lockLabel,
                    style: TextStyle(
                      color: lockColor,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    swap.displayState,
                    style: TextStyle(
                      color: _statusColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Flexible(
                  child: xfgAmount(
                    swap.xfgAmountDecimal.toStringAsFixed(2),
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    '→',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                  ),
                ),
                Expanded(
                  child: Text(
                    '${swap.ctrAmountDecimal.toStringAsFixed(4)} $pairName',
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'ID: ${swap.swapId.length > 12 ? '${swap.swapId.substring(0, 12)}…' : swap.swapId}',
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                      fontFamily: 'IBMPlexMono',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (swap.ctrLockTxId != null && swap.ctrLockTxId!.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => _copyShort(context),
                    onLongPress: () => _openExplorer(context),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            swap.shortTxid,
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 10,
                              fontFamily: 'IBMPlexMono',
                              decoration: TextDecoration.underline,
                              decorationColor: AppTheme.textSecondary,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.open_in_new,
                            size: 10,
                            color: AppTheme.textMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (swap.isCommitSeen) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: swap.confirmationProgress,
                  minHeight: 3,
                  backgroundColor: AppTheme.surfaceColor,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    swap.isLanded ? AppTheme.successColor : AppTheme.primaryColor,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                swap.isLanded
                    ? 'Landed ${swap.confirmations}/${swap.requiredConfirmations} — SPV verified'
                    : swap.confirmations == 0
                        ? 'Seen in mempool — 0/${swap.requiredConfirmations}'
                        : '${swap.confirmations}/${swap.requiredConfirmations} confirmations',
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 10,
                ),
              ),
            ],
            if (onAccept != null || onRefund != null || onInspect != null) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (onAccept != null)
                    ElevatedButton(
                      onPressed: onAccept,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.successColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text(
                        'Accept',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                      ),
                    ),
                  if (onRefund != null)
                    OutlinedButton(
                      onPressed: onRefund,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.errorColor,
                        side: const BorderSide(color: AppTheme.errorColor),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text(
                        'Refund',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                      ),
                    ),
                  if (onInspect != null)
                    TextButton(
                      onPressed: onInspect,
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.primaryColor,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        'Inspect',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _fallbackIcon(String pairName, Color chainColor) {
    final String letters = pairName.length >= 2 ? pairName.substring(0, 2) : pairName;
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: chainColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: chainColor.withValues(alpha: 0.3)),
      ),
      child: Center(
        child: Text(
          letters,
          style: TextStyle(
            color: chainColor,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}
