import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/core.dart';
import '../../bloc/wallet/wallet_cubit.dart';
import '../../bloc/mining/mining_cubit.dart';
import '../../utils/theme.dart';
import '../transactions/transaction_details_screen.dart';
import '../transactions/send_screen.dart';
import '../transactions/mint_heat_screen.dart';
import '../transactions/receive_screen.dart';
import '../../utils/xfg_ticker.dart';

// Shared prestige palette — Obsidian case + Champagne dial (Obsidian Reserve house)
const Color _obsidian = Color(0xFF0D0B08);
const Color _champagne = Color(
  0xFFC5A059,
); // Champagne gold — muted, not peachy
const Color _platinum = Color(0xFFF5F1E8); // Cream parchment
const List<Color> _fireStops = [
  Color(0xFF8C734B), // Muted gold
  Color(0xFFC5A059), // Champagne
  Color(0xFFD4B896), // Light champagne
  Color(0xFF8C734B),
];
LinearGradient get _fireLine => const LinearGradient(colors: _fireStops);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WalletCubit, WalletState>(
      builder: (context, state) {
        return SafeArea(
          top: true,
          bottom: false,
          child: RefreshIndicator(
            onRefresh: () => context.read<WalletCubit>().refreshWallet(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
              children: [
                const SizedBox(height: 8),
                _balanceCard(state),
                const SizedBox(height: 14),
                if (state.address != null) _addressPlate(state),
                if (state.address != null) const SizedBox(height: 14),
                _complicationsRow(state),
                _miningControls(state),
                const SizedBox(height: 16),
                const Text(
                  'Recent Transactions',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                if (state.transactions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No transactions yet',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  ...state.transactions.take(10).map((tx) => _txCard(tx)),
                if (state.error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      state.error!,
                      style: const TextStyle(
                        color: AppTheme.errorColor,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  static const _plaque = Color(0xFF141417);

  Widget _complicationsRow(WalletState state) {
    return BlocBuilder<MiningCubit, MiningState>(
      builder: (context, mining) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _complication('${state.blockHeight}', 'BLOCK HEIGHT'),
              _complication(_hashrate(mining.hashrate), 'HASHRATE'),
              _complication('${state.peerCount}', 'PEERS'),
            ],
          ),
        );
      },
    );
  }

  String _hashrate(int h) {
    if (h >= 1000000) return '${(h / 1000000).toStringAsFixed(1)}MH/s';
    if (h >= 1000) return '${(h / 1000).toStringAsFixed(1)}kH/s';
    return '${h}H/s';
  }

  Widget _complication(String value, String label) {
    return SizedBox(
      width: 64,
      height: 64,
      child: CustomPaint(
        painter: const _FireRingPainter(),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: TextStyle(
                    color: _platinum,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    fontFamily: AppTheme.numberFontFamily,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.38),
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _balanceCard(WalletState state) => _BalanceCard(state: state);

  Widget _addressPlate(WalletState state) {
    final addr = state.address ?? '';
    final alias = state.alias; // Assuming alias is in WalletState
    if (addr.isEmpty) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: _plaque,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1E1E24), Color(0xFF131317)],
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (alias != null)
                  Text(
                    '@$alias',
                    style: TextStyle(
                      color: _champagne,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                SelectableText(
                  addr,
                  maxLines: 1,
                  style: TextStyle(
                    color: const Color(0xFFE9E7E2).withOpacity(0.85),
                    fontSize: 11,
                    fontFamily: 'IBMPlexMono',
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: addr));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Address copied'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: Icon(
              Icons.copy_outlined,
              color: _champagne.withOpacity(0.55),
              size: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _miningControls(WalletState state) {
    return BlocBuilder<MiningCubit, MiningState>(
      builder: (context, mining) {
        final miningCubit = context.read<MiningCubit>();
        final miningSupported = miningCubit.isMiningSupported;
        final addr = state.address;
        final canMine = miningSupported && addr != null && addr.isNotEmpty;

        String statusText;
        String? miningHashrate;
        Color statusColor;
        if (!miningSupported) {
          statusText = 'Pool mining unavailable on iOS due to Appstore policy';
          statusColor = AppTheme.textMuted;
        } else {
          switch (mining.status) {
            case 'connecting':
              statusText =
                  'Connecting to ${mining.poolHost}:${mining.poolPort}...';
              statusColor = Colors.orange;
            case 'connected':
              statusText = 'Connected — waiting for jobs';
              statusColor = Colors.cyanAccent;
            case 'mining':
              statusText = 'Mining — ';
              statusColor = AppTheme.successColor;
              miningHashrate = '${mining.hashrate} H/s';
            case 'error':
              statusText = mining.error ?? 'Connection failed';
              statusColor = AppTheme.errorColor;
            default:
              statusText = 'Pool Miner (${mining.poolHost}:${mining.poolPort})';
              statusColor = AppTheme.textMuted;
          }
        }

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.surfaceColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  if (mining.status == 'connecting')
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      Icons.memory,
                      color: mining.isMining
                          ? AppTheme.successColor
                          : AppTheme.textMuted,
                      size: 18,
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        style: TextStyle(color: statusColor, fontSize: 14),
                        children: [
                          TextSpan(text: statusText),
                          if (miningHashrate != null)
                            TextSpan(
                              text: miningHashrate,
                              style: TextStyle(
                                fontFamily: AppTheme.numberFontFamily,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: !canMine
                        ? null
                        : () {
                            if (mining.isMining) {
                              context.read<MiningCubit>().stopMining();
                            } else {
                              context.read<MiningCubit>().startMining(
                                walletAddress: addr,
                              );
                            }
                          },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: mining.isMining
                            ? AppTheme.errorColor.withOpacity(0.12)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          width: 1,
                          color: mining.isMining
                              ? AppTheme.errorColor.withOpacity(0.6)
                              : _champagne.withOpacity(0.5),
                        ),
                        gradient: mining.isMining
                            ? null
                            : LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  for (final c in _fireStops)
                                    c.withOpacity(0.18),
                                ],
                              ),
                      ),
                      child: Text(
                        mining.isMining ? 'STOP MINING' : 'START MINING',
                        style: TextStyle(
                          color: mining.isMining
                              ? AppTheme.errorColor
                              : _champagne,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (miningSupported) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    const Text(
                      'Cores',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                    ),
                    const SizedBox(width: 8),
                    DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        value: mining.coreCount,
                        dropdownColor: AppTheme.cardColor,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 11,
                        ),
                        isDense: true,
                        items: miningCubit.coreOptions
                            .map(
                              (cores) => DropdownMenuItem<int>(
                                value: cores,
                                child: Text('$cores'),
                              ),
                            )
                            .toList(),
                        onChanged: mining.isMining
                            ? null
                            : (cores) {
                                if (cores != null) {
                                  context.read<MiningCubit>().setCoreCount(
                                    cores,
                                  );
                                }
                              },
                      ),
                    ),
                  ],
                ),
              ],
              if (mining.sharesAccepted > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Shares: ${mining.sharesAccepted}',
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                    ),
                  ),
                ),
              if (!canMine)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: const Text(
                    'Wallet address not available',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 10),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _txCard(FuegoTransaction tx) {
    final isIn = tx.isIncoming;
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => TransactionDetailsScreen(transaction: tx),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.surfaceColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              isIn ? Icons.arrow_downward : Icons.arrow_upward,
              color: isIn ? AppTheme.successColor : AppTheme.errorColor,
              size: 16,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tx.txHash.substring(0, 16) + '...',
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 12,
                      fontFamily: 'IBMPlexMono',
                    ),
                  ),
                  Text(
                    tx.dateTime.toString().substring(0, 19),
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: xfgAmount(
                '${isIn ? '+' : '-'}${tx.amount.toStringAsFixed(decimalPlaces)}',
                style: TextStyle(
                  color: isIn ? AppTheme.successColor : AppTheme.errorColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Engine-turned guilloché texture: fine concentric ring sets from two
/// off-canvas centres, evoking a hand-lacquered watch dial at ~3% ink.
class _GuillochePainter extends CustomPainter {
  const _GuillochePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final white = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = Colors.white.withOpacity(0.035);
    final fireRect = Rect.fromLTWH(0, 0, size.width, size.height);
    final gold = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..shader = const LinearGradient(
        colors: [
          Color(0xFF8C734B),
          Color(0xFFC5A059),
          Color(0xFFD4B896),
          Color(0xFF8C734B),
        ],
      ).createShader(fireRect)
      ..color = const Color(0xFFC5A059).withOpacity(0.06);

    void rings(Offset center, int count, double step, Paint paint) {
      for (var i = 1; i <= count; i++) {
        canvas.drawCircle(center, i * step, paint);
      }
    }

    rings(Offset(size.width * 0.88, -size.height * 0.30), 26, 15, white);
    rings(const Offset(-30, 0), 14, 17, white);
    rings(Offset(size.width * 0.88, -size.height * 0.30), 9, 42, gold);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Swiss-watch balance card: rolling odometer figures, specular sweep on
/// settle, chain complications subdials and a knurled crown pusher.
class _BalanceCard extends StatefulWidget {
  const _BalanceCard({required this.state});

  final WalletState state;

  @override
  State<_BalanceCard> createState() => _BalanceCardState();
}

class _BalanceCardState extends State<_BalanceCard> {
  static const _mask = '••••••••';

  bool _showBalance = true;
  int _sweep = 0;

  /// Thin-space thousands grouping for prestige figures.
  String _grouped(String fixed) {
    final parts = fixed.split('.');
    final intPart = parts[0].replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]}\u2009',
    );
    return parts.length > 1 ? '$intPart.${parts[1]}' : intPart;
  }

  String _figure(double v) =>
      _showBalance ? _grouped(v.toStringAsFixed(decimalPlaces)) : _mask;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return Container(
      decoration: BoxDecoration(
        color: _obsidian,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.55),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(19),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(painter: const _GuillochePainter()),
            ),
            // Inner fire-gradient bezel (thin flame leaf)
            Padding(
              padding: const EdgeInsets.all(5),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(15),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      for (final c in _fireStops) c.withOpacity(0.55),
                      _fireStops.first.withOpacity(0.55),
                    ],
                  ),
                ),
                padding: const EdgeInsets.all(0.8),
                child: Container(
                  decoration: BoxDecoration(
                    color: _obsidian,
                    borderRadius: BorderRadius.circular(14.2),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'XFG BALANCE',
                        style: TextStyle(
                          color: _champagne.withOpacity(0.75),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 4,
                        ),
                      ),
                      GestureDetector(
                        onTap: () async {
                          final revealing = !_showBalance;
                          setState(() => _showBalance = revealing);
                          if (revealing) {
                            // Minute-repeater double tick on reveal.
                            HapticFeedback.selectionClick();
                            await Future.delayed(
                              const Duration(milliseconds: 90),
                            );
                            if (mounted) HapticFeedback.selectionClick();
                          }
                        },
                        child: Icon(
                          _showBalance
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          color: _champagne.withOpacity(0.55),
                          size: 17,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (XfgTicker.isGlyph)
                          Padding(
                            padding: const EdgeInsets.only(right: 8, bottom: 4),
                            child: Text(
                              XfgTicker.glyph,
                              style: XfgTicker.glyphStyle(
                                const TextStyle(
                                  color: _champagne,
                                  fontSize: 30,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        _ShimmerSweep(
                          sweep: _sweep,
                          child: ShaderMask(
                            shaderCallback: (bounds) => const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color(0xFFC5A059),
                                Color(0xFFD4B896),
                                Color(0xFF8C734B),
                              ],
                            ).createShader(bounds),
                            child: _OdometerText(
                              _figure(state.balanceXfg),
                              const TextStyle(
                                color: Colors.white,
                                fontSize: 44,
                                fontWeight: FontWeight.w600,
                                height: 1.0,
                                letterSpacing: 0.2,
                                fontFamily: 'Cormorant',
                              ),
                              onSettled: () => setState(() => _sweep++),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: _fireLine.withOpacity(0.35),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _statementRow(
                    'AVAILABLE',
                    _figure(state.unlockedBalanceXfg),
                    isXfgAmount: true,
                  ),
                  if (state.totalHeatXfg > 0) ...[
                    const SizedBox(height: 8),
                    _statementRow(
                      'ΗΞΔŦ UNLOCKED',
                      _figure(state.unlockedHeatXfg),
                      valueColor: AppTheme.accentColor,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Container(
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: _fireLine.withOpacity(0.35),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: _fireLine.withOpacity(0.35),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _CrownPusher(
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const SendScreen(),
                            ),
                          );
                        },
                      ),
                      _CrownPusher(
                        icon: Icons.local_fire_department,
                        label: 'MINT ΗΞΔŦ',
                        accent: AppTheme.accentColor,
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const MintHeatScreen(),
                            ),
                          );
                        },
                      ),
                      _CrownPusher(
                        icon: Icons.arrow_downward,
                        label: 'RECEIVE',
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const ReceiveScreen(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statementRow(
    String label,
    String value, {
    Color? valueColor,
    bool isXfgAmount = false,
  }) {
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withOpacity(0.38),
            fontSize: 9,
            fontWeight: FontWeight.w600,
            letterSpacing: 3,
          ),
        ),
        const Spacer(),
        if (isXfgAmount && XfgTicker.isGlyph)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              XfgTicker.glyph,
              style: XfgTicker.glyphStyle(
                const TextStyle(
                  color: _champagne,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        _OdometerText(
          value,
          TextStyle(
            color: valueColor ?? _platinum.withOpacity(0.92),
            fontSize: 14,
            fontWeight: FontWeight.w500,
            height: 1.2,
            fontFamily: AppTheme.numberFontFamily,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// One-shot diagonal specular highlight across its child. Replays when the
/// [sweep] counter changes; idles fully transparent otherwise.
class _ShimmerSweep extends StatefulWidget {
  const _ShimmerSweep({required this.sweep, required this.child});

  final int sweep;
  final Widget child;

  @override
  State<_ShimmerSweep> createState() => _ShimmerSweepState();
}

class _ShimmerSweepState extends State<_ShimmerSweep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void didUpdateWidget(covariant _ShimmerSweep oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sweep != oldWidget.sweep && widget.sweep > 0) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        if (!_controller.isAnimating) return child!;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withOpacity(0),
              Colors.white.withOpacity(0.18),
              Colors.white.withOpacity(0),
            ],
            stops: const [0.40, 0.50, 0.60],
            transform: _SweepGradientTransform(_controller.value * 3 - 1),
          ).createShader(bounds),
          child: child,
        );
      },
    );
  }
}

/// Translates a gradient band horizontally by [slide] rect-widths.
class _SweepGradientTransform extends GradientTransform {
  const _SweepGradientTransform(this.slide);

  final double slide;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * slide, 0, 0);
}

/// Rolling-figure odometer. Digit pairs tween along the shortest 0-9 wrap
/// path with easeOutCubic; skeleton changes fall back to a gentle rise-in.
/// Masked (bullet) strings jump instantly.
class _OdometerText extends StatefulWidget {
  const _OdometerText(
    this.text,
    this.style, {
    this.duration = const Duration(milliseconds: 450),
    this.onSettled,
  });

  final String text;
  final TextStyle style;
  final Duration duration;
  final VoidCallback? onSettled;

  @override
  State<_OdometerText> createState() => _OdometerTextState();
}

class _OdometerTextState extends State<_OdometerText>
    with SingleTickerProviderStateMixin {
  static bool _isDigit(String c) =>
      c.isNotEmpty && c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;

  late String _display = widget.text;
  String _from = '';
  String _target = '';
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          setState(() => _display = _target);
          widget.onSettled?.call();
        }
      });
  }

  @override
  void didUpdateWidget(covariant _OdometerText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text == oldWidget.text) return;
    final to = widget.text;
    if (to.contains('•')) {
      // Masking: settle instantly, no roll.
      _controller.stop();
      setState(() {
        _display = to;
        _target = '';
        _from = '';
      });
      return;
    }
    final rollable =
        !_display.contains('•') &&
        _display.length == to.length &&
        _layoutMatches(_display, to);
    setState(() {
      _target = to;
      _from = rollable ? _display : _zeroSeed(to);
    });
    _controller
      ..duration = widget.duration
      ..forward(from: 0);
  }

  /// Same-length strings whose non-digit skeleton is identical roll
  /// column-by-column; anything else uses the rise-in fallback.
  bool _layoutMatches(String a, String b) {
    for (var i = 0; i < a.length; i++) {
      if (!_isDigit(a[i]) && a[i] != b[i]) return false;
    }
    return true;
  }

  String _zeroSeed(String to) => to.replaceAllMapped(RegExp(r'\d'), (_) => '0');

  double get _lineHeight =>
      (widget.style.fontSize ?? 14) * (widget.style.height ?? 1.2);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        if (!_controller.isAnimating) {
          return Text(_display, style: widget.style);
        }
        final t = CurvedAnimation(
          parent: _controller,
          curve: Curves.easeOutCubic,
        ).value;
        final rollable =
            _from.isNotEmpty &&
            _layoutMatches(_from, _target) &&
            _from.length == _target.length;
        if (!rollable) {
          return Transform.translate(
            offset: Offset(0, (1 - t) * 8),
            child: Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: Text(_target, style: widget.style),
            ),
          );
        }
        final lineHeight = _lineHeight;
        final children = <Widget>[];
        for (var i = 0; i < _target.length; i++) {
          final from = _from[i];
          final to = _target[i];
          if (from == to || !_isDigit(from) || !_isDigit(to)) {
            children.add(_cell(Text(to, style: widget.style), lineHeight));
          } else {
            children.add(
              _cell(_rollColumn(from, to, t, lineHeight), lineHeight),
            );
          }
        }
        return Row(mainAxisSize: MainAxisSize.min, children: children);
      },
    );
  }

  Widget _cell(Widget child, double lineHeight) => SizedBox(
    height: lineHeight,
    child: Center(child: child),
  );

  Widget _rollColumn(String from, String to, double t, double lineHeight) {
    final seq = _sequence(from, to);
    return ClipRect(
      child: OverflowBox(
        maxWidth: double.infinity,
        maxHeight: lineHeight * seq.length,
        alignment: Alignment.topCenter,
        child: Transform.translate(
          offset: Offset(0, -t * lineHeight * (seq.length - 1)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [for (final c in seq) Text(c, style: widget.style)],
          ),
        ),
      ),
    );
  }

  /// Shortest wrap path from [from] to [to], inclusive of both ends.
  List<String> _sequence(String from, String to) {
    var a = from.codeUnitAt(0) - 48;
    final b = to.codeUnitAt(0) - 48;
    final up = (b - a + 10) % 10;
    final down = (a - b + 10) % 10;
    final stepCount = up <= down ? up : down;
    final step = up <= down ? 1 : 9; // +9 mod 10 == -1
    final seq = <String>[from];
    for (var i = 0; i < stepCount; i++) {
      a = (a + step) % 10;
      seq.add('$a');
    }
    return seq;
  }
}

