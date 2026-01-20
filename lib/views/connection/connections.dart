import 'dart:async';
import 'dart:math';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

enum ConnectionColumn {
  host,
  process,
  rule,
  chains,
  uploadSpeed,
  downloadSpeed,
  time,
  source,
  action;

  String get label {
    return switch (this) {
      ConnectionColumn.host => 'Host',
      ConnectionColumn.process => 'Process',
      ConnectionColumn.rule => 'Rule',
      ConnectionColumn.chains => 'Chains',
      ConnectionColumn.uploadSpeed => 'Up/s',
      ConnectionColumn.downloadSpeed => 'Down/s',
      ConnectionColumn.time => 'Duration',
      ConnectionColumn.action => 'Action',
    };
  }

  // 默认初始宽度
  double get defaultWidth {
    return switch (this) {
      ConnectionColumn.host => 220,
      ConnectionColumn.process => 120,
      ConnectionColumn.rule => 140,
      ConnectionColumn.chains => 180,
      ConnectionColumn.uploadSpeed => 100,
      ConnectionColumn.downloadSpeed => 100,
      ConnectionColumn.time => 100,
      ConnectionColumn.source => 150,
      ConnectionColumn.action => 60,
    };
  }

  int compare(TrackerInfo a, TrackerInfo b) {
    switch (this) {
      case ConnectionColumn.host:
        final hostA = a.metadata.host.isEmpty ? a.metadata.destinationIP : a.metadata.host;
        final hostB = b.metadata.host.isEmpty ? b.metadata.destinationIP : b.metadata.host;
        return hostA.compareTo(hostB);
      case ConnectionColumn.process:
        return a.metadata.process.compareTo(b.metadata.process);
      case ConnectionColumn.rule:
        return a.rule.compareTo(b.rule);
      case ConnectionColumn.chains:
        return a.chains.last.compareTo(b.chains.last);
      case ConnectionColumn.uploadSpeed:
        return (a.uploadSpeed ?? 0).compareTo(b.uploadSpeed ?? 0);
      case ConnectionColumn.downloadSpeed:
        return (a.downloadSpeed ?? 0).compareTo(b.downloadSpeed ?? 0);
      case ConnectionColumn.time:
        return b.start.compareTo(a.start);
      case ConnectionColumn.source:
        return a.metadata.sourceIP.compareTo(b.metadata.sourceIP);
      case ConnectionColumn.action:
        return 0;
    }
  }
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

