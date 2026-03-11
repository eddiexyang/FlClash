import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

class LogsView extends ConsumerStatefulWidget {
  const LogsView({super.key});

  @override
  ConsumerState<LogsView> createState() => _LogsViewState();
}

class _LogsViewState extends ConsumerState<LogsView> {
  final _logsStateNotifier = ValueNotifier<LogsState>(LogsState());
  late ScrollController _scrollController;
  List<Log>? _pendingLogs;

  List<Log> _logs = [];
  static const _topThreshold = 12.0;

  @override
  void initState() {
    super.initState();
    _logs = ref.read(logsProvider).list;
    _scrollController = ScrollController(initialScrollOffset: double.maxFinite);
    _scrollController.addListener(_flushLogsWhenReachTop);
    _logsStateNotifier.value = _logsStateNotifier.value.copyWith(logs: _logs);
    ref.listenManual(logsProvider.select((state) => state.list), (prev, next) {
      if (prev != next) {
        final isEquality = logListEquality.equals(prev, next);
        if (!isEquality) {
          _onLogsChanged(next);
        }
      }
    });
  }

  List<Widget> _buildActions() {
    return [
      ValueListenableBuilder<LogsState>(
        valueListenable: _logsStateNotifier,
        builder: (_, state, _) {
          final selectedLevel = _parseSelectedLevel(state.keywords);
          return PopupMenuButton<LogLevel?>(
            icon: Icon(
              selectedLevel == null ? Icons.tune : Icons.filter_alt_outlined,
            ),
            tooltip: appLocalizations.logLevel,
            onSelected: _setLevelFilter,
            itemBuilder: (context) {
              return [
                CheckedPopupMenuItem<LogLevel?>(
                  value: null,
                  checked: selectedLevel == null,
                  child: const Text('all'),
                ),
                const PopupMenuDivider(),
                ...LogLevel.values.map(
                  (level) => CheckedPopupMenuItem<LogLevel?>(
                    value: level,
                    checked: selectedLevel == level,
                    child: Text(level.name),
                  ),
                ),
              ];
            },
          );
        },
      ),
      IconButton(
        onPressed: () {
          _handleExport();
        },
        icon: const Icon(Icons.save_as_outlined),
      ),
    ];
  }

  bool get _isAtTop {
    if (!_scrollController.hasClients) {
      return false;
    }
    final position = _scrollController.position;
    return (position.maxScrollExtent - position.pixels).abs() <= _topThreshold;
  }

  bool get _shouldUpdateNow => _logsStateNotifier.value.autoScrollToEnd || _isAtTop;

  LogLevel? _parseSelectedLevel(List<String> keywords) {
    if (keywords.isEmpty) {
      return null;
    }
    final target = keywords.first;
    for (final level in LogLevel.values) {
      if (level.name == target) {
        return level;
      }
    }
    return null;
  }

  void _setLevelFilter(LogLevel? level) {
    _logsStateNotifier.value = _logsStateNotifier.value.copyWith(
      keywords: level == null ? [] : [level.name],
    );
  }

  void _onLogsChanged(List<Log> next) {
    _logs = next;
    if (_shouldUpdateNow) {
      _pendingLogs = null;
      updateLogsThrottler(next);
      return;
    }
    _pendingLogs = List<Log>.from(next);
  }

  void _flushLogsWhenReachTop() {
    if (_pendingLogs == null || !_shouldUpdateNow) {
      return;
    }
    final pendingLogs = _pendingLogs!;
    _pendingLogs = null;
    updateLogsThrottler(pendingLogs);
  }

