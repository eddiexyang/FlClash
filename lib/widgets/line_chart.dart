import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

class Point {
  final double x;
  final double y;

  const Point(this.x, this.y);
}

class LineChart extends StatefulWidget {
  final List<Point> points;
  final Color color;
  final Duration duration;
  final bool gradient;
  final double? minX;
  final double? maxX;
  final List<String> xLabels;

  LineChart({
    super.key,
    this.gradient = false,
    required this.points,
    required this.color,
    required this.xLabels,
    this.duration = Duration.zero,
    this.minX,
    this.maxX,
  }) : assert((minX == null) == (maxX == null)),
       assert(minX == null || minX < maxX!),
       assert(xLabels.length >= 2);

  @override
  State<LineChart> createState() => _LineChartState();
}

class _LineChartState extends State<LineChart>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  List<Point> _points = [];

  List<Point> _prevRenderPoints = [];
  List<Point> _currentRenderPoints = [];
  double _prevMaxY = 1;
  double _currentMaxY = 1;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _points = widget.points;
    _currentMaxY = _getMaxY(_points);
    _prevMaxY = _currentMaxY;
    _currentRenderPoints = _getRenderPoints(_points, _currentMaxY);
    _prevRenderPoints = _currentRenderPoints;
  }

  @override
  void didUpdateWidget(LineChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.points != _points ||
        widget.minX != oldWidget.minX ||
        widget.maxX != oldWidget.maxX) {
      _points = widget.points;
      _prevRenderPoints = _currentRenderPoints;
      _prevMaxY = _currentMaxY;
      _currentMaxY = _getMaxY(_points);
      _currentRenderPoints = _getRenderPoints(_points, _currentMaxY);
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _getMaxY(List<Point> points) {
    var maxY = 0.0;
    for (final point in points) {
      maxY = math.max(maxY, point.y);
    }
    if (maxY <= 1024) {
      return 1024;
    }
    final magnitude = math.pow(
      10,
      (math.log(maxY) / math.ln10).floor(),
    ).toDouble();
    final normalized = maxY / magnitude;
    final niceNormalized = switch (normalized) {
      <= 1 => 1.0,
      <= 2 => 2.0,
      <= 5 => 5.0,
      _ => 10.0,
    };
    return niceNormalized * magnitude;
  }

  List<Point> _getRenderPoints(List<Point> points, double maxY) {
    if (points.isEmpty) return [];
    double maxX = widget.maxX ?? points[0].x;
    double minX = widget.minX ?? points[0].x;

    if (widget.minX == null) {
      for (final point in points) {
        if (point.x > maxX) maxX = point.x;
        if (point.x < minX) minX = point.x;
      }
    }

    return points.map((e) {
      var x = (e.x - minX) / (maxX - minX);
      if (x.isNaN) x = 0;
      var y = e.y / maxY;
      if (y.isNaN) y = 0;
      return Point(x, y);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, container) {
        return AnimatedBuilder(
          animation: _controller.view,
          builder: (_, _) {
            final colorScheme = Theme.of(context).colorScheme;
            return CustomPaint(
              painter: LineChartPainter(
                prevRenderPoints: _prevRenderPoints,
                currentRenderPoints: _currentRenderPoints,
                progress: _controller.value,
                gradient: widget.gradient,
                color: widget.color,
                prevMaxY: _prevMaxY,
                currentMaxY: _currentMaxY,
                axisColor: colorScheme.onSurfaceVariant,
                gridColor: colorScheme.outline,
                labelStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
                xLabels: widget.xLabels,
              ),
              child: SizedBox(
                height: container.maxHeight,
                width: container.maxWidth,
              ),
            );
          },
        );
      },
    );
  }
}

class LineChartPainter extends CustomPainter {
  final List<Point> prevRenderPoints;
  final List<Point> currentRenderPoints;
  final double progress;
  final Color color;
  final bool gradient;
  final double prevMaxY;
  final double currentMaxY;
  final Color axisColor;
  final Color gridColor;
  final TextStyle? labelStyle;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final List<String> xLabels;

