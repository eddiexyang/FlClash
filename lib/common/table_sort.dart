typedef ColumnComparator<C, T> = int Function(C column, T a, T b);

class TableSortState<C> {
  final C primaryColumn;
  final bool primaryAscending;
  final C? secondaryColumn;
  final bool secondaryAscending;

  const TableSortState({
    required this.primaryColumn,
    this.primaryAscending = true,
    this.secondaryColumn,
    this.secondaryAscending = true,
  });

  TableSortState<C> select(C column) {
    if (column == primaryColumn) {
      return TableSortState(
        primaryColumn: primaryColumn,
        primaryAscending: !primaryAscending,
        secondaryColumn: secondaryColumn,
        secondaryAscending: secondaryAscending,
      );
    }

    return TableSortState(
      primaryColumn: column,
      secondaryColumn: primaryColumn,
      secondaryAscending: primaryAscending,
    );
  }

  int compare<T>(T a, T b, ColumnComparator<C, T> compareColumn) {
    final primaryResult = compareColumn(primaryColumn, a, b);
    if (primaryResult != 0) {
      return primaryAscending ? primaryResult : -primaryResult;
    }

    final secondaryColumn = this.secondaryColumn;
    if (secondaryColumn == null) {
      return 0;
    }

    final secondaryResult = compareColumn(secondaryColumn, a, b);
    return secondaryAscending ? secondaryResult : -secondaryResult;
  }
}
