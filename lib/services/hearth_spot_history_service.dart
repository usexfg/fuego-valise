import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/heat_amm.dart';

class HearthSpotObservation {
  final int time;
  final double heatPerXfg;

  const HearthSpotObservation({required this.time, required this.heatPerXfg});
}

class HearthSpotHistoryService {
  static const _keyPrefix = 'hearth_spot_daily_v1_';

  Future<List<HearthSpotObservation>> load(String networkId) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('$_keyPrefix$networkId');
    if (saved == null) return const [];
    final decoded = jsonDecode(saved);
    if (decoded is! List) {
      throw const FormatException('Invalid saved Hearth spot history');
    }

    final observations = <HearthSpotObservation>[];
    for (final row in decoded) {
      if (row is! Map<String, dynamic> ||
          row['time'] is! int ||
          row['heatPerXfg'] is! num) {
        throw const FormatException('Invalid saved Hearth spot observation');
      }
      final observation = HearthSpotObservation(
        time: row['time'] as int,
        heatPerXfg: (row['heatPerXfg'] as num).toDouble(),
      );
      if (observation.time <= 0 ||
          !observation.heatPerXfg.isFinite ||
          observation.heatPerXfg <= 0 ||
          (observations.isNotEmpty &&
              observation.time ~/ Duration.secondsPerDay <=
                  observations.last.time ~/ Duration.secondsPerDay)) {
        throw const FormatException('Invalid saved Hearth spot chronology');
      }
      observations.add(observation);
    }
    return List.unmodifiable(observations);
  }

  Future<List<HearthSpotObservation>> record(
    String networkId,
    PoolInfo pool, {
    DateTime? observedAt,
  }) async {
    final observations = (await load(networkId)).toList();
    if (pool.status != 'OK' ||
        pool.reserveXfg <= 0 ||
        pool.reserveHeat <= 0 ||
        pool.spotPrice <= 0 ||
        !pool.heatPerXfg.isFinite) {
      return List.unmodifiable(observations);
    }

    final time =
        (observedAt ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
    if (observations.isNotEmpty && time <= observations.last.time) {
      return List.unmodifiable(observations);
    }
    final next = HearthSpotObservation(time: time, heatPerXfg: pool.heatPerXfg);
    if (observations.isNotEmpty &&
        observations.last.time ~/ Duration.secondsPerDay ==
            time ~/ Duration.secondsPerDay) {
      observations[observations.length - 1] = next;
    } else {
      observations.add(next);
    }

    final prefs = await SharedPreferences.getInstance();
    final encoded = observations
        .map(
          (observation) => {
            'time': observation.time,
            'heatPerXfg': observation.heatPerXfg,
          },
        )
        .toList();
    final saved = await prefs.setString(
      '$_keyPrefix$networkId',
      jsonEncode(encoded),
    );
    if (!saved) throw StateError('Unable to save Hearth spot history');
    return List.unmodifiable(observations);
  }
}
