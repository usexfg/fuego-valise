import 'package:flutter/material.dart';
import '../../services/swap_daemon_client.dart';
import '../../utils/theme.dart';

/// Theatre timeline: 7 adaptor steps or 4 AFK steps, horizontal on desktop
/// and vertical on mobile (<600 via LayoutBuilder).
class SwapTimelineStepper extends StatelessWidget {
  const SwapTimelineStepper({super.key, required this.swap});

  final SwapInfo swap;

  static const List<_StepDef> _adaptorSteps = [
    _StepDef(id: 10, label: 'Keys exchanged', icon: Icons.vpn_key),
    _StepDef(id: 11, label: 'Escrow funded', icon: Icons.lock),
    _StepDef(id: 12, label: 'Presigs ready', icon: Icons.draw),
    _StepDef(id: 13, label: 'Counterparty locked', icon: Icons.anchor),
    _StepDef(id: 17, label: 'Confirming SPV', icon: Icons.verified),
    _StepDef(id: 18, label: 'Secret confirmed', icon: Icons.key),
    _StepDef(id: 14, label: 'Secret revealed', icon: Icons.check_circle),
    _StepDef(id: 15, label: 'Complete', icon: Icons.celebration),
  ];

  static const List<_StepDef> _afkSteps = [
    _StepDef(id: 100, label: 'Offer locked', icon: Icons.lock),
    _StepDef(id: 101, label: 'Offer accepted', icon: Icons.handshake),
    _StepDef(id: 102, label: 'AFK claimed', icon: Icons.verified),
    _StepDef(id: 103, label: 'AFK refunded', icon: Icons.replay),
  ];

  static const Map<int, int> _adaptorIndex = {
    10: 0,
    11: 1,
    12: 2,
    13: 3,
    17: 4,
    18: 5,
    14: 6,
    15: 7,
  };

  static const Map<int, int> _afkIndex = {100: 0, 101: 1, 102: 2, 103: 3};

  static const Map<String, int> _nameToAdaptorId = {
    'ADAPTOR_KEYS_EXCHANGED': 10,
    'ADAPTOR_ESCROW_FUNDED': 11,
    'ADAPTOR_PRESIGS_READY': 12,
    'ADAPTOR_CTR_LOCKED': 13,
    'ADAPTOR_WAITING_SPV': 17,
    'ADAPTOR_SECRET_CONFIRMED_SPV': 18,
    'ADAPTOR_SECRET_REVEALED': 14,
    'ADAPTOR_XFG_SPENT': 15,
    'ADAPTOR_REFUNDED': 16,
  };

  static const Map<String, int> _nameToAfkId = {
    'AFK_OFFER_LOCKED': 100,
    'AFK_OFFER_ACCEPTED': 101,
    'AFK_CLAIMED': 102,
    'AFK_REFUNDED': 103,
  };

  bool get _isAfk {
    if (_nameToAfkId.containsKey(swap.state)) {
      return true;
    }
    // Heuristic: AFK swaps carry swap_id == lockId and short timeouts;
    // but state name is authoritative.
    return false;
  }

  List<_StepDef> get _steps {
    if (_isAfk) {
      return _afkSteps;
    }
    return _adaptorSteps;
  }

  int _stepIndex(String state) {
    if (_isAfk) {
      final int? id = _nameToAfkId[state];
      if (id != null) {
        return _afkIndex[id] ?? 0;
      }
      return 0;
    }
    final int? id = _nameToAdaptorId[state];
    if (id != null) {
      return _adaptorIndex[id] ?? 0;
    }
    // Fallback: numeric state stored as string? try parse.
    final int? numeric = int.tryParse(state);
    if (numeric != null) {
      if (_adaptorIndex.containsKey(numeric)) {
        return _adaptorIndex[numeric]!;
      }
      if (_afkIndex.containsKey(numeric)) {
        return _afkIndex[numeric]!;
      }
    }
    return 0;
  }

  bool _isCompleted(int stepPos, int currentPos) {
    if (swap.isTerminal) {
      // Terminal state: everything up to current is completed.
      if (stepPos < currentPos) {
        return true;
      }
      if (stepPos == currentPos) {
        return true;
      }
      return false;
    }
    if (stepPos < currentPos) {
      return true;
    }
    return false;
  }

