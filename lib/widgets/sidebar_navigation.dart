import 'package:flutter/material.dart';

@immutable
class SidebarNavigationDestination {
  final Widget icon;
  final Widget label;
  final String tooltip;

  const SidebarNavigationDestination({
    required this.icon,
    required this.label,
    required this.tooltip,
  });
}

class SidebarNavigation extends StatelessWidget {
  static const double width = 80;

  final List<SidebarNavigationDestination> destinations;
  final int selectedIndex;
  final bool showLabels;
  final ValueChanged<int> onDestinationSelected;

  const SidebarNavigation({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.showLabels,
    required this.onDestinationSelected,
  }) : assert(selectedIndex >= 0),
       assert(selectedIndex < destinations.length);

  Widget _buildDestination(BuildContext context, int index) {
    final destination = destinations[index];
    final selected = index == selectedIndex;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final labelStyle = theme.textTheme.labelLarge?.copyWith(
      color: colorScheme.onSurface,
    );
    final content = InkWell(
      key: ValueKey(index),
      mouseCursor: WidgetStateMouseCursor.clickable,
      borderRadius: BorderRadius.circular(28),
      onTap: () => onDestinationSelected(index),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              width: 56,
              height: 32,
              duration: kThemeAnimationDuration,
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: selected
                    ? colorScheme.secondaryContainer
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: IconTheme(
                data: IconThemeData(
                  size: 24,
                  color: selected
                      ? colorScheme.onSecondaryContainer
                      : colorScheme.onSurfaceVariant,
                ),
                child: destination.icon,
              ),
            ),
            if (showLabels) ...[
              const SizedBox(height: 4),
              DefaultTextStyle(
                style: labelStyle ?? const TextStyle(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                child: destination.label,
              ),
            ],
          ],
        ),
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      child: showLabels
          ? content
          : Tooltip(message: destination.tooltip, child: content),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: destinations.length,
        itemBuilder: _buildDestination,
      ),
    );
  }
}