  void _onSearch(String value) {
    _logsStateNotifier.value = _logsStateNotifier.value.copyWith(query: value);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_flushLogsWhenReachTop);
    _logsStateNotifier.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _handleExport() async {
    final res = await appController.safeRun<bool>(() async {
      return await appController.exportLogs();
    }, title: appLocalizations.exportLogs);
    if (res != true) return;
    globalState.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(text: appLocalizations.exportSuccess),
    );
  }

  void updateLogsThrottler(List<Log> logs) {
    throttler.call(FunctionTag.logs, () {
      if (!mounted) {
        return;
      }
      final isEquality = logListEquality.equals(
        logs,
        _logsStateNotifier.value.logs,
      );
      if (isEquality) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _logsStateNotifier.value = _logsStateNotifier.value.copyWith(
            logs: logs,
          );
        }
      });
    }, duration: commonDuration);
  }

  @override
  Widget build(BuildContext context) {
    final configLogLevel = ref.watch(
      patchClashConfigProvider.select((state) => state.logLevel),
    );
    final isCoreLogFiltered = configLogLevel.index > LogLevel.info.index;
    return CommonScaffold(
      actions: _buildActions(),
      searchState: AppBarSearchState(onSearch: _onSearch),
      title: appLocalizations.logs,
      floatingActionButton: ValueListenableBuilder(
        valueListenable: _logsStateNotifier,
        builder: (_, state, _) {
          final autoScrollToEnd = state.autoScrollToEnd;
          return FadeRotationScaleBox(
            child: FloatingActionButton(
              key: ValueKey(autoScrollToEnd),
              onPressed: () {
                final nextAutoScrollToEnd = !autoScrollToEnd;
                _logsStateNotifier.value = _logsStateNotifier.value.copyWith(
                  autoScrollToEnd: nextAutoScrollToEnd,
                );
                if (nextAutoScrollToEnd) {
                  _flushLogsWhenReachTop();
                }
              },
              child: autoScrollToEnd
                  ? const Icon(Icons.block)
                  : const Icon(Icons.vertical_align_top),
            ),
          );
        },
      ),
      body: ValueListenableBuilder<LogsState>(
        valueListenable: _logsStateNotifier,
        builder: (context, state, _) {
          final hint = isCoreLogFiltered
              ? Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: context.colorScheme.errorContainer.opacity80,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '当前核心日志级别为 ${configLogLevel.name}，连接日志会被过滤。'
                    '请在配置-通用-日志等级切换到 info 或 debug。',
                    style: context.textTheme.bodyMedium?.copyWith(
                      color: context.colorScheme.onErrorContainer,
                    ),
                  ),
                )
              : const SizedBox.shrink();
          final logs = state.list;
          if (logs.isEmpty) {
            return Column(
              children: [
                hint,
                Expanded(
                  child: NullStatus(
                    illustration: LogEmptyIllustration(),
                    label: appLocalizations.nullTip(appLocalizations.logs),
                  ),
                ),
              ],
            );
          }
          final items = logs
              .map<Widget>(
                (log) => LogItem(
                  key: ValueKey(log.id),
                  log: log,
                ),
              )
              .separated(const Divider(height: 0))
              .toList();
          return Column(
            children: [
              hint,
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ScrollToEndBox(
                    onCancelToEnd: () {
                      _logsStateNotifier.value = _logsStateNotifier.value
                          .copyWith(autoScrollToEnd: false);
                    },
                    controller: _scrollController,
                    enable: state.autoScrollToEnd,
                    dataSource: logs,
                    child: CommonScrollBar(
                      controller: _scrollController,
                      child: SuperListView.builder(
                        physics: NextClampingScrollPhysics(),
                        reverse: true,
                        shrinkWrap: true,
                        controller: _scrollController,
                        itemBuilder: (_, index) {
                          return items[index];
                        },
                        itemCount: items.length,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class LogItem extends StatelessWidget {
  final Log log;
  final Function(String)? onClick;

  const LogItem({super.key, required this.log, this.onClick});

  @override
  Widget build(BuildContext context) {
    return ListItem(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      onTap: () {},
      title: SelectableText(
        log.payload,
        style: context.textTheme.bodyLarge?.copyWith(color: log.logLevel.color),
      ),
      subtitle: Column(
        children: [
          SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              CommonChip(
                onPressed: () {
                  if (onClick == null) return;
                  onClick!(log.logLevel.name);
                },
                label: log.logLevel.name,
              ),
              Text(
                log.dateTime,
                style: context.textTheme.bodySmall?.copyWith(
                  color: context.colorScheme.onSurface.opacity80,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
