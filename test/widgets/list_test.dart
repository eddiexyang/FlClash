import 'package:fl_clash/widgets/card.dart';
import 'package:fl_clash/widgets/list.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Future<MouseCursor?> activeCursorOverListItem(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(find.byType(ListTile)));
  await tester.pump();
  return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
}

void main() {
  testWidgets('profile item content inherits its clickable card cursor', (
    tester,
  ) async {
    var tapCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: CommonCard(
            isSelected: true,
            onPressed: () => tapCount++,
            child: const ListItem<void>(title: Text('Profile')),
          ),
        ),
      ),
    );

    expect(await activeCursorOverListItem(tester), SystemMouseCursors.click);
    await tester.tap(find.byType(ListTile));
    expect(tapCount, 1);
  });

  testWidgets('standalone passive list item keeps the basic cursor', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Material(
          child: ListItem<void>(title: Text('Profile')),
        ),
      ),
    );

    expect(await activeCursorOverListItem(tester), SystemMouseCursors.basic);
  });
}
