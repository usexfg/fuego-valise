import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// XFG ticker display style.
///
/// '' renders the classic trailing-ticker convention (`123.45 XFG`).
/// A glyph family renders the ₲ sign (U+20B2, present in every bundled
/// glyph font) as a PREFIX on XFG amounts — exactly like $ on USD — and
/// suppresses the redundant trailing ticker: `₲123.45`, never `₲123.45 XFG`.
///
/// Labels, pair names and prose keep the literal 'XFG' text; only
/// [xfgAmount] call sites participate in glyph styling.
class XfgTicker {
  XfgTicker._();
  static const prefKey = 'xfg_ticker_font';
  static const glyph = '\u20B2';

  /// Glyph font family, or '' for the plain-text convention.
  static String font = '';

  static const options = <({String family, String label, String? note})>[
    (family: '', label: 'XFG · trailing ticker', note: 'Classic · default'),
    (family: 'CormorantSC', label: '₲ Cormorant SC', note: 'Small-cap serif'),
    (family: 'UnicaOne', label: '₲ Unica One', note: 'Condensed display'),
    (family: 'Fahkwang', label: '₲ Fahkwang', note: 'Thai-latin sans'),
    (family: 'CrimsonPro', label: '₲ Crimson Pro', note: 'Old-style serif'),
    (family: 'TiltPrism', label: '₲ Tilt Prism', note: 'Prismatic 3D'),
  ];

  static bool get isGlyph => font.isNotEmpty;

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(prefKey) ?? '';
      font = options.any((o) => o.family == saved) ? saved : '';
    } catch (_) {
      font = '';
    }
  }

  static Future<void> set(String family) async {
    font = options.any((o) => o.family == family) ? family : '';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefKey, font);
    } catch (_) {}
  }

  /// Optical size compensation — most glyph faces run small next to
  /// lining figures; Fahkwang is the odd one out (full x-height).
  static double glyphScale(String family) => switch (family) {
        'Fahkwang' => 1.0,
        'CormorantSC' => 1.22,
        'UnicaOne' => 1.22,
        'CrimsonPro' => 1.18,
        'TiltPrism' => 1.15,
        _ => 1.0,
      };

  /// Style applied to just the ₲ span when a glyph font is active.
  /// Scales fontSize per-family so every option sits optically level
  /// with the surrounding numerals.
  static TextStyle? glyphStyle(TextStyle base) {
    if (!isGlyph) return null;
    final fs = base.fontSize;
    return base.copyWith(
      fontFamily: font,
      fontSize: fs == null ? null : fs * glyphScale(font),
      height: 1.0,
    );
  }
}

/// Renders an XFG amount without any trailing ticker.
///
/// Glyph mode: `₲` prefix in the chosen display font + the bare figure.
/// Plain mode: the bare figure + [plainTail] (default ` XFG`).
Widget xfgAmount(
  String amount, {
  TextStyle? style,
  String plainTail = ' XFG',
  Key? key,
  int? maxLines,
  TextOverflow? overflow,
}) {
  final s = style ?? const TextStyle();
  if (!XfgTicker.isGlyph) {
    return Text(
      key: key,
      '$amount$plainTail',
      style: s,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
  return Text.rich(
    key: key,
    TextSpan(style: s, children: [
      TextSpan(text: XfgTicker.glyph, style: XfgTicker.glyphStyle(s)),
      TextSpan(text: amount),
    ]),
    maxLines: maxLines,
    overflow: overflow,
  );
}
