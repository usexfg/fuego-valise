import 'package:flutter/material.dart';

/// The maison home's only door into the trading sheet.
///
/// Fuego is the page you are on. Portfolio is a launcher, not a second
/// dashboard painted over the dial.
class HomeModeBar extends StatelessWidget {
  const HomeModeBar({super.key, required this.onPortfolio});

  final VoidCallback onPortfolio;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          const Text(
            'FUEGO',
            style: TextStyle(
              color: Color(0xFFC5A059),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.6,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 16,
            height: 1,
            color: const Color(0xFFC5A059).withValues(alpha: 0.7),
          ),
          const Spacer(),
          Semantics(
            button: true,
            label: 'Open portfolio',
            child: GestureDetector(
              onTap: onPortfolio,
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'PORTFOLIO',
                      style: TextStyle(
                        color: Color(0xB3E8EDF2),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.2,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: Color(0xB3E8EDF2),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