  String _formatTimestamp(int seconds) {
    if (seconds <= 0) {
      return '';
    }
    try {
      final DateTime dt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
      final String y = dt.year.toString().padLeft(4, '0');
      final String m = dt.month.toString().padLeft(2, '0');
      final String d = dt.day.toString().padLeft(2, '0');
      final String hh = dt.hour.toString().padLeft(2, '0');
      final String mm = dt.minute.toString().padLeft(2, '0');
      return '$y-$m-$d $hh:$mm';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<_StepDef> steps = _steps;
    final int currentPos = _stepIndex(swap.state);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool isHorizontal = constraints.maxWidth >= 600;
        if (isHorizontal) {
          return _buildHorizontal(context, steps, currentPos);
        }
        return _buildVertical(context, steps, currentPos);
      },
    );
  }

  Widget _buildHorizontal(
    BuildContext context,
    List<_StepDef> steps,
    int currentPos,
  ) {
    final String ts = _formatTimestamp(swap.updatedAt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < steps.length; i++) ...[
              Expanded(child: _buildStep(context, steps[i], i, currentPos, ts)),
              if (i < steps.length - 1)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 400),
                      height: 2,
                      color: i < currentPos
                          ? AppTheme.primaryColor
                          : AppTheme.surfaceColor,
                    ),
                  ),
                ),
            ],
          ],
        ),
        if (ts.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            ts,
            style: const TextStyle(
              color: AppTheme.textMuted,
              fontSize: 10,
              fontFamily: 'CormorantGaramond', // Luxury editorial serif
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildVertical(
    BuildContext context,
    List<_StepDef> steps,
    int currentPos,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < steps.length; i++)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                children: [
                  _buildCircle(steps[i], i, currentPos),
                  if (i < steps.length - 1)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 400),
                      width: 2,
                      height: 28,
                      color: i < currentPos
                          ? AppTheme.primaryColor
                          : AppTheme.surfaceColor,
                    ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        steps[i].label,
                        style: TextStyle(
                          color: _isCompleted(i, currentPos)
                              ? AppTheme.textPrimary
                              : i == currentPos
                              ? AppTheme.primaryColor
                              : AppTheme.textMuted,
                          fontSize: 11,
                          fontWeight: i == currentPos
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      if (i == currentPos) ...[
                        const SizedBox(height: 2),
                        Text(
                          swap.displayState,
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 10,
                          ),
                        ),
                        if (swap.updatedAt > 0) ...[
                          const SizedBox(height: 2),
                          Text(
                            _formatTimestamp(swap.updatedAt),
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 10,
                              fontFamily: 'IBMPlexMono',
                            ),
                          ),
                        ],
                      ],
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildStep(
    BuildContext context,
    _StepDef step,
    int pos,
    int currentPos,
    String ts,
  ) {
    final bool completed = _isCompleted(pos, currentPos);
    final bool current = pos == currentPos;
    return Column(
      children: [
        _buildCircle(step, pos, currentPos),
        const SizedBox(height: 6),
        Text(
          step.label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: completed
                ? AppTheme.textPrimary
                : current
                ? AppTheme.primaryColor
                : AppTheme.textMuted,
            fontSize: 11,
            fontWeight: current ? FontWeight.w700 : FontWeight.w500,
            height: 1.2,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (current) ...[
          const SizedBox(height: 2),
          Text(
            swap.displayState,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 9),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (completed && !current)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.check, size: 10, color: AppTheme.successColor),
          ),
      ],
    );
  }

  Widget _buildCircle(_StepDef step, int pos, int currentPos) {
    final bool completed = _isCompleted(pos, currentPos);
    final bool current = pos == currentPos;
    final Color bg;
    final Color fg;
    final Widget icon;
    if (completed) {
      bg = AppTheme.primaryColor;
      fg = Colors.white;
      icon = const Icon(Icons.check, size: 14, color: Colors.white);
    } else if (current) {
      bg = AppTheme.primaryColor.withValues(alpha: 0.15);
      fg = AppTheme.primaryColor;
      icon = Icon(step.icon, size: 14, color: AppTheme.primaryColor);
    } else {
      bg = AppTheme.surfaceColor;
      fg = AppTheme.textMuted;
      icon = Icon(step.icon, size: 14, color: AppTheme.textMuted);
    }
    final Widget circle = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bg,
        border: Border.all(
          color: completed
              ? AppTheme.primaryColor
              : current
              ? AppTheme.primaryColor
              : AppTheme.surfaceColor,
          width: 1.2,
        ),
      ),
      child: Center(child: icon),
    );
    if (current && !completed) {
      return _PulsingScale(child: circle);
    }
    // Keep unused variable fg to satisfy lints without affecting visuals.
    // ignore: unused_local_variable
    final Color _ = fg;
    return circle;
  }
}

class _StepDef {
  const _StepDef({required this.id, required this.label, required this.icon});
  final int id;
  final String label;
  final IconData icon;
}

class _PulsingScale extends StatefulWidget {
  const _PulsingScale({required this.child});
  final Widget child;
  @override
  State<_PulsingScale> createState() => _PulsingScaleState();
}

class _PulsingScaleState extends State<_PulsingScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
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
      builder: (BuildContext context, Widget? child) {
        final double scale = 1.0 + (_controller.value * 0.08);
        return Transform.scale(scale: scale, child: widget.child);
      },
      child: widget.child,
    );
  }
}
