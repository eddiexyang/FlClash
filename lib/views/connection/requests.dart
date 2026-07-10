import 'dart:math';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:fl_clash/views/connection/connections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

enum RequestColumn {
  time,
  host,
  process,
  rule,
  chains;

  String get label {
    return switch (this) {
      RequestColumn.time => 'Time',
      RequestColumn.host => 'Host',
      RequestColumn.process => 'Process',
      RequestColumn.rule => 'Rule',
      RequestColumn.chains => 'Chains',
    };
  }

  double get defaultWidth {
    return switch (this) {
      RequestColumn.time => 160,
      RequestColumn.host => 220,
      RequestColumn.process => 120,
      RequestColumn.rule => 140,
      RequestColumn.chains => 180,
    };
  }

  int compare(TrackerInfo a, TrackerInfo b) {
    switch (this) {
      case RequestColumn.time:
        return b.start.compareTo(a.start);
      case RequestColumn.host:
        return a.metadata.displayHost.compareTo(b.metadata.displayHost);
      case RequestColumn.process:
        return a.metadata.process.compareTo(b.metadata.process);
      case RequestColumn.rule:
        return a.rule.compareTo(b.rule);
      case RequestColumn.chains:
        return a.chains.last.compareTo(b.chains.last);
    }
  }
}

class RequestsView extends ConsumerStatefulWidget {
  const RequestsView({super.key});

  @override
  ConsumerState<RequestsView> createState() => _RequestsViewState();
}

class _RequestsViewState extends ConsumerState<RequestsView> {
  static const double _rowExtent = 32;

  // Data State
  List<TrackerInfo> _requests = [];
  List<TrackerInfo>? _cachedRequests;
  bool _isLive = true;

  // Search
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // Sorting
  RequestColumn _sortColumn = RequestColumn.time;
  bool _sortAscending = true; // 默认时间倒序(也就是最新的在上面)

  // Scrolling
  final ScrollController _verticalScrollController = ScrollController();
  final ScrollController _horizontalScrollController = ScrollController();

  // Columns
  final List<RequestColumn> _columns = RequestColumn.values;
  late Map<RequestColumn, double> _columnWidths;

  @override
  void initState() {
    super.initState();
    _columnWidths = {for (var col in _columns) col: col.defaultWidth};

    // 初始化数据
    _requests = ref.read(requestsProvider).list;
    _verticalScrollController.addListener(_syncLiveStateFromScroll);

    // 监听数据源变化
    ref.listenManual(requestsProvider.select((state) => state.list), (
      prev,
      next,
    ) {
      // 使用 throttler 避免过于频繁刷新导致表格重绘卡顿
      throttler.call(FunctionTag.requests, () {
        if (!mounted) return;
        if (trackerInfoListEquality.equals(_requests, next)) return;
        if (_isLive && _isAtTop) {
          _cachedRequests = null;
          setState(() {
            _requests = next;
          });
          return;
        }
        _cachedRequests = next;
      }, duration: commonDuration);
    });
  }

  bool get _isAtTop {
    if (!_verticalScrollController.hasClients) {
      return true;
    }
    final position = _verticalScrollController.position;
    return (position.pixels - position.minScrollExtent).abs() <= 1;
  }

  void _syncLiveStateFromScroll() {
    if (!mounted) {
      return;
    }

    if (!_isAtTop) {
      if (_isLive) {
        setState(() {
          _isLive = false;
        });
      }
      return;
    }

    _resumeLiveAtTop();
  }

  void _resumeLiveAtTop() {
    if (!mounted) {
      return;
    }
    final cachedRequests = _cachedRequests;
    final hasNewRequests =
        cachedRequests != null &&
        !trackerInfoListEquality.equals(_requests, cachedRequests);
    if (_isLive && !hasNewRequests) {
      _cachedRequests = null;
      return;
    }
    setState(() {
      _isLive = true;
      if (hasNewRequests) {
        _requests = cachedRequests;
      }
      _cachedRequests = null;
    });
  }

  void _pauseLive() {
    if (!_isLive) {
      return;
    }
    setState(() {
      _isLive = false;
    });
  }

  Future<void> _resumeLive() async {
    if (_verticalScrollController.hasClients && !_isAtTop) {
      final position = _verticalScrollController.position;
      await _verticalScrollController.animateTo(
        position.minScrollExtent,
        duration: kThemeAnimationDuration,
        curve: Curves.easeOut,
      );
    }
    _resumeLiveAtTop();
  }

