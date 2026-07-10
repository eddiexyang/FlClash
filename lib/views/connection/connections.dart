import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ConnectionColumn {
  host,
  process,
  chains,
  upload,
  download,
  time,
  action;

  String get label {
    return switch (this) {
      ConnectionColumn.host => 'Host',
      ConnectionColumn.process => 'Process',
      ConnectionColumn.chains => 'Chains',
      ConnectionColumn.upload => 'Up',
      ConnectionColumn.download => 'Down',
      ConnectionColumn.time => 'Duration',
      ConnectionColumn.action => '',
    };
  }

  // 默认初始宽度
  double get defaultWidth {
    return switch (this) {
      ConnectionColumn.host => 220,
      ConnectionColumn.process => 120,
      ConnectionColumn.chains => 240,
      ConnectionColumn.upload => 80,
      ConnectionColumn.download => 80,
      ConnectionColumn.time => 80,
      ConnectionColumn.action => 44,
    };
  }

  int compare(TrackerInfo a, TrackerInfo b) {
    switch (this) {
      case ConnectionColumn.host:
        return a.metadata.displayHost.compareTo(b.metadata.displayHost);
      case ConnectionColumn.process:
        return a.metadata.process.compareTo(b.metadata.process);
      case ConnectionColumn.chains:
        final chainA = a.chains.isEmpty ? '' : a.chains.last;
        final chainB = b.chains.isEmpty ? '' : b.chains.last;
        return chainA.compareTo(chainB);
      case ConnectionColumn.upload:
        return a.upload.compareTo(b.upload);
      case ConnectionColumn.download:
        return a.download.compareTo(b.download);
      case ConnectionColumn.time:
        return b.start.compareTo(a.start);
      case ConnectionColumn.action:
        return 0;
    }
  }
}

String _formatConnectionDuration(Duration duration) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  final hours = twoDigits(duration.inHours);
  final minutes = twoDigits(duration.inMinutes.remainder(60));
  final seconds = twoDigits(duration.inSeconds.remainder(60));
  return duration.inHours > 0
      ? '$hours:$minutes:$seconds'
      : '$minutes:$seconds';
}

class ConnectionsView extends ConsumerStatefulWidget {
  const ConnectionsView({super.key});

  @override
  ConsumerState<ConnectionsView> createState() => _ConnectionsViewState();
}

class _ConnectionsViewState extends ConsumerState<ConnectionsView> {
  Timer? _timer;
  List<TrackerInfo> _connections = [];
  bool _isDisposed = false;
  bool _isFetching = false;
  bool _fetchPending = false;
  bool _isClosingConnections = false;
  int _connectionsGeneration = 0;
  String? _lastFetchError;

  // Sorting
  ConnectionColumn _sortColumn = ConnectionColumn.time;
  bool _sortAscending = true;

  // Search
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // Vertical Scroll Controller for the list
  final ScrollController _verticalScrollController = ScrollController();
  final List<ConnectionColumn> _columns = [
    ConnectionColumn.host,
    ConnectionColumn.process,
    ConnectionColumn.chains,
    ConnectionColumn.upload,
    ConnectionColumn.download,
    ConnectionColumn.time,
    ConnectionColumn.action,
  ];

  // Column Widths State
  late Map<ConnectionColumn, double> _columnWidths;

