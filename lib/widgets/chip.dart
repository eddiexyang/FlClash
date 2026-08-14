import 'package:fl_clash/enum/enum.dart';
import 'package:flutter/material.dart';

class CommonChip extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final ChipType type;
  final Widget? avatar;
  final TextStyle? labelStyle;

  const CommonChip({
    super.key,
    required this.label,
    this.labelStyle,
    this.onPressed,
    this.avatar,
    this.type = ChipType.action,
  });

  @override
  Widget build(BuildContext context) {
    if (type == ChipType.delete) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Chip(
          avatar: avatar,
          labelPadding: const EdgeInsets.symmetric(
            vertical: 0,
            horizontal: 4,
          ),
          clipBehavior: Clip.antiAlias,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onDeleted: onPressed ?? () {},
          labelStyle: labelStyle,
          label: Text(label),
        ),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: ActionChip(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        avatar: avatar,
        clipBehavior: Clip.antiAlias,
        labelPadding: const EdgeInsets.symmetric(
          vertical: 0,
          horizontal: 4,
        ),
        onPressed: onPressed ?? () {},
        labelStyle: labelStyle,
        label: Text(label),
      ),
    );
  }
}