  void _handleSort(RequestColumn column) {
    setState(() {
      if (_sortColumn == column) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumn = column;
        _sortAscending = true;
      }
    });
  }

  void _handleResize(int columnIndex, double delta) {
    if (columnIndex < 0 || columnIndex >= _columns.length - 1) return;

    setState(() {
      final leftColumn = _columns[columnIndex];
      final rightColumn = _columns[columnIndex + 1];

      final leftWidth = _columnWidths[leftColumn]!;
      final rightWidth = _columnWidths[rightColumn]!;

      const minWidth = 40.0;
      var newLeftWidth = leftWidth + delta;
      var newRightWidth = rightWidth - delta;

      if (newLeftWidth < minWidth) {
        newLeftWidth = minWidth;
        newRightWidth = leftWidth + rightWidth - minWidth;
      }
      if (newRightWidth < minWidth) {
        newRightWidth = minWidth;
        newLeftWidth = leftWidth + rightWidth - minWidth;
      }

      _columnWidths[leftColumn] = newLeftWidth;
      _columnWidths[rightColumn] = newRightWidth;
    });
  }

  List<TrackerInfo> _filterAndSortRequests(List<TrackerInfo> source) {
    var list = source;

    // Search
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((info) {
        final host = info.metadata.displayHost.toLowerCase();
        final sniffHost = info.metadata.sniffHost.toLowerCase();
        final ip = info.metadata.destinationIP.toLowerCase();
        final process = info.metadata.process.toLowerCase();
        final rule = info.rule.toLowerCase();
        final chains = info.chains.join(' ').toLowerCase();
        final time = DateFormat(
          'yyyy-MM-dd HH:mm:ss',
        ).format(info.start.toLocal()).toLowerCase();
        final port = info.metadata.destinationPort.toLowerCase();
        final hostOrIp = host.isEmpty ? ip : host;
        final hostWithPort = '$hostOrIp:$port';

        return hostWithPort.contains(q) ||
            sniffHost.contains(q) ||
            process.contains(q) ||
            rule.contains(q) ||
            chains.contains(q) ||
            time.contains(q);
      }).toList();
    }

    // Sort
    final sortedList = List<TrackerInfo>.from(list);
    sortedList.sort((a, b) {
      final compare = _sortColumn.compare(a, b);
      return _sortAscending ? compare : -compare;
    });

    return sortedList;
  }

  List<TrackerInfo> get _filteredAndSortedRequests {
    return _filterAndSortRequests(_requests);
  }

  void _showRequestDetails(TrackerInfo info) {
    showExtend(
      context,
      builder: (_, type) {
        return AdaptiveSheetScaffold(
          type: type,
          body: TrackerInfoDetailView(trackerInfo: info),
          title: appLocalizations.details(appLocalizations.request),
        );
      },
    );
  }

  void _clearRequests() {
    ref.read(requestsProvider.notifier).value = FixedList(maxLength);
    setState(() {
      _requests = [];
      _cachedRequests = null;
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _verticalScrollController.removeListener(_syncLiveStateFromScroll);
    _verticalScrollController.dispose();
    _horizontalScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final requests = _filteredAndSortedRequests;

    return CommonScaffold(
      title: appLocalizations.requests,
      actions: [
        SizedBox(
          width: 200,
          height: 36,
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              hintText: appLocalizations.search,
              prefixIcon: const Icon(Icons.search, size: 18),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          _searchQuery = '';
                        });
                      },
                    )
                  : null,
            ),
            style: const TextStyle(fontSize: 14),
            onChanged: (value) {
              setState(() {
                _searchQuery = value;
              });
            },
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: _isLive ? 'Pause live updates' : 'Resume live updates',
          onPressed: _isLive ? _pauseLive : _resumeLive,
          icon: Icon(
            _isLive
                ? Icons.pause_circle_outline_rounded
                : Icons.play_circle_outline_rounded,
          ),
        ),
        IconButton(
          tooltip: appLocalizations.clearData,
          onPressed: _clearRequests,
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
        const SizedBox(width: 8),
      ],
      body: SelectionArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final totalFixedWidth = _columns.fold<double>(
              0,
              (sum, col) => sum + (_columnWidths[col] ?? col.defaultWidth),
            );

            double scaleRatio = 1.0;
            if (constraints.maxWidth > totalFixedWidth) {
              scaleRatio = constraints.maxWidth / totalFixedWidth;
            }

            final effectiveColumnWidths = {
              for (var col in _columns)
                col: (_columnWidths[col] ?? col.defaultWidth) * scaleRatio,
            };

            final contentWidth = max(constraints.maxWidth, totalFixedWidth);

            return Column(
              children: [
                Expanded(
                  child: Scrollbar(
                    controller: _verticalScrollController,
                    thumbVisibility: true,
                    child: Scrollbar(
                      controller: _horizontalScrollController,
                      thumbVisibility: true,
                      notificationPredicate: (notification) =>
                          notification.depth == 1,
                      child: SingleChildScrollView(
                        controller: _horizontalScrollController,
                        scrollDirection: Axis.horizontal,
                        physics: scaleRatio > 1.0
                            ? const NeverScrollableScrollPhysics()
                            : const ClampingScrollPhysics(),
                        child: SizedBox(
                          width: contentWidth,
                          child: Column(
                            children: [
                              _ResizableHeaderRow(
                                columns: _columns,
                                columnWidths: effectiveColumnWidths,
                                sortColumn: _sortColumn,
                                isAscending: _sortAscending,
                                onSort: _handleSort,
                                onResizeDelta: (index, delta) {
                                  _handleResize(index, delta / scaleRatio);
                                },
                              ),
                              const Divider(height: 1),
                              Expanded(
                                child: requests.isEmpty
                                    ? Center(
                                        child: Text(appLocalizations.noData),
                                      )
                                    : ListView.builder(
                                        controller: _verticalScrollController,
                                        itemCount: requests.length,
                                        itemExtent: _rowExtent,
                                        itemBuilder: (context, index) {
                                          final info = requests[index];
                                          return _RequestRow(
                                            key: ValueKey(info.id),
                                            info: info,
                                            columns: _columns,
                                            columnWidths: effectiveColumnWidths,
                                            onTap: () =>
                                                _showRequestDetails(info),
                                          );
                                        },
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ResizableHeaderRow extends StatelessWidget {
  final List<RequestColumn> columns;
  final Map<RequestColumn, double> columnWidths;
  final RequestColumn sortColumn;
  final bool isAscending;
  final ValueChanged<RequestColumn> onSort;
  final Function(int, double) onResizeDelta;

  const _ResizableHeaderRow({
    required this.columns,
    required this.columnWidths,
    required this.sortColumn,
    required this.isAscending,
    required this.onSort,
    required this.onResizeDelta,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      color: Theme.of(context).colorScheme.surface,
      child: Row(
        children: columns.asMap().entries.map((entry) {
          final index = entry.key;
          final col = entry.value;
          final width = columnWidths[col]!;
          final isSorted = col == sortColumn;
          final isLast = index == columns.length - 1;

          return SizedBox(
            width: width,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: InkWell(
                    onTap: () => onSort(col),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              col.label,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: isSorted
                                        ? Theme.of(context).colorScheme.primary
                                        : null,
                                  ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isSorted)
                            Icon(
                              isAscending
                                  ? Icons.arrow_upward
                                  : Icons.arrow_downward,
                              size: 14,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (!isLast)
                  Positioned(
                    right: 0,
                    top: 6,
                    bottom: 6,
                    child: Container(
                      width: 1,
                      color: Theme.of(
                        context,
                      ).dividerColor.withValues(alpha: 0.5),
                    ),
                  ),
                if (!isLast)
                  Positioned(
                    right: -4,
                    top: 0,
                    bottom: 0,
                    width: 9,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeColumn,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragUpdate: (details) {
                          if (details.primaryDelta != null) {
                            onResizeDelta(index, details.primaryDelta!);
                          }
                        },
                        child: Container(color: Colors.transparent),
                      ),
                    ),
                  ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _RequestRow extends StatelessWidget {
  final TrackerInfo info;
  final List<RequestColumn> columns;
  final Map<RequestColumn, double> columnWidths;
  final VoidCallback onTap;

  const _RequestRow({
    super.key,
    required this.info,
    required this.columns,
    required this.columnWidths,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return SelectionTapRegion(
      onTap: onTap,
      hoverColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Row(
        children: columns.map((col) {
          return SizedBox(
            width: columnWidths[col],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.centerLeft,
              child: _buildCell(context, col, info, textTheme, colorScheme),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildCell(
    BuildContext context,
    RequestColumn col,
    TrackerInfo info,
    TextTheme textTheme,
    ColorScheme colorScheme,
  ) {
    final style = textTheme.bodySmall?.copyWith(
      fontFamily: FontFamily.jetBrainsMono.value,
      overflow: TextOverflow.ellipsis,
    );

    switch (col) {
      case RequestColumn.time:
        return Text(
          DateFormat('yyyy-MM-dd HH:mm:ss').format(info.start.toLocal()),
          style: style,
        );
      case RequestColumn.process:
        return Text(info.metadata.process, style: style);
      case RequestColumn.host:
        final host = info.metadata.displayHost;
        final ip = info.metadata.destinationIP;
        final port = info.metadata.destinationPort;
        if (info.metadata.domain.isNotEmpty) {
          return Tooltip(
            message: '$host:$port ($ip)',
            waitDuration: const Duration(milliseconds: 500),
            child: Text('$host:$port', style: style),
          );
        }
        return Text('$ip:$port', style: style);
      case RequestColumn.rule:
        return Text(info.rule, style: style);
      case RequestColumn.chains:
        return Tooltip(
          message: info.chains.reversed.join(' → '),
          waitDuration: const Duration(milliseconds: 500),
          child: Text(
            info.chains.reversed.join(' → '),
            style: style?.copyWith(color: colorScheme.secondary),
          ),
        );
    }
  }
}