/// Circular crown pusher: obsidian disc, champagne hairline ring over a
/// knurled rim of radial ridges, 'SEND' micro-caps beneath.
class _CrownPusher extends StatelessWidget {
  const _CrownPusher({
    required this.onTap,
    this.icon = Icons.arrow_upward,
    this.label = 'SEND',
    this.accent,
  });

  final VoidCallback onTap;
  final IconData icon;
  final String label;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final a = accent ?? _champagne;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 58,
            height: 58,
            child: CustomPaint(
              painter: _KnurlPainter(accent: a),
              child: Center(child: Icon(icon, color: a, size: 20)),
            ),
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              style: TextStyle(
                color: a.withOpacity(0.65),
                fontSize: 8,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Knurled crown edge: 36 radial ridges at the rim under a hairline ring.
class _KnurlPainter extends CustomPainter {
  const _KnurlPainter({this.accent});
  final Color? accent;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    canvas.drawCircle(
      center,
      radius - 0.5,
      Paint()..color = const Color(0xFF0C0C0F),
    );

    final fireRect = Rect.fromLTWH(0, 0, size.width, size.height);
    final tick = Paint()
      ..shader = LinearGradient(
        colors: [for (final c in _fireStops) c.withOpacity(0.55)],
      ).createShader(fireRect)
      ..color = (accent ?? _champagne).withOpacity(0.45)
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 36; i++) {
      final angle = i * math.pi / 18; // 10° steps
      final dir = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + dir * (radius - 4.5),
        center + dir * (radius - 1.5),
        tick,
      );
    }

    canvas.drawCircle(
      center,
      radius - 5.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = const Color(0xFFC9A96A).withOpacity(0.55),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Thin fire-gradient ring for complication subdials.
class _FireRingPainter extends CustomPainter {
  const _FireRingPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF8C734B),
          Color(0xFFC5A059),
          Color(0xFFD4B896),
          Color(0xFF8C734B),
        ],
      ).createShader(Offset.zero & size)
      ..color = Colors.white.withOpacity(0.10);
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.width / 2 - 0.5,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
