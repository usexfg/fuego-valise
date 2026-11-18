import 'package:flutter/material.dart';

import '../../models/portfolio.dart';
import '../../utils/theme.dart';
import 'portfolio_plate.dart';

/// The ΗΞΔŦ stratum: the stablecoin reserve that sits under the XFG dial.
///
/// White-flame figures with the glacial-aqua secondary are the ΗΞΔŦ
/// denomination marks (AppTheme.heatFlame / heatAqua), keeping the coin's
/// identity distinct from XFG champagne inside the same case.
class HeatPlate extends StatelessWidget {
  const HeatPlate({
    super.key,
    required this.total,
    required this.unlocked,
    required this.locked,
    required this.masked,
    this.available = true,
    this.pegUsd,
    this.onMint,
  });

  final double total;
  final double unlocked;
  final double locked;
  final bool masked;

  /// False when walletd cannot report ΗΞΔŦ (older build). The plate then shows
  /// an em dash and says why, instead of claiming an empty reserve.
  final bool available;

  /// Peg from the live price snapshot; null renders no valuation claim.
  final double? pegUsd;
  final VoidCallback? onMint;

  String _amount(double value) => !available
      ? '—'
      : masked
      ? '••••'
      : groupThousands(value.toStringAsFixed(4));

  double? get _valueUsd {
    if (!available) return null;
    final peg = pegUsd;
    if (peg == null || peg <= 0) return null;
    return total * peg;
  }

  bool get _held => available && total > 0;

  @override
  Widget build(BuildContext context) {
    final valueUsd = _valueUsd;
    return PortfolioPlate(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'ΗΞΔŦ',
                style: PortfolioStyle.label(
                  color: AppTheme.heatFlame.withValues(alpha: 0.9),
                  size: 10,
                  spacing: 2.5,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'RESERVE',
                style: PortfolioStyle.label(size: 8.5, spacing: 2.5),
              ),
              const Spacer(),
              if (valueUsd != null)
                Text(
                  masked ? '••••' : '≈ ${PortfolioStyle.usd(valueUsd)}',
                  style: PortfolioStyle.label(
                    size: 8.5,
                    spacing: 1.2,
                    color: AppTheme.heatAqua.withValues(alpha: 0.55),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _amount(total),
                style: TextStyle(
                  color: _held
                      ? AppTheme.heatFlame
                      : AppTheme.heatFlame.withValues(alpha: 0.45),
                  fontSize: 24,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                  letterSpacing: 0.2,
                  fontFamily: 'Cormorant',
                ),
              ),
              const Spacer(),
              if (onMint != null)
                GestureDetector(
                  onTap: onMint,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: AppTheme.heatAqua.withValues(
                          alpha: _held ? 0.2 : 0.4,
                        ),
                      ),
                    ),
                    child: Text(
                      _held ? 'ADD' : 'MINT',
                      style: PortfolioStyle.label(
                        size: 8,
                        spacing: 2,
                        color: AppTheme.heatAqua.withValues(
                          alpha: _held ? 0.55 : 0.9,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          const PortfolioHairline(opacity: 0.22),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _sub('UNLOCKED', unlocked)),
              Container(
                width: 1,
                height: 18,
                color: Colors.white.withValues(alpha: 0.07),
              ),
              const SizedBox(width: 10),
              Expanded(child: _sub('ON DEPOSIT', locked, alignEnd: true)),
            ],
          ),
          if (!available)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'ΗΞΔŦ balance not reported by this wallet build',
                style: PortfolioStyle.label(
                  size: 8,
                  spacing: 0.8,
                  color: Colors.white.withValues(alpha: 0.28),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sub(String label, double value, {bool alignEnd = false}) {
    return Row(
      mainAxisAlignment: alignEnd
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: [
        Text(label, style: PortfolioStyle.label(size: 8, spacing: 1.8)),
        const SizedBox(width: 6),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
            child: Text(
              _amount(value),
              style: PortfolioStyle.figure(
                size: 11.5,
                color: PortfolioStyle.platinum.withValues(alpha: 0.85),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
