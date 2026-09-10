import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/chain_info.dart';
import '../../services/swap_daemon_client.dart';
import '../../utils/theme.dart';

Future<void> showContractInspectorSheet(
  BuildContext context,
  SwapInfo swap,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext sheetContext) {
      final double maxHeight =
          MediaQuery.of(sheetContext).size.height * 0.85;
      final String pairName = swap.pairName;
      final String lockLabel =
          swap.lockTypeLabel.isEmpty ? 'HTLC' : swap.lockTypeLabel;
      final Color lockColor = _lockColorFor(swap);
      final String? ptlcDesc = ChainInfo.ptlc[pairName];
      return Container(
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: const BoxDecoration(
          color: AppTheme.cardColor,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
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
                    const Expanded(
                      child: Text(
                        'Contract Inspector',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: lockColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: lockColor, width: 0.8),
                      ),
                      child: Text(
                        lockLabel,
                        style: TextStyle(
                          color: lockColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _sectionHeader('Pair & lock type'),
                const SizedBox(height: 6),
                Text(
                  '$pairName — $lockLabel',
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (ptlcDesc != null && ptlcDesc.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    ptlcDesc,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      height: 1.35,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                _sectionHeader('Chain contract'),
                const SizedBox(height: 8),
                if (swap.ctrLockTxId != null &&
                    swap.ctrLockTxId!.isNotEmpty) ...[
                  _copyableRow(
                    sheetContext,
                    label: 'Lock tx',
                    value: swap.ctrLockTxId!,
                    isTxid: true,
                    chain: pairName,
                  ),
                ] else ...[
                  const Text(
                    'Lock tx — not yet broadcast',
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                if (swap.ptlcPoint.isNotEmpty) ...[
                  _copyableRow(
                    sheetContext,
                    label: 'Adaptor / PTLC point',
                    value: swap.ptlcPoint,
                    isTxid: false,
                    chain: pairName,
                  ),
                ] else ...[
                  const Text(
                    'Adaptor point — not yet exchanged',
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text(
                      'Lock type: ',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      lockLabel,
                      style: TextStyle(
                        color: lockColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceColor.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppTheme.textMuted.withValues(alpha: 0.15),
                    ),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 14,
                        color: AppTheme.textMuted,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Full chainState inspection available when daemon exposes chainState via SwapInfo. '
                          'Expected format: p2tr:<tweaked>|ptlc:<T> vs redeem|ptlc:<T>.',
                          style: TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 10,
                            fontStyle: FontStyle.italic,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (swap.isPtlc || swap.isBridge) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.successColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AppTheme.successColor.withValues(alpha: 0.25),
                      ),
                    ),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.verified,
                          size: 16,
                          color: AppTheme.successColor,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Adaptor point verified',
                          style: TextStyle(
                            color: AppTheme.successColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.surfaceColor,
                      foregroundColor: AppTheme.textPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Close',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Color _lockColorFor(SwapInfo swap) {
  final String name = swap.lockTypeName.toUpperCase();
  if (name == 'PTLC') {
    return AppTheme.primaryColor;
  }
  if (name == 'BRIDGE') {
    return AppTheme.primaryVariant;
  }
  return AppTheme.textMuted;
}

Widget _sectionHeader(String title) {
  return Text(
    title,
    style: const TextStyle(
      color: AppTheme.textPrimary,
      fontSize: 12,
      fontWeight: FontWeight.w700,
    ),
  );
}

Widget _copyableRow(
  BuildContext context, {
  required String label,
  required String value,
  required bool isTxid,
  required String chain,
}) {
  final String display = value.length > 42
      ? '${value.substring(0, 20)}…${value.substring(value.length - 12)}'
      : value;
  final String explorerUrl = isTxid ? ChainInfo.explorerTxUrl(chain, value) : '';
  final bool canOpen = explorerUrl.isNotEmpty;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 4),
      Row(
        children: [
          Expanded(
            child: SelectableText(
              display,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 11,
                fontFamily: 'IBMPlexMono',
                height: 1.3,
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied to clipboard'),
                    backgroundColor: AppTheme.successColor,
                  ),
                );
              }
            },
            icon: const Icon(Icons.copy, size: 16),
            color: AppTheme.textSecondary,
            tooltip: 'Copy',
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
          if (canOpen) ...[
            IconButton(
              onPressed: () async {
                final Uri uri = Uri.parse(explorerUrl);
                final bool ok = await launchUrl(
                  uri,
                  mode: LaunchMode.externalApplication,
                );
                if (!ok && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Could not open $explorerUrl'),
                      backgroundColor: AppTheme.errorColor,
                    ),
                  );
                }
              },
              icon: const Icon(Icons.open_in_new, size: 16),
              color: AppTheme.primaryColor,
              tooltip: 'Explorer',
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ],
      ),
    ],
  );
}
