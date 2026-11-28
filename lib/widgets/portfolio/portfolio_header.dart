import 'package:flutter/material.dart';

import '../../models/portfolio.dart';
import 'portfolio_plate.dart';

/// Chapter heading for the portfolio: one figure for everything the wallet can
/// price today (XFG + ΗΞΔŦ), and a short count of what it holds.
///
/// Deliberately unframed — the heading names the page, the dials below are the
/// instruments.
class PortfolioHeader extends StatelessWidget {
  const PortfolioHeader({
    super.key,
    required this.valuation,
    required this.masked,
    required this.heldChainCount,
    required this.isRefreshing,
    this.priceError,
    this.onRefresh,
  });

  final PortfolioValuation valuation;
  final bool masked;
  final int heldChainCount;
  final bool isRefreshing;
  final String? priceError;
  final VoidCallback? onRefresh;

  String get _figure {
    if (masked) return '••••••';
    if (!valuation.isPriced) return '—';
    return PortfolioStyle.usd(valuation.totalUsd);
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = !valuation.isPriced
        ? (priceError ?? 'Waiting for the live Hearth price')
        : !valuation.heatKnown
        ? 'XFG priced · ΗΞΔŦ balance unreadable'
        : (heldChainCount == 0
              ? 'XFG + ΗΞΔŦ priced · no chain assets yet'
              : 'XFG + ΗΞΔŦ priced · $heldChainCount chain${heldChainCount == 1 ? '' : 's'} held');

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'PORTFOLIO',
                style: PortfolioStyle.label(
                  color: PortfolioStyle.champagne.withValues(alpha: 0.8),
                  size: 10,
                  spacing: 4,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 3,
                height: 3,
                decoration: BoxDecoration(
                  color: valuation.isPriced
                      ? PortfolioStyle.champagne.withValues(alpha: 0.9)
                      : Colors.white.withValues(alpha: 0.25),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                valuation.isPriced ? 'LIVE' : 'UNPRICED',
                style: PortfolioStyle.label(
                  size: 8,
                  spacing: 2,
                  color: valuation.isPriced
                      ? PortfolioStyle.champagne.withValues(alpha: 0.55)
                      : Colors.white.withValues(alpha: 0.3),
                ),
              ),
              const Spacer(),
              if (isRefreshing)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      PortfolioStyle.champagne.withValues(alpha: 0.6),
                    ),
                  ),
                )
              else if (onRefresh != null)
                GestureDetector(
                  onTap: onRefresh,
                  behavior: HitTestBehavior.opaque,
                  child: Icon(
                    Icons.refresh,
                    size: 15,
                    color: PortfolioStyle.champagne.withValues(alpha: 0.5),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _figure,
                style: TextStyle(
                  color: PortfolioStyle.platinum.withValues(alpha: 0.96),
                  fontSize: 26,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                  letterSpacing: 0.2,
                  fontFamily: 'Cormorant',
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (valuation.isPriced) ...[
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    'EST.',
                    style: PortfolioStyle.label(
                      size: 8,
                      spacing: 2,
                      color: PortfolioStyle.champagne.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: PortfolioStyle.label(
              size: 8.5,
              spacing: 1.4,
              color: Colors.white.withValues(alpha: 0.32),
            ),
          ),
        ],
      ),
    );
  }
}