  late final Paint _strokePaint;
  late final Paint _fillPaint;

  Shader? _cachedShader;
  Size? _cachedShaderSize;
  Color? _cachedShaderColor;

  LineChartPainter({
    required this.prevRenderPoints,
    required this.currentRenderPoints,
    required this.progress,
    required this.color,
    required this.gradient,
    required this.prevMaxY,
    required this.currentMaxY,
    required this.axisColor,
    required this.gridColor,
    required this.labelStyle,
    required this.textDirection,
    required this.textScaler,
    required this.xLabels,
  }) {
    _strokePaint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    _fillPaint = Paint()..style = PaintingStyle.fill;
  }

  List<Point> _getInterpolatePoints(double t, double maxY) {
    if (currentRenderPoints.isEmpty) return [];

    final length = currentRenderPoints.length;
    final result = <Point>[];

    for (var i = 0; i < length; i++) {
      if (i > prevRenderPoints.length - 1) {
        final currentPoint = currentRenderPoints[i];
        result.add(
          Point(currentPoint.x, currentPoint.y * currentMaxY / maxY),
        );
      } else {
        final x = lerpDouble(
          prevRenderPoints[i].x,
          currentRenderPoints[i].x,
          t,
        )!;
        final prevY = prevRenderPoints[i].y * prevMaxY;
        final currentY = currentRenderPoints[i].y * currentMaxY;
        final y = lerpDouble(prevY, currentY, t)! / maxY;
        result.add(Point(x, y));
      }
    }

    return result;
  }

  Path _getPath(List<Point> points, Rect plotRect) {
    if (points.isEmpty) return Path();

    final path = Path()
      ..moveTo(
        plotRect.left + points[0].x * plotRect.width,
        plotRect.top + (1 - points[0].y) * plotRect.height,
      );

    if (points.length == 1) {
      path.relativeLineTo(0.001, 0);
      return path;
    }

    for (var i = 1; i < points.length; i++) {
      path.lineTo(
        plotRect.left + points[i].x * plotRect.width,
        plotRect.top + (1 - points[i].y) * plotRect.height,
      );
    }
    return path;
  }

  Path _getAnimatedPath(Rect plotRect, double maxY) {
    final interpolatedPoints = _getInterpolatePoints(progress, maxY);
    return _getPath(interpolatedPoints, plotRect);
  }

