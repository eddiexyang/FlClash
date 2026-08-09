import 'dart:math';

import 'package:fl_clash/common/common.dart';
import 'package:flutter/material.dart';

@immutable
class DonutChartData {
  final double _value;
  final Color color;

  const DonutChartData({
    required double value,
    required this.color,
  }) : _value = value < 0 ? 0 : value;

  double get value => _value;

  @override
  String toString() {
    return 'DonutChartData{_value: $_value}';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DonutChartData &&
          runtimeType == other.runtimeType &&
          _value == other._value &&
          color == other.color;

  @override
  int get hashCode => _value.hashCode ^ color.hashCode;
}

class DonutChart extends StatefulWidget {
  final List<DonutChartData> data;
  final Duration duration;

  const DonutChart({
    super.key,
    required this.data,
    this.duration = commonDuration,
  });

  @override
  State<DonutChart> createState() => _DonutChartState();
}

class _DonutChartState extends State<DonutChart>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late List<DonutChartData> _oldData;

  @override
  void initState() {
    super.initState();
    _oldData = widget.data;
    _animationController = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
  }

  @override
  void didUpdateWidget(DonutChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _oldData = oldWidget.data;
      _animationController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        return CustomPaint(
          painter: DonutChartPainter(
            _oldData,
            widget.data,
            _animationController.value,
            Theme.of(context).colorScheme.outline,
          ),
        );
      },
    );
  }
}

class DonutChartPainter extends CustomPainter {
  final List<DonutChartData> oldData;
  final List<DonutChartData> newData;
  final double progress;
  final Color trackColor;

  late final Paint _arcPaint;

  List<DonutChartData>? _cachedInterpolatedData;
  double? _cachedProgress;

  DonutChartPainter(
    this.oldData,
    this.newData,
    this.progress,
    this.trackColor,
  ) {
    _arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
  }

  List<DonutChartData> get _interpolatedData {
    if (_cachedInterpolatedData != null && _cachedProgress == progress) {
      return _cachedInterpolatedData!;
    }

    if (newData.isEmpty) {
      _cachedInterpolatedData = newData;
      _cachedProgress = progress;
      return newData;
    }

    if (oldData.length != newData.length) {
      _cachedInterpolatedData = newData;
      _cachedProgress = progress;
      return newData;
    }

    final result = <DonutChartData>[];
    for (var i = 0; i < newData.length; i++) {
      final oldValue = oldData[i].value;
      final newValue = newData[i].value;
      final interpolatedValue = oldValue + (newValue - oldValue) * progress;

      result.add(DonutChartData(
        value: interpolatedValue,
        color: newData[i].color,
      ));
    }

    _cachedInterpolatedData = result;
    _cachedProgress = progress;
    return result;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final data = _interpolatedData;
    if (data.isEmpty) return;

    double total = 0;
    for (final item in data) {
      total += item.value;
    }

    final center = Offset(size.width / 2, size.height / 2);
    final strokeWidth = 10.0.ap;
    final radius = min(size.width / 2, size.height / 2) - strokeWidth / 2;
    if (radius <= 0) return;

    _arcPaint.strokeWidth = strokeWidth;
    if (total <= 0) {
      _arcPaint.color = trackColor;
      canvas.drawCircle(center, radius, _arcPaint);
      return;
    }

    final gapRatio = (strokeWidth / (2 * radius)).clamp(0.0, 1.0);
    final gapAngle = 2 * asin(gapRatio) * 1.2;
    final availableAngle = 2 * pi - (data.length * gapAngle);
    final totalInv = 1.0 / total;

    double startAngle = -pi / 2 + gapAngle / 2;

    for (final item in data) {
      final sweepAngle = availableAngle * (item.value * totalInv);

      if (sweepAngle <= 0) continue;

      _arcPaint.color = item.color;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        _arcPaint,
      );

      startAngle += sweepAngle + gapAngle;
    }
  }

  @override
  bool shouldRepaint(DonutChartPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.oldData != oldData ||
        oldDelegate.newData != newData ||
        oldDelegate.trackColor != trackColor;
  }
}
