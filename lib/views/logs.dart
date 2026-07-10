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
          final autoScrollToEnd = state.autoScrollToEnd;
          return IconButton(
            tooltip: autoScrollToEnd
                ? 'Pause live updates'
                : 'Resume live updates',
            onPressed: () => _setAutoScroll(!autoScrollToEnd),
            icon: Icon(
              autoScrollToEnd
                  ? Icons.pause_circle_outline_rounded
                  : Icons.play_circle_outline_rounded,
            ),
          );
        },
      ),
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

  bool get _shouldUpdateNow =>
      _logsStateNotifier.value.autoScrollToEnd || _isAtTop;

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

  void _setAutoScroll(bool enabled) {
    _logsStateNotifier.value = _logsStateNotifier.value.copyWith(
      autoScrollToEnd: enabled,
    );
    if (enabled) {
      _flushLogsWhenReachTop();
    }
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
      body: ValueListenableBuilder<LogsState>(
        valueListenable: _logsStateNotifier,
        builder: (context, state, _) {
          final hint = isCoreLogFiltered
              ? Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: context.colorScheme.errorContainer.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: context.colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '当前核心日志级别为 ${configLogLevel.name}，连接日志会被过滤。'
                          '请在配置-通用-日志等级切换到 info 或 debug。',
                          style: context.textTheme.labelMedium?.copyWith(
                            color: context.colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
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
              .map<Widget>((log) => LogItem(key: ValueKey(log.id), log: log))
              .separated(const Divider(height: 1, thickness: 0.5, indent: 16))
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
    final levelColor = log.logLevel.color ?? context.colorScheme.primary;
    final levelIndicator = GestureDetector(
      onTap: onClick == null ? null : () => onClick!(log.logLevel.name),
      child: SizedBox(
        width: 92,
        child: Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: levelColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                log.logLevel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.labelSmall?.copyWith(
                  color: context.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final timestamp = SizedBox(
      width: 146,
      child: Text(
        log.dateTime,
        maxLines: 1,
        style: context.textTheme.labelSmall?.copyWith(
          color: context.colorScheme.onSurfaceVariant,
          fontFamily: FontFamily.jetBrainsMono.value,
        ),
      ),
    );
    final payload = SelectableText(
      log.payload,
      style: context.textTheme.bodySmall?.copyWith(
        height: 1.3,
        fontFamily: FontFamily.jetBrainsMono.value,
        color: context.colorScheme.onSurface,
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 640;
        return Container(
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          child: isCompact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [timestamp, const Spacer(), levelIndicator]),
                    const SizedBox(height: 4),
                    payload,
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    timestamp,
                    const SizedBox(width: 8),
                    levelIndicator,
                    const SizedBox(width: 8),
                    Expanded(child: payload),
                  ],
                ),
        );
      },
    );
  }
}