  Shader _getShader(Size size) {
    if (_cachedShader == null ||
        _cachedShaderSize != size ||
        _cachedShaderColor != color) {
      final gradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.18),
          color.withValues(alpha: 0.02),
        ],
      );

      final strokeWidth = 2.0;
      _cachedShader = gradient.createShader(
        Rect.fromLTWH(0, 0, size.width, size.height + strokeWidth * 2),
      );
      _cachedShaderSize = size;
      _cachedShaderColor = color;
    }
    return _cachedShader!;
  }

  String _formatRate(double value) {
    const units = ['B/s', 'KB/s', 'MB/s', 'GB/s', 'TB/s'];
    var scaled = value;
    var unitIndex = 0;
    while (scaled >= 1024 && unitIndex < units.length - 1) {
      scaled /= 1024;
      unitIndex++;
    }
    final decimals = scaled >= 100 || scaled == 0 ? 0 : 1;
    return '${scaled.toStringAsFixed(decimals)}${units[unitIndex]}';
  }

  TextPainter _labelPainter(String text) {
    return TextPainter(
      text: TextSpan(text: text, style: labelStyle),
      maxLines: 1,
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();
  }

  Rect _getPlotRect(Size size, double maxY) {
    final yValues = [maxY, maxY / 2, 0.0];
    final yPainters = yValues.map((value) {
      return _labelPainter(_formatRate(value));
    }).toList();
    final maxYLabelWidth = yPainters.fold<double>(
      0,
      (width, painter) => math.max(width, painter.width),
    );
    final xPainters = xLabels.map(_labelPainter).toList();
    final xLabelHeight = xPainters.fold<double>(
      0,
      (height, painter) => math.max(height, painter.height),
    );
    if (size.width <= maxYLabelWidth + 12 ||
        size.height <= xLabelHeight + 10) {
      return Rect.zero;
    }
    final plotRect = Rect.fromLTRB(
      maxYLabelWidth + 8,
      4,
      size.width - 4,
      size.height - xLabelHeight - 6,
    );
    if (plotRect.width <= 0 || plotRect.height <= 0) {
      return Rect.zero;
    }
    return plotRect;
  }

  void _drawAxes(Canvas canvas, Size size, double maxY, Rect plotRect) {
    final yValues = [maxY, maxY / 2, 0.0];
    final yPainters = yValues.map((value) {
      return _labelPainter(_formatRate(value));
    }).toList();
    final xPainters = xLabels.map(_labelPainter).toList();

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i < yValues.length; i++) {
      final y = plotRect.top + plotRect.height * i / (yValues.length - 1);
      canvas.drawLine(
        Offset(plotRect.left, y),
        Offset(plotRect.right, y),
        gridPaint,
      );
      final painter = yPainters[i];
      if (painter.height > size.height) continue;
      painter.paint(
        canvas,
        Offset(
          plotRect.left - painter.width - 6,
          (y - painter.height / 2)
              .clamp(0, size.height - painter.height)
              .toDouble(),
        ),
      );
    }

    for (var i = 0; i < xPainters.length; i++) {
      final fraction = i / (xPainters.length - 1);
      final x = plotRect.left + plotRect.width * fraction;
      canvas.drawLine(
        Offset(x, plotRect.top),
        Offset(x, plotRect.bottom),
        gridPaint,
      );
      final painter = xPainters[i];
      final labelX = painter.width >= plotRect.width
          ? plotRect.left
          : (x - painter.width / 2)
                .clamp(plotRect.left, plotRect.right - painter.width)
                .toDouble();
      painter.paint(canvas, Offset(labelX, plotRect.bottom + 4));
    }

    final axisPaint = Paint()
      ..color = axisColor
      ..strokeWidth = 1.25;
    canvas.drawLine(plotRect.bottomLeft, plotRect.bottomRight, axisPaint);
    canvas.drawLine(plotRect.topLeft, plotRect.bottomLeft, axisPaint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = 2.0;
    final maxY = lerpDouble(prevMaxY, currentMaxY, progress) ?? currentMaxY;
    final plotRect = _getPlotRect(size, maxY);
    if (plotRect.width <= 0 || plotRect.height <= 0) return;
    if (currentRenderPoints.isEmpty) {
      _drawAxes(canvas, size, maxY, plotRect);
      return;
    }
    final path = _getAnimatedPath(plotRect, maxY);

    canvas.save();
    canvas.clipRect(plotRect.inflate(strokeWidth));
    if (gradient && currentRenderPoints.length > 1) {
      final fillPath = Path.from(path);
      fillPath.lineTo(plotRect.right, plotRect.bottom);
      fillPath.lineTo(plotRect.left, plotRect.bottom);
      fillPath.close();

      _fillPaint.shader = _getShader(size);
      canvas.drawPath(fillPath, _fillPaint);
    }

    canvas.restore();

    _drawAxes(canvas, size, maxY, plotRect);

    canvas.save();
    canvas.clipRect(plotRect.inflate(strokeWidth));
    canvas.drawPath(path, _strokePaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant LineChartPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.prevRenderPoints != prevRenderPoints ||
        oldDelegate.currentRenderPoints != currentRenderPoints ||
        oldDelegate.color != color ||
        oldDelegate.gradient != gradient ||
        oldDelegate.prevMaxY != prevMaxY ||
        oldDelegate.currentMaxY != currentMaxY ||
        oldDelegate.axisColor != axisColor ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.labelStyle != labelStyle ||
        oldDelegate.textDirection != textDirection ||
        oldDelegate.textScaler != textScaler ||
        oldDelegate.xLabels != xLabels;
  }
}
