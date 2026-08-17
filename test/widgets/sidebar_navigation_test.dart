import 'package:fl_clash/widgets/sidebar_navigation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('sidebar destinations use the click cursor and remain tappable', (
    tester,
  ) async {
    final selectedIndexes = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: SidebarNavigation(
            selectedIndex: 1,
            showLabels: true,
            onDestinationSelected: selectedIndexes.add,
            destinations: const [
              SidebarNavigationDestination(
                icon: Icon(Icons.article),
                label: Text('Proxies'),
                tooltip: 'Proxies',
              ),
              SidebarNavigationDestination(
                icon: Icon(Icons.folder),
                label: Text('Profiles'),
                tooltip: 'Profiles',
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(SidebarNavigation)).width,
      SidebarNavigation.width,
    );

    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    for (var index = 0; index < 2; index++) {
      final destination = find.byKey(ValueKey(index));
      await gesture.moveTo(tester.getCenter(destination));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );
      await tester.tap(destination);
    }
    expect(selectedIndexes, [0, 1]);
  });

  testWidgets('sidebar hides labels behind tooltips', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: SidebarNavigation(
            selectedIndex: 0,
            showLabels: false,
            onDestinationSelected: (_) {},
            destinations: const [
              SidebarNavigationDestination(
                icon: Icon(Icons.article),
                label: Text('Proxies'),
                tooltip: 'Proxies',
              ),
              SidebarNavigationDestination(
                icon: Icon(Icons.folder),
                label: Text('Profiles'),
                tooltip: 'Profiles',
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Proxies'), findsNothing);
    expect(find.text('Profiles'), findsNothing);
    expect(find.byType(Tooltip), findsNWidgets(2));
  });
}
