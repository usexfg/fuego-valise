import 'package:flutter/material.dart';
import '../../../utils/theme.dart';

const List<int> kCdTermEpochs = [6, 18, 36, 72];

class CdV12Cover extends StatelessWidget {
  const CdV12Cover({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lock_clock, color: AppTheme.primaryColor),
              const SizedBox(width: 10),
              Text(
                'CDs open at v12',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const _Body(
            'Certificates of Deposit activate with the v12 network upgrade. '
            'Creating and withdrawing CDs is unavailable until then.',
          ),
          const _Heading('HEAT CD tiers and terms'),
          const _Body(
            'A CD locks HEAT for a fixed term and earns protocol fee yield. '
            'One epoch is 900 blocks, about 5 days on mainnet.',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final epochs in kCdTermEpochs) _TermChip(epochs)],
          ),
          const _Heading('Creation fee'),
          const _Body(
            'Opening a CD costs a one-time fee paid in XFG: 0.25% of the HEAT '
            'deposited at 6 epochs, rising linearly to 1% at 72 epochs, valued '
            'at the mint oracle price. The fee funds the XFG leg of the '
            'protocol liquidity position. It is not yield.',
          ),
          const _Heading('Where yield comes from'),
          const _Bullet(
            'Hearth taker fee: the CD share of the 1% taker fee, 70% from v12.',
          ),
          const _Bullet(
            'Atomic swaps: 80% of the swap fee goes to the CD yield pool.',
          ),
          const _Body(
            'Yield is paid from fees earned. Never from burns, the creation '
            'fee, or inflation.',
          ),
          const _Heading('Bonus Vault minimum yield'),
          const _Body(
            '20% of swap fees fill the Bonus Vault. In a lean epoch, when the '
            'fee rate falls below the CD yield floor rate, the vault tops a CD '
            'up to that floor, capped by the vault balance. The floor is '
            '111 per million per epoch, about 0.8% a year, and is flat in '
            'term: a 6-epoch CD and a 72-epoch CD get the same floor rate.',
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;

  const _Heading(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: AppTheme.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final String text;

  const _Body(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: AppTheme.textSecondary,
        fontSize: 14,
        height: 1.4,
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final String text;

  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '•  ',
            style: TextStyle(color: AppTheme.primaryColor, fontSize: 14),
          ),
          Expanded(child: _Body(text)),
        ],
      ),
    );
  }
}

class _TermChip extends StatelessWidget {
  final int epochs;

  const _TermChip(this.epochs);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.primaryColor.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$epochs epochs',
        style: TextStyle(
          color: AppTheme.primaryColor,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          fontFamily: AppTheme.numberFontFamily,
        ),
      ),
    );
  }
}
