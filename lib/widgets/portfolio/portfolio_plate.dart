import 'package:flutter/material.dart';

import '../../models/portfolio.dart';
import '../../utils/theme.dart';
import '../maison_guilloche.dart';

/// House tokens for the wallet portfolio strata.
///
/// The XFG dial, the ΗΞΔŦ reserve and the chain drawer must read as one
/// instrument, so they share one bezel, one hairline and one label voice.
class PortfolioStyle {
  PortfolioStyle._();

  static const Color obsidian = Color(0xFF0D0B08);
  static const Color plaque = Color(0xFF141417);
  static const Color champagne = Color(0xFFC5A059);
  static const Color champagneLight = Color(0xFFD4B896);
  static const Color mutedGold = Color(0xFF8C734B);
  static const Color platinum = Color(0xFFF5F1E8);

  static const List<Color> fireStops = [
    Color(0xFF8C734B),
    Color(0xFFC5A059),
    Color(0xFFD4B896),
    Color(0xFF8C734B),
  ];

  static const LinearGradient fireLine = LinearGradient(colors: fireStops);

  /// Micro-caps label — letterspaced, never bold, never loud.
  static TextStyle label({Color? color, double size = 9, double spacing = 3}) =>
      TextStyle(
        color: color ?? Colors.white.withValues(alpha: 0.38),
        fontSize: size,
        fontWeight: FontWeight.w600,
        letterSpacing: spacing,
        height: 1.2,
      );

  /// Tabular figure style for amounts.
  static TextStyle figure({Color? color, double size = 14}) => TextStyle(
    color: color ?? platinum.withValues(alpha: 0.92),
    fontSize: size,
    fontWeight: FontWeight.w500,
    height: 1.2,
    fontFamily: AppTheme.numberFontFamily,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  /// Hearth pool price chip — `≋ $1.58`, grouped once past a thousand.
  static String usd(double value, {int decimals = 2}) {
    if (!value.isFinite) return '—';
    return '\$${groupThousands(value.toStringAsFixed(decimals))}';
  }
}

/// Obsidian plate with the house fire bezel, an optional guilloché ground and
/// an optional tap target.
class PortfolioPlate extends StatelessWidget {
  const PortfolioPlate({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(20, 16, 20, 18),
    this.radius = 18,
    this.guilloche = false,
    this.glow = false,
    this.onTap,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final bool guilloche;
  final bool glow;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final inner = radius - 0.8;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: glow ? 0.5 : 0.32),
            blurRadius: glow ? 24 : 16,
            offset: Offset(0, glow ? 12 : 8),
          ),
        ],
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            for (final c in PortfolioStyle.fireStops) c.withValues(alpha: 0.42),
            PortfolioStyle.fireStops.first.withValues(alpha: 0.42),
          ],
        ),
      ),
      padding: const EdgeInsets.all(0.8),
      child: Container(
        decoration: BoxDecoration(
          color: PortfolioStyle.obsidian,
          borderRadius: BorderRadius.circular(inner),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(inner),
          child: Stack(
            children: [
              if (guilloche)
                const Positioned.fill(
                  child: CustomPaint(painter: MaisonGuillochePainter()),
                ),
              GestureDetector(
                onTap: onTap,
                behavior: HitTestBehavior.opaque,
                child: Padding(padding: padding, child: child),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hairline fire rule used between strata and rows.
class PortfolioHairline extends StatelessWidget {
  const PortfolioHairline({super.key, this.opacity = 0.35});

  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      decoration: BoxDecoration(
        gradient: PortfolioStyle.fireLine.withOpacity(opacity),
      ),
    );
  }
}
