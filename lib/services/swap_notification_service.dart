import 'dart:async';
import 'package:flutter/material.dart';
import '../utils/theme.dart';
import 'daemon_event_bus.dart';

class SwapNotificationService {
  static StreamSubscription<DaemonEvent>? _sub;
  static final Map<String, bool> _prevLanded = <String, bool>{};

  static void init(DaemonEventBus bus, BuildContext context) {
    _sub?.cancel();
    _prevLanded.clear();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    _sub = bus.stream
        .where((DaemonEvent e) => e.type == DaemonEventBus.eventSpv)
        .listen((DaemonEvent event) {
          final List<dynamic> swaps =
              event.payload['swaps'] as List<dynamic>? ?? <dynamic>[];
          for (final dynamic raw in swaps) {
            if (raw is! Map<String, dynamic>) {
              continue;
            }
            final String swapId = raw['swapId'] as String? ?? '';
            if (swapId.isEmpty) {
              continue;
            }
            final int confirmations =
                (raw['confirmations'] as num?)?.toInt() ?? 0;
            final int required =
                (raw['requiredConfirmations'] as num?)?.toInt() ?? 6;
            final bool spvVerified = raw['spvVerified'] as bool? ?? false;
            final bool isLanded =
                spvVerified && confirmations >= required && required > 0;
            final bool wasLanded = _prevLanded[swapId] ?? false;
            _prevLanded[swapId] = isLanded;
            if (!wasLanded && isLanded) {
              final String shortId = swapId.length > 8
                  ? swapId.substring(0, 8)
                  : swapId;
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    'Swap $shortId landed — $confirmations/$required confirmed',
                  ),
                  backgroundColor: AppTheme.successColor,
                ),
              );
            }
          }
        });
  }

  static void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
