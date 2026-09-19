import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/chain_info.dart';
import '../../utils/theme.dart';

/// Theatre cluster: required dots + status line + tappable explorer + progress.
///
/// Mirrors the Act 0 SPV fields wired through SwapDaemonClient.SwapInfo.
class ConfirmationCluster extends StatelessWidget {
  const ConfirmationCluster({
    super.key,
    required this.chain,
    required this.confirmations,
    required this.requiredConfirmations,
    required this.spvVerified,
    required this.blockHeight,
    required this.txid,
    required this.spvError,
  });

  final String chain;
  final int confirmations;
  final int requiredConfirmations;
  final bool spvVerified;
  final int blockHeight;
  final String? txid;
  final String? spvError;

  int get _required {
    if (requiredConfirmations > 0) {
      return requiredConfirmations;
    }
    return 6;
  }

  String get _statusText {
    if (spvError != null && spvError!.isNotEmpty) {
      return 'SPV: $spvError';
    }
    if (txid == null || txid!.isEmpty) {
      return 'Awaiting commit';
    }
    if (confirmations == 0) {
      return 'Seen in mempool — 0/$_required';
    }
    if (!spvVerified) {
      return '$confirmations/$_required confirmations (unverified)';
    }
    if (confirmations < _required) {
      return 'Landed $confirmations/$_required — SPV verified at $blockHeight';
    }
    return 'Confirmed $confirmations/$_required — ready';
  }

  bool get _hasError {
    if (spvError != null && spvError!.isNotEmpty) {
      return true;
    }
    return false;
  }

  Future<void> _openExplorer(BuildContext context) async {
    final String? id = txid;
    if (id == null || id.isEmpty) {
      return;
    }
    final String url = ChainInfo.explorerTxUrl(chain, id);
    if (url.isEmpty) {
      return;
    }
    final Uri uri = Uri.parse(url);
    final bool launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open $url'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  Future<void> _copyTxid(BuildContext context) async {
    final String? id = txid;
    if (id == null || id.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: id));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Transaction ID copied'),
          backgroundColor: AppTheme.successColor,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final int req = _required;
    final int filled = confirmations.clamp(0, req);
    final double progress = req > 0
        ? (confirmations / req).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final bool hasTxid = txid != null && txid!.isNotEmpty;
    final String explorerUrl = hasTxid
        ? ChainInfo.explorerTxUrl(chain, txid!)
        : '';
    final bool canOpen = explorerUrl.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [for (int i = 0; i < req; i++) _buildDot(i, filled, req)],
        ),
        const SizedBox(height: 8),
        Text(
          _statusText,
          style: TextStyle(
            color: _hasError ? const Color(0xFFC5A059) : AppTheme.textSecondary,
            fontFamily: 'CormorantGaramond', // Luxury editorial serif
            fontSize: 11,
            fontWeight: _hasError ? FontWeight.w600 : FontWeight.w400,
            height: 1.3,
          ),
        ),
        if (hasTxid) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: canOpen ? () => _openExplorer(context) : null,
                  onLongPress: () => _copyTxid(context),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            txid!,
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 10,
                              fontFamily: 'IBMPlexMono',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (canOpen) ...[
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.open_in_new,
                            size: 12,
                            color: AppTheme.primaryColor,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (blockHeight > 0) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: canOpen ? () => _openExplorer(context) : null,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(
                      '#$blockHeight',
                      style: const TextStyle(
                        color: AppTheme.primaryColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                        decorationColor: AppTheme.primaryColor,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            backgroundColor: AppTheme.surfaceColor,
            valueColor: const AlwaysStoppedAnimation<Color>(
              Color(0xFFC5A059),
            ), // Champagne gold progress
          ),
        ),
      ],
    );
  }

  Widget _buildDot(int index, int filled, int req) {
    final bool isFilled = index < filled;
    final bool isCurrent =
        index == filled && filled < req && filled == confirmations;
    final bool showCheck = isFilled && spvVerified;
    final Widget dot = Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isFilled
            ? Color(0xFFC5A059)
            : Colors.transparent, // Champagne fill
        border: Border.all(
          color: isFilled
              ? Color(0xFFC5A059)
              : Color(0xFF3D5A80), // Midnight Blue unfilled
          width: 1.2,
        ),
      ),
      child: showCheck
          ? const Icon(
              Icons.check,
              size: 7,
              color: Color(0xFF0D0B08),
            ) // Black check on gold
          : null,
    );
    if (!isCurrent || !isFilled) {
      if (isCurrent && !isFilled) {
        return _PulsingDot(child: dot);
      }
      return dot;
    }
    // Current confirming dot pulses; verified dots already have check.
    // Pulsing applies to the in-progress dot at the confirmation frontier.
    return _PulsingDot(child: dot);
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.child});
  final Widget child;
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> {
  bool _forward = true;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 1.0, end: _forward ? 1.08 : 1.0),
      duration: const Duration(milliseconds: 450),
      onEnd: () {
        if (mounted) {
          setState(() {
            _forward = !_forward;
          });
        }
      },
      builder: (BuildContext context, double scale, Widget? child) {
        return Transform.scale(scale: scale, child: child);
      },
      child: widget.child,
    );
  }
}