  @override
  void initState() {
    super.initState();
    _columnWidths = {for (var col in _columns) col: col.defaultWidth};
    _startTimer();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _fetchData();
    });
    _fetchData();
  }

  Future<void> _fetchData() async {
    if (_isDisposed || _isClosingConnections) return;
    if (_isFetching) {
      _fetchPending = true;
      return;
    }

    _isFetching = true;
    try {
      do {
        _fetchPending = false;
        final generation = _connectionsGeneration;
        try {
          final rawConnections = await coreController.getConnections();
          if (_isDisposed || generation != _connectionsGeneration) {
            continue;
          }

          _lastFetchError = null;
          if (mounted) {
            setState(() {
              _connections = rawConnections;
            });
          }
        } catch (error, stackTrace) {
          final errorMessage = error.toString();
          if (_lastFetchError != errorMessage) {
            commonPrint.log(
              'get_connections_failed error=$error\n$stackTrace',
              logLevel: LogLevel.warning,
            );
            _lastFetchError = errorMessage;
          }
        }
      } while (_fetchPending && !_isDisposed && !_isClosingConnections);
    } finally {
      _isFetching = false;
    }
  }

  void _handleSort(ConnectionColumn column) {
    if (column == ConnectionColumn.action) return;
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

  List<TrackerInfo> get _filteredAndSortedConnections {
    var list = _connections;
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((info) {
        final host = info.metadata.displayHost.toLowerCase();
        final sniffHost = info.metadata.sniffHost.toLowerCase();
        final ip = info.metadata.destinationIP.toLowerCase();
        final process = info.metadata.process.toLowerCase();
        final port = info.metadata.destinationPort.toLowerCase();
        final remotePort = _extractRemotePort(
          info.metadata.nextHop,
        ).toLowerCase();
        final rule = info.rule.toLowerCase();
        final chains = info.chains.join(' ').toLowerCase();
        final time = info.start.toString().toLowerCase();
        final hostOrIp = host.isEmpty ? ip : host;
        final hostWithPort = '$hostOrIp:$port';

        return hostWithPort.contains(q) ||
            sniffHost.contains(q) ||
            (remotePort.isNotEmpty && remotePort.contains(q)) ||
            process.contains(q) ||
            rule.contains(q) ||
            chains.contains(q) ||
            time.contains(q);
      }).toList();
    }

    final sortedList = List<TrackerInfo>.from(list);
    sortedList.sort((a, b) {
      final compare = _sortColumn.compare(a, b);
      return _sortAscending ? compare : -compare;
    });
    return sortedList;
  }

  Future<void> _closeAllConnections() async {
    if (_isClosingConnections) return;
    _connectionsGeneration++;
    setState(() {
      _isClosingConnections = true;
    });
    try {
      final success = await coreController.closeConnections();
      if (!success) {
        commonPrint.log(
          'close_all_connections completed with errors',
          logLevel: LogLevel.warning,
        );
      }
    } catch (error, stackTrace) {
      commonPrint.log(
        'close_all_connections_failed error=$error\n$stackTrace',
        logLevel: LogLevel.error,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isClosingConnections = false;
        });
      } else {
        _isClosingConnections = false;
      }
    }

    if (mounted) {
      await _fetchData();
    }
  }

  void _showConnectionDetails(TrackerInfo info) {
    showExtend(
      context,
      builder: (_, type) {
        return AdaptiveSheetScaffold(
          type: type,
          body: TrackerInfoDetailView(trackerInfo: info),
          title: appLocalizations.details(appLocalizations.connection),
        );
      },
    );
  }

  @override
  void dispose() {
    _isDisposed = true;
    _timer?.cancel();
    _searchController.dispose();
    _verticalScrollController.dispose();
    super.dispose();
  }

  String _extractRemotePort(String remoteDestination) {
    if (remoteDestination.isEmpty) return '';
    final lastColon = remoteDestination.lastIndexOf(':');
    if (lastColon == -1 || lastColon == remoteDestination.length - 1) return '';
    final portPart = remoteDestination.substring(lastColon + 1).trim();
    if (int.tryParse(portPart) == null) return '';
    return portPart;
  }

  @override
  Widget build(BuildContext context) {
    final connections = _filteredAndSortedConnections;

    return CommonScaffold(
      title: appLocalizations.connections,
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
          tooltip: appLocalizations.closeConnections,
          onPressed: _isClosingConnections ? null : _closeAllConnections,
          icon: _isClosingConnections
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.delete_sweep_outlined),
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
            if (totalFixedWidth > 0 && constraints.maxWidth > 0) {
              scaleRatio = constraints.maxWidth / totalFixedWidth;
            }

            final effectiveColumnWidths = {
              for (var col in _columns)
                col: (_columnWidths[col] ?? col.defaultWidth) * scaleRatio,
            };

            return Column(
              children: [
                Expanded(
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
                        child: connections.isEmpty
                            ? Center(child: Text(appLocalizations.noData))
                            : ListView.builder(
                                controller: _verticalScrollController,
                                itemCount: connections.length,
                                itemExtent: 32,
                                itemBuilder: (context, index) {
                                  final info = connections[index];
                                  return _ConnectionRow(
                                    key: ValueKey(info.id),
                                    info: info,
                                    columns: _columns,
                                    columnWidths: effectiveColumnWidths,
                                    onTap: () => _showConnectionDetails(info),
                                    onClose: () async {
                                      _connectionsGeneration++;
                                      final success = await coreController
                                          .closeConnection(info.id);
                                      if (!mounted) return;
                                      if (success) {
                                        setState(() {
                                          _connections.removeWhere(
                                            (item) => item.id == info.id,
                                          );
                                        });
                                      }
                                      await _fetchData();
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                // Footer
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  color: context.colorScheme.surfaceContainer,
                  child: Row(
                    children: [
                      Text(
                        'Total: ${_connections.length}',
                        style: context.textTheme.labelMedium,
                      ),
                      const Spacer(),
                      Text(
                        'Down: ${_connections.fold<int>(0, (p, c) => p + c.download).traffic.show}',
                        style: context.textTheme.labelSmall,
                      ),
                      const SizedBox(width: 16),
                      Text(
                        'Up: ${_connections.fold<int>(0, (p, c) => p + c.upload).traffic.show}',
                        style: context.textTheme.labelSmall,
                      ),
                    ],
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
  final List<ConnectionColumn> columns;
  final Map<ConnectionColumn, double> columnWidths;
  final ConnectionColumn sortColumn;
  final bool isAscending;
  final ValueChanged<ConnectionColumn> onSort;
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
          final isAction = col == ConnectionColumn.action;
          final isLast = index == columns.length - 1;

          return SizedBox(
            width: width,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: InkWell(
                    onTap: isAction ? null : () => onSort(col),
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

class _ConnectionRow extends StatelessWidget {
  final TrackerInfo info;
  final List<ConnectionColumn> columns;
  final Map<ConnectionColumn, double> columnWidths;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _ConnectionRow({
    super.key,
    required this.info,
    required this.columns,
    required this.columnWidths,
    required this.onTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final dataColumns = columns
        .where((column) => column != ConnectionColumn.action)
        .toList();
    final actionColumns = columns
        .where((column) => column == ConnectionColumn.action)
        .toList();

    Widget buildCell(ConnectionColumn column) {
      return SizedBox(
        width: columnWidths[column],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.centerLeft,
          child: _buildCell(context, column, info, textTheme, colorScheme),
        ),
      );
    }

    return Row(
      children: [
        SelectionTapRegion(
          onTap: onTap,
          hoverColor: colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.5,
          ),
          child: Row(children: dataColumns.map(buildCell).toList()),
        ),
        ...actionColumns.map(buildCell),
      ],
    );
  }

  String _formatDuration(Duration d) {
    return _formatConnectionDuration(d);
  }

  Widget _buildCell(
    BuildContext context,
    ConnectionColumn col,
    TrackerInfo info,
    TextTheme textTheme,
    ColorScheme colorScheme,
  ) {
    final style = textTheme.bodySmall?.copyWith(
      fontFamily: FontFamily.jetBrainsMono.value,
      overflow: TextOverflow.ellipsis,
    );

    switch (col) {
      case ConnectionColumn.process:
        return Text(info.metadata.process, style: style);
      case ConnectionColumn.host:
        final host = info.metadata.displayHost;
        final port = info.metadata.destinationPort;
        return Text('$host:$port', style: style);
      case ConnectionColumn.chains:
        return Text(
          info.chains.reversed.join(' → '),
          style: style?.copyWith(color: colorScheme.secondary),
        );
      case ConnectionColumn.upload:
        final total = info.upload;
        return Text(
          total == 0 ? '-' : total.traffic.show,
          style: style?.copyWith(color: Colors.grey),
        );
      case ConnectionColumn.download:
        final total = info.download;
        return Text(
          total == 0 ? '-' : total.traffic.show,
          style: style?.copyWith(color: Colors.green),
        );
      case ConnectionColumn.time:
        final duration = DateTime.now().difference(info.start);
        return Text(_formatDuration(duration), style: style);
      case ConnectionColumn.action:
        return IconButton(
          icon: Icon(Icons.close, size: 16, color: colorScheme.error),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          tooltip: context.appLocalizations.closeConnection,
          onPressed: onClose,
        );
    }
  }
}

// 2. 原版 TrackerInfoDetailView
class TrackerInfoDetailView extends StatelessWidget {
  final TrackerInfo trackerInfo;

  const TrackerInfoDetailView({super.key, required this.trackerInfo});

  String _getRuleText() {
    final rule = trackerInfo.rule;
    final rulePayload = trackerInfo.rulePayload;
    if (rulePayload.isNotEmpty) {
      return '$rule($rulePayload)';
    }
    return rule;
  }

  String _getProcessText() {
    final process = trackerInfo.metadata.process;
    final uid = trackerInfo.metadata.uid;
    if (uid != 0) {
      return '$process($uid)';
    }
    return process;
  }

  String _getSourceText() {
    final sourceIP = trackerInfo.metadata.sourceIP;
    if (sourceIP.isEmpty) {
      return '';
    }
    final sourcePort = trackerInfo.metadata.sourcePort;
    if (sourcePort.isNotEmpty) {
      return '$sourceIP:$sourcePort';
    }
    return sourceIP;
  }

  String _getDestinationText() {
    final destinationIP = trackerInfo.metadata.destinationIP;
    if (destinationIP.isEmpty) {
      return '';
    }
    final destinationPort = trackerInfo.metadata.destinationPort;
    if (destinationPort.isNotEmpty) {
      return '$destinationIP:$destinationPort';
    }
    return destinationIP;
  }

  Widget _buildChains(BuildContext context) {
    return ListItem(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 20,
        children: [
          Text(appLocalizations.proxyChains),
          Flexible(
            child: Text(
              trackerInfo.chains.reversed.join(' → '),
              textAlign: TextAlign.end,
              style: context.textTheme.bodyMedium?.copyWith(
                color: context.colorScheme.secondary,
                fontFamily: FontFamily.jetBrainsMono.value,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItem({
    required String title,
    required String desc,
    bool quickCopy = false,
  }) {
    return ListItem(
      title: Row(
        spacing: 16,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            spacing: 4,
            children: [
              Text(title),
              if (quickCopy)
                Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    icon: Icon(Icons.content_copy, size: 18),
                    onPressed: () {},
                  ),
                ),
            ],
          ),
          Flexible(child: Text(desc, textAlign: TextAlign.end)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      _buildItem(
        title: appLocalizations.creationTime,
        desc: trackerInfo.start.showFull,
      ),
      if (_getProcessText().isNotEmpty)
        _buildItem(title: appLocalizations.process, desc: _getProcessText()),
      _buildItem(
        title: appLocalizations.networkType,
        desc: trackerInfo.metadata.network,
      ),
      _buildItem(title: appLocalizations.rule, desc: _getRuleText()),
      if (trackerInfo.metadata.domain.isNotEmpty)
        _buildItem(
          title: appLocalizations.host,
          desc: trackerInfo.metadata.domain,
        ),
      if (_getSourceText().isNotEmpty)
        _buildItem(title: appLocalizations.source, desc: _getSourceText()),
      if (_getDestinationText().isNotEmpty)
        _buildItem(
          title: appLocalizations.destination,
          desc: _getDestinationText(),
        ),
      _buildItem(
        title: appLocalizations.upload,
        desc: trackerInfo.upload.traffic.show,
      ),
      _buildItem(
        title: appLocalizations.download,
        desc: trackerInfo.download.traffic.show,
      ),
      if (trackerInfo.metadata.destinationGeoIP.isNotEmpty)
        _buildItem(
          title: appLocalizations.destinationGeoIP,
          desc: trackerInfo.metadata.destinationGeoIP.join(' '),
        ),
      if (trackerInfo.metadata.destinationIPASN.isNotEmpty)
        _buildItem(
          title: appLocalizations.destinationIPASN,
          desc: trackerInfo.metadata.destinationIPASN,
        ),
      if (trackerInfo.metadata.dnsMode != null)
        _buildItem(
          title: appLocalizations.dnsMode,
          desc: trackerInfo.metadata.dnsMode!.name,
        ),
      if (trackerInfo.metadata.specialProxy.isNotEmpty)
        _buildItem(
          title: appLocalizations.specialProxy,
          desc: trackerInfo.metadata.specialProxy,
        ),
      if (trackerInfo.metadata.specialRules.isNotEmpty)
        _buildItem(
          title: appLocalizations.specialRules,
          desc: trackerInfo.metadata.specialRules,
        ),
      if (trackerInfo.metadata.nextHop.isNotEmpty)
        _buildItem(
          title: appLocalizations.remoteDestination,
          desc: trackerInfo.metadata.nextHop,
        ),
      _buildChains(context),
    ];
    return SelectionArea(
      child: ListView.builder(
        padding: EdgeInsets.symmetric(vertical: 12),
        itemCount: items.length,
        itemBuilder: (_, index) {
          return items[index];
        },
      ),
    );
  }
}
