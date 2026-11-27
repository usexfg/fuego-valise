import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../../utils/theme.dart';

/// Terminal tokens for the portfolio sheet and DeXFG.
///
/// Deliberately not the maison palette. Gain/loss colors are never the only
/// signal — pair them with an arrow and a sign.
class TradingStyle {
  TradingStyle._();

  static const Color background = Color(0xFF0B0E11);
  static const Color panel = Color(0xFF12161C);
  static const Color hairline = Color(0xFF1E2630);
  static const Color text = Color(0xFFE8EDF2);
  static const Color muted = Color(0xFF8B95A1);
  static const Color gain = Color(0xFF16C784);
  static const Color loss = Color(0xFFEA3943);
  static const Color flat = Color(0xFF8B95A1);
  static const Color accent = Color(0xFF4C8DFF);

  static TextStyle figure({Color? color, double size = 13}) => TextStyle(
    color: color ?? text,
    fontSize: size,
    fontWeight: FontWeight.w500,
    height: 1.1,
    fontFamily: AppTheme.numberFontFamily,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  static TextStyle caption({Color? color, double size = 10}) => TextStyle(
    color: color ?? muted,
    fontSize: size,
    fontWeight: FontWeight.w500,
    height: 1.2,
    letterSpacing: 0.2,
  );

  static TextStyle ticker({Color? color, double size = 12.5}) => TextStyle(
    color: color ?? text,
    fontSize: size,
    fontWeight: FontWeight.w600,
    height: 1.1,
    letterSpacing: 0.4,
  );
}
