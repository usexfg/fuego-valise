import 'package:flutter/material.dart';
import '../../models/chain_info.dart';
import '../../services/swap_daemon_client.dart';
import '../../utils/theme.dart';
import '../../utils/xfg_ticker.dart';

class SwapAmountRow extends StatelessWidget {
  const SwapAmountRow({super.key, required this.swap});

  final SwapInfo swap;

  String _formatCtr(double? amount, String ticker) {
    if (amount == null) return '—';
    final int? dec = ChainInfo.decimals[ticker];
    if (dec == null) return '—';
    final int frac;
    if (dec >= 18) {
      frac = 6;
    } else if (dec == 8) {
      frac = 6;
    } else if (dec == 9) {
      frac = 5;
    } else if (dec == 12) {
      frac = 4;
    } else {
      frac = 4;
    }
    return amount.toStringAsFixed(frac);
  }

  void _showFeeSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
                const Text(
                  'Protocol fee — 1%',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Every atomic swap pays a flat 1% protocol fee, split transparently:',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                // SWAP_FEE_RATE_BPS = 100 (1% of the claim/refund amount),
                // split SWAP_FEE_CD_SHARE_PCT 69 / SWAP_FEE_BONUS_VAULT_PCT 11
                // / SWAP_FEE_TREASURY_SHARE_PCT 20 (CryptoNoteConfig.h:148-197).
                // This is the ATOMIC SWAP split. Hearth's is a different fee
                // and a different split — HEARTH_FEE_BPS 100, 70/30.
                _feeSplitRow('69%', 'CD yield', AppTheme.primaryColor),
                const SizedBox(height: 6),
                _feeSplitRow('11%', 'Bonus vault', AppTheme.successColor),
                const SizedBox(height: 6),
                _feeSplitRow('20%', 'Treasury reserve', AppTheme.warningColor),
                const SizedBox(height: 12),
                const Text(
                  'The fee is taken from the XFG leg. Counterparty-chain network fees are separate and shown when the daemon reports them.',
                  style: TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.surfaceColor,
                      foregroundColor: AppTheme.textPrimary,
                    ),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final String pairName = swap.pairName;
    final double xfgDec = swap.xfgAmountDecimal;
    final double? ctrDec = swap.ctrAmountDecimal;
    final String xfgStr = xfgDec.toStringAsFixed(2);
    final String ctrStr = _formatCtr(ctrDec, pairName);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'You send',
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  xfgAmount(
                    xfgStr,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(
                Icons.arrow_forward,
                size: 16,
                color: AppTheme.textMuted,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text(
                    'You receive',
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$ctrStr $pairName',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        InkWell(
          onTap: () {
            _showFeeSheet(context);
          },
          borderRadius: BorderRadius.circular(6),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 12,
                  color: AppTheme.textMuted,
                ),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Protocol fee 1% (69% CD yield / 11% bonus / 20% treasury)',
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                      height: 1.3,
                    ),
                  ),
                ),
                Icon(
                  Icons.open_in_new,
                  size: 10,
                  color: AppTheme.textMuted,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        const Row(
          children: [
            Icon(
              Icons.landscape_outlined,
              size: 12,
              color: AppTheme.textMuted,
            ),
            SizedBox(width: 6),
            Expanded(
              child: Text(
                '~ network fee from daemon when available',
                style: TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

Widget _feeSplitRow(String pct, String label, Color color) {
  return Row(
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
      ),
      const SizedBox(width: 8),
      Text(
        pct,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(width: 8),
      Text(
        label,
        style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    ],
  );
}
