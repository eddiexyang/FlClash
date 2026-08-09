import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class NetworkSpeed extends StatefulWidget {
  const NetworkSpeed({super.key});

  @override
  State<NetworkSpeed> createState() => _NetworkSpeedState();
}

class _NetworkSpeedState extends State<NetworkSpeed> {
  List<Point> _getPoints(
    List<Traffic> traffics,
    List<DateTime> sampleTimes,
  ) {
    final sampleCount = math.min(traffics.length, sampleTimes.length);
    if (sampleCount == 0) return const [];

    final trafficOffset = traffics.length - sampleCount;
    final timeOffset = sampleTimes.length - sampleCount;
    final windowEnd = DateTime.now();
    final windowStart = windowEnd.subtract(
      const Duration(seconds: networkSpeedWindowSeconds),
    );
    final points = <Point>[];
    for (var index = 0; index < sampleCount; index++) {
      final sampleTime = sampleTimes[timeOffset + index];
      if (sampleTime.isBefore(windowStart)) continue;
      final elapsed = sampleTime.difference(windowStart);
      final x = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
      final speed = traffics[trafficOffset + index].speed;
      points.add(Point(x, speed.toDouble()));
    }
    return points;
  }

  Traffic _getLastTraffic(List<Traffic> traffics) {
    if (traffics.isEmpty) return Traffic();
    return traffics.last;
  }

  @override
  Widget build(BuildContext context) {
    final color = context.colorScheme.onSurfaceVariant.opacity80;
    return SizedBox(
      height: getWidgetHeight(2),
      child: RepaintBoundary(
        child: CommonCard(
          onPressed: () {},
          child: Consumer(
            builder: (_, ref, _) {
              ref.watch(runTimeProvider);
              final traffics = ref.watch(trafficsProvider).list;
              final sampleTimes = ref.read(
                trafficsProvider.notifier,
              ).sampleTimes;
              return Column(
                children: [
                  Padding(
                    padding: baseInfoEdgeInsets.copyWith(bottom: 0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: InfoHeader(
                            padding: EdgeInsets.zero,
                            info: Info(
                              label: appLocalizations.networkSpeed,
                              iconData: Icons.speed_sharp,
                            ),
                          ),
                        ),
                        SizedBox(width: 8),
                        Text(
                          _getLastTraffic(traffics).speedText,
                          style: context.textTheme.bodySmall?.copyWith(
                            color: color,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: Padding(
                      padding: EdgeInsets.all(
                        16,
                      ).copyWith(bottom: 0, left: 0, right: 0),
                      child: LineChart(
                        gradient: true,
                        color: Theme.of(context).colorScheme.primary,
                        points: _getPoints(traffics, sampleTimes),
                        minX: 0,
                        maxX: networkSpeedWindowSeconds.toDouble(),
                        xLabels: const ['-60s', '-30s', '0s'],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
