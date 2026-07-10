import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class SelectionTapRegion extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final Color? hoverColor;

  const SelectionTapRegion({
    super.key,
    required this.child,
    this.onTap,
    this.hoverColor,
  });

  @override
  State<SelectionTapRegion> createState() => _SelectionTapRegionState();
}

class _SelectionTapRegionState extends State<SelectionTapRegion> {
  static const _dragThreshold = 4.0;

  int? _pointer;
  Offset? _downPosition;
  bool _hovered = false;

  void _handlePointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryMouseButton) return;
    _pointer = event.pointer;
    _downPosition = event.position;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_pointer != event.pointer || _downPosition == null) return;
    if ((event.position - _downPosition!).distance > _dragThreshold) {
      _clearPointer();
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_pointer == event.pointer && _downPosition != null) {
      widget.onTap?.call();
    }
    _clearPointer();
  }

  void _clearPointer() {
    _pointer = null;
    _downPosition = null;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        onPointerCancel: (_) => _clearPointer(),
        child: ColoredBox(
          color: _hovered
              ? widget.hoverColor ?? Colors.transparent
              : Colors.transparent,
          child: widget.child,
        ),
      ),
    );
  }
}