  // 缓存上一次的连接信息，用于计算速度 Key为ID
  Map<String, TrackerInfo> _lastConnectionStates = {};

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
    ConnectionColumn.rule,
    ConnectionColumn.chains,
    ConnectionColumn.uploadSpeed,
    ConnectionColumn.downloadSpeed,
    ConnectionColumn.time,
    ConnectionColumn.source,
    ConnectionColumn.action,
  ];

  // Column Widths State
  late Map<ConnectionColumn, double> _columnWidths;

  @override
  void initState() {
    super.initState();
    _columnWidths = {
      for (var col in _columns) col: col.defaultWidth,
    };
    _startTimer();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _fetchData();
    });
    _fetchData();
  }

  Future<void> _fetchData() async {
    if (_isDisposed) return;
    try {
      final rawConnections = await coreController.getConnections();
      if (_isDisposed) return;

      final List<TrackerInfo> calculatedConnections = [];
      final Map<String, TrackerInfo> newStates = {};

      for (var current in rawConnections) {
        final last = _lastConnectionStates[current.id];
        
        int upSpeed = 0;
        int downSpeed = 0;

        if (last != null) {
          upSpeed = max(0, current.upload - last.upload);
          downSpeed = max(0, current.download - last.download);
        }

        final connectionWithSpeed = current.copyWith(
          uploadSpeed: upSpeed,
          downloadSpeed: downSpeed,
        );

        calculatedConnections.add(connectionWithSpeed);
        newStates[current.id] = current;
      }

      if (mounted) {
        setState(() {
          _connections = calculatedConnections;
          _lastConnectionStates = newStates;
        });
      }
    } catch (_) {}
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
        final host = info.metadata.host.toLowerCase();
        final ip = info.metadata.destinationIP.toLowerCase();
        final process = info.metadata.process.toLowerCase();
        final port = info.metadata.destinationPort.toLowerCase();
        final remotePort =
            _extractRemotePort(info.metadata.remoteDestination).toLowerCase();
        final rule = info.rule.toLowerCase();
        final chains = info.chains.join(' ').toLowerCase();
        final time = info.start.toString().toLowerCase();
        final hostWithPort = '$host:$port';
        
        return hostWithPort.contains(q) ||
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
    final res = await globalState.showMessage(
      title: appLocalizations.closeConnections,
      message: TextSpan(text: appLocalizations.resetTip),
    );
    if (res == true) {
      coreController.closeConnections();
      setState(() {
        _connections.clear();
        _lastConnectionStates.clear();
      });
      _fetchData();
    }
  }

  void _showConnectionDetails(TrackerInfo info) {
    showExtend(
      context,
      builder: (_, type) {
        return AdaptiveSheetScaffold(
          type: type,
          body: TrackerInfoDetailView(trackerInfo: info),
          title:  appLocalizations.details(appLocalizations.connection),
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
          onPressed: _closeAllConnections,
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
        const SizedBox(width: 8),
      ],
      body: SelectionArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final totalFixedWidth = _columns.fold<double>(
                0, (sum, col) => sum + (_columnWidths[col] ?? col.defaultWidth));
            
            double scaleRatio = 1.0;
            if (totalFixedWidth > 0 && constraints.maxWidth > 0) {
              scaleRatio = constraints.maxWidth / totalFixedWidth;
            }

            final effectiveColumnWidths = {
              for (var col in _columns)
                col: (_columnWidths[col] ?? col.defaultWidth) * scaleRatio
            };

            return Column(
              children: [
                Expanded(
                  child: Scrollbar(
                    controller: _verticalScrollController,
                    thumbVisibility: true,
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
                                  // 1. 绑定垂直控制器
                                  controller: _verticalScrollController,
                                  itemCount: connections.length,
                                  itemExtent: 40,
                                  itemBuilder: (context, index) {
                                    final info = connections[index];
                                    return _ConnectionRow(
                                      key: ValueKey(info.id),
                                      info: info,
                                      columns: _columns,
                                      columnWidths: effectiveColumnWidths,
                                      onTap: () => _showConnectionDetails(info),
                                      onClose: () {
                                        coreController.closeConnection(info.id);
                                        setState(() {
                                          _connections.removeWhere(
                                              (e) => e.id == info.id);
                                          _lastConnectionStates.remove(info.id);
                                        });
                                      },
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Footer
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: context.colorScheme.surfaceContainer,
                  child: Row(
                    children: [
                      Text(
                        'Total: ${_connections.length}',
                        style: context.textTheme.labelMedium,
                      ),
                      const Spacer(),
                      Text(
                        'Download: ${_connections.fold<int>(0, (p, c) => p + (c.downloadSpeed ?? 0)).traffic.show}/s',
                        style: context.textTheme.labelSmall,
                      ),
                      const SizedBox(width: 16),
                      Text(
                        'Upload: ${_connections.fold<int>(0, (p, c) => p + (c.uploadSpeed ?? 0)).traffic.show}/s',
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
      height: 40,
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
                              style: Theme.of(context)
                                  .textTheme
                                  .labelMedium
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
                    top: 8,
                    bottom: 8,
                    child: Container(
                      width: 1,
                      color: Theme.of(context).dividerColor.withOpacity(0.5),
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
                        child: Container(
                          color: Colors.transparent,
                        ),
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
    final rowColor = WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.hovered)) {
        return colorScheme.surfaceContainerHighest.withOpacity(0.5);
      }
      return null;
    });

    return TextButton(
      style: ButtonStyle(
        padding: WidgetStateProperty.all(EdgeInsets.zero),
        shape: WidgetStateProperty.all(const RoundedRectangleBorder()),
        overlayColor: rowColor,
        backgroundColor: rowColor,
      ),
      onPressed: onTap,
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

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(d.inHours);
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    if (d.inHours > 0) return '$hours:$minutes:$seconds';
    return '$minutes:$seconds';
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
        final host = info.metadata.host;
        final ip = info.metadata.destinationIP;
        final port = info.metadata.destinationPort;
        if (host.isNotEmpty) {
          return Text('$host:$port', style: style);
        }
        return Text('$ip:$port', style: style);
      case ConnectionColumn.rule:
        return Text(info.rule, style: style);
      case ConnectionColumn.chains:
        return Text(
          info.chains.reversed.join(' -> '),
          style: style?.copyWith(color: colorScheme.secondary),
        );
      case ConnectionColumn.uploadSpeed:
        final speed = info.uploadSpeed ?? 0;
        return Text(
          speed == 0 ? '-' : '${speed.traffic.show}/s',
          style: style?.copyWith(color: Colors.grey),
        );
      case ConnectionColumn.downloadSpeed:
        final speed = info.downloadSpeed ?? 0;
        return Text(
          speed == 0 ? '-' : '${speed.traffic.show}/s',
          style: style?.copyWith(color: Colors.green),
        );
      case ConnectionColumn.time:
        final duration = DateTime.now().difference(info.start);
        return Text(_formatDuration(duration), style: style);
      case ConnectionColumn.source:
        return Text('${info.metadata.sourceIP}:${info.metadata.sourcePort}',
            style: style);
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

  Widget _buildChains() {
    final chains = Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: [
        for (final chain in trackerInfo.chains)
          CommonChip(label: chain, onPressed: () {}),
      ],
    );
    return ListItem(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 20,
        children: [
          Text(appLocalizations.proxyChains),
          Flexible(child: chains),
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
      if (trackerInfo.metadata.host.isNotEmpty)
        _buildItem(
          title: appLocalizations.host,
          desc: trackerInfo.metadata.host,
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
      if (trackerInfo.metadata.remoteDestination.isNotEmpty)
        _buildItem(
          title: appLocalizations.remoteDestination,
          desc: trackerInfo.metadata.remoteDestination,
        ),
      _buildChains(),
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
