import 'package:flutter/material.dart';

/// The Fuego mark (`assets/logo/fuegologo.png`).
///
/// Brand surfaces use this instead of the Material fire icon. The HEAT
/// screen keeps its own mark.
class FuegoLogo extends StatelessWidget {
  const FuegoLogo({super.key, this.size = 96, this.fit = BoxFit.contain});

  final double size;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/logo/fuegologo.png',
      width: size,
      height: size,
      fit: fit,
      filterQuality: FilterQuality.high,
    );
  }
}
