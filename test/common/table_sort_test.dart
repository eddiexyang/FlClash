import 'package:fl_clash/common/table_sort.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TableSortState', () {
    test('keeps the previous primary sort as the secondary sort', () {
      const initial = TableSortState<String>(primaryColumn: 'time');

      final next = initial.select('host');

      expect(next.primaryColumn, 'host');
      expect(next.primaryAscending, isTrue);
      expect(next.secondaryColumn, 'time');
      expect(next.secondaryAscending, isTrue);
    });

    test('preserves the direction of the previous sort', () {
      final initial = const TableSortState<String>(
        primaryColumn: 'time',
      ).select('time');

      final next = initial.select('host');

      expect(next.primaryColumn, 'host');
      expect(next.secondaryColumn, 'time');
      expect(next.secondaryAscending, isFalse);
    });

    test('toggling the primary sort leaves the secondary sort unchanged', () {
      final initial = const TableSortState<String>(
        primaryColumn: 'time',
      ).select('host');

      final next = initial.select('host');

      expect(next.primaryColumn, 'host');
      expect(next.primaryAscending, isFalse);
      expect(next.secondaryColumn, 'time');
      expect(next.secondaryAscending, isTrue);
    });

    test('uses the secondary sort to break primary ties', () {
      final sort = const TableSortState<String>(
        primaryColumn: 'name',
        secondaryColumn: 'time',
        secondaryAscending: false,
      );
      final values = [
        (name: 'B', time: 1),
        (name: 'A', time: 1),
        (name: 'A', time: 3),
        (name: 'A', time: 2),
      ];

      values.sort(
        (a, b) => sort.compare(a, b, (column, a, b) {
          return switch (column) {
            'name' => a.name.compareTo(b.name),
            'time' => a.time.compareTo(b.time),
            _ => 0,
          };
        }),
      );

      expect(values, [
        (name: 'A', time: 3),
        (name: 'A', time: 2),
        (name: 'A', time: 1),
        (name: 'B', time: 1),
      ]);
    });

    test('replaces the secondary sort when a third column is selected', () {
      final sort = const TableSortState<String>(
        primaryColumn: 'time',
      ).select('host').select('process');

      expect(sort.primaryColumn, 'process');
      expect(sort.secondaryColumn, 'host');
    });
  });
}
