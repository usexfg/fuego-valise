import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/swap_daemon_client.dart';
import '../../utils/theme.dart';

class SwapReceipt {
  const SwapReceipt({
    required this.swapId,
    required this.pairName,
    required this.state,
    required this.displayState,
    required this.xfgAmountDecimal,
    required this.ctrAmountDecimal,
    required this.lockTypeName,
    required this.ptlcPoint,
    required this.ctrLockTxId,
    required this.confirmations,
    required this.requiredConfirmations,
    required this.blockHeight,
    required this.spvVerified,
    required this.currentHeight,
    required this.peerEndpoint,
    required this.createdAt,
    required this.updatedAt,
    required this.timeoutHeight,
    required this.explorerUrl,
  });

  final String swapId;
  final String pairName;
  final String state;
  final String displayState;
  final double xfgAmountDecimal;
  final double? ctrAmountDecimal;
  final String lockTypeName;
  final String ptlcPoint;
  final String? ctrLockTxId;
  final int confirmations;
  final int requiredConfirmations;
  final int blockHeight;
  final bool spvVerified;
  final int? currentHeight;
  final String peerEndpoint;
  final int createdAt;
  final int updatedAt;
  final int? timeoutHeight;
  final String? explorerUrl;

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> map = <String, dynamic>{
      'swapId': swapId,
      'pairName': pairName,
      'state': state,
      'displayState': displayState,
      'xfgAmountDecimal': xfgAmountDecimal,
      'ctrAmountDecimal': ctrAmountDecimal,
      'lockTypeName': lockTypeName,
      'ptlcPoint': ptlcPoint,
      'ctrLockTxId': ctrLockTxId,
      'confirmations': confirmations,
      'requiredConfirmations': requiredConfirmations,
      'blockHeight': blockHeight,
      'spvVerified': spvVerified,
      'currentHeight': currentHeight,
      'peerEndpoint': peerEndpoint,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'timeoutHeight': timeoutHeight,
      'explorerUrl': explorerUrl,
    };
    return map;
  }
}

Map<String, dynamic> buildReceipt(SwapInfo swap) {
  final SwapReceipt receipt = SwapReceipt(
    swapId: swap.swapId,
    pairName: swap.pairName,
    state: swap.state,
    displayState: swap.displayState,
    xfgAmountDecimal: swap.xfgAmountDecimal,
    ctrAmountDecimal: swap.ctrAmountDecimal,
    lockTypeName: swap.lockTypeName,
    ptlcPoint: swap.ptlcPoint,
    ctrLockTxId: swap.ctrLockTxId,
    confirmations: swap.confirmations,
    requiredConfirmations: swap.requiredConfirmations,
    blockHeight: swap.blockHeight,
    spvVerified: swap.spvVerified,
    currentHeight: swap.currentHeight,
    peerEndpoint: swap.peerEndpoint,
    createdAt: swap.createdAt,
    updatedAt: swap.updatedAt,
    timeoutHeight: swap.timeoutHeight,
    explorerUrl: swap.explorerUrl,
  );
  final Map<String, dynamic> json = receipt.toJson();
  return json;
}

Future<void> showSwapReceiptSheet(BuildContext context, SwapInfo swap) async {
  final Map<String, dynamic> receiptMap = buildReceipt(swap);
  final String pretty = const JsonEncoder.withIndent('  ').convert(receiptMap);
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.cardColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    isScrollControlled: true,
    builder: (BuildContext ctx) {
      return DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (BuildContext context, ScrollController scrollController) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                const Text(
                  'Swap Receipt',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  swap.swapId,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 10,
                    fontFamily: 'IBMPlexMono',
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceColor.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.surfaceColor),
                    ),
                    child: SingleChildScrollView(
                      controller: scrollController,
                      child: SelectableText(
                        pretty,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 10,
                          fontFamily: 'IBMPlexMono',
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: pretty));
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(
                                content: Text('Receipt JSON copied'),
                                backgroundColor: AppTheme.successColor,
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text(
                          'Copy JSON',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.surfaceColor,
                          foregroundColor: AppTheme.textPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          // share_plus not in pubspec.yaml — fallback to copy + SnackBar.
                          // If share_plus is later added, replace this branch with:
                          // await Share.share(pretty, subject: 'Swap ${swap.swapId} receipt');
                          await Clipboard.setData(ClipboardData(text: pretty));
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(
                                content: Text('Receipt copied — share via clipboard (share_plus not installed)'),
                                backgroundColor: AppTheme.infoColor,
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.share, size: 16),
                        label: const Text(
                          'Share',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
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

class SwapReceiptButton extends StatelessWidget {
  const SwapReceiptButton({
    super.key,
    required this.swap,
  });

  final SwapInfo swap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () {
        showSwapReceiptSheet(context, swap);
      },
      icon: const Icon(Icons.receipt_long, size: 16),
      label: const Text(
        'Receipt',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.primaryColor,
        side: const BorderSide(color: AppTheme.primaryColor),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
