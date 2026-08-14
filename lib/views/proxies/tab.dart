import 'dart:math';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'card.dart';
import 'common.dart';

typedef ProxyGroupViewKeyMap =
    Map<String, GlobalObjectKey<_ProxyGroupViewState>>;

const _chainBarHeight = 56.0;
const _chainBarFabGap = 12.0;
const _chainDragDuration = Duration(milliseconds: 180);
const _chainDropDuration = Duration(milliseconds: 80);

const _chainProxy = Proxy(name: internalChainProxyName, type: 'Relay');

bool _isChainGroup(Group group) {
  final isSelectable =
      group.type == GroupType.Selector || group.type.isComputedSelected;
  return isSelectable &&
      group.name.toLowerCase() == GroupName.Proxy.name.toLowerCase();
}

@immutable
class _ProxyChainDragData {
  final Proxy proxy;
  final int? chainIndex;

  const _ProxyChainDragData({required this.proxy, this.chainIndex});
}

class ProxiesTabView extends ConsumerStatefulWidget {
  const ProxiesTabView({super.key});

  static Map<String, PageStorageKey> pageListStoreMap = {};

  @override
  ConsumerState<ProxiesTabView> createState() => ProxiesTabViewState();
}

class ProxiesTabViewState extends ConsumerState<ProxiesTabView>
    with TickerProviderStateMixin {
  TabController? _tabController;
  final _hasMoreButtonNotifier = ValueNotifier<bool>(false);
  final _chainBarKey = GlobalKey();
  final List<Proxy> _chain = [];
  int? _chainProfileId;
  ProxyGroupViewKeyMap _keyMap = {};

  @override
  void initState() {
    super.initState();
    ref.listenManual(proxiesTabControllerStateProvider, (prev, next) {
      if (prev == next) {
        return;
      }
      if (!stringListEquality.equals(prev?.a, next.a)) {
        _destroyTabController();
        final groupNames = next.a;
        final currentGroupName = next.b;
        final index = groupNames.indexWhere((item) => item == currentGroupName);
        _updateTabController(groupNames.length, index);
      }
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _destroyTabController();
    super.dispose();
  }

  void scrollToGroupSelected() {
    final currentGroupName = appController.getCurrentGroupName();
    _keyMap[currentGroupName]?.currentState?.scrollToSelected();
  }

  Future<void> delayTestCurrentGroup() async {
    final currentGroupName = appController.getCurrentGroupName();
    final currentState = _keyMap[currentGroupName]?.currentState;
    final currentProxies = currentState?.currentProxies ?? const <Proxy>[];
    try {
      await delayTest(currentProxies, currentState?.testUrl);
    } catch (error) {
      globalState.showNotifier(error.toString());
    }
  }

  void _applyChain() {
    final pendingChain = _chain.map((proxy) => proxy.name).toList();
    appController
        .updateProxyChain(
          pendingChain,
          closeConnections: true,
        )
        .then((message) {
          if (message.isNotEmpty) {
            globalState.showNotifier(message);
            _restoreChain(pendingChain);
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          globalState.showNotifier(error.toString());
          _restoreChain(pendingChain);
        });
  }

  void _restoreChain(List<String> failedChain) {
    if (!mounted ||
        !stringListEquality.equals(
          _chain.map((proxy) => proxy.name).toList(),
          failedChain,
        )) {
      return;
    }
    final proxiesByName = {
      for (final group in appController.getCurrentGroups())
        for (final proxy in group.all) proxy.name: proxy,
    };
    setState(() {
      _chain
        ..clear()
        ..addAll(
          appController.proxyChain.map(
            (name) => proxiesByName[name] ?? Proxy(name: name, type: ''),
          ),
        );
    });
  }

  void _insertChainNode(_ProxyChainDragData data, int targetIndex) {
    setState(() {
      var insertIndex = targetIndex;
      if (insertIndex < 0) {
        insertIndex = 0;
      } else if (insertIndex > _chain.length) {
        insertIndex = _chain.length;
      }
      final sourceIndex = data.chainIndex;
      if (sourceIndex != null &&
          sourceIndex >= 0 &&
          sourceIndex < _chain.length) {
        _chain.removeAt(sourceIndex);
        if (sourceIndex < insertIndex) {
          insertIndex--;
        }
      }
      _chain.insert(insertIndex, data.proxy);
    });
    _applyChain();
  }

  void _removeChainNode(int index) {
    if (index < 0 || index >= _chain.length) {
      return;
    }
    setState(() {
      _chain.removeAt(index);
    });
    _applyChain();
  }

  void _syncChainProfile(List<Group> groups) {
    final profileId = appController.currentProfile?.id;
    final chainNames = appController.proxyChain;
    final currentNames = _chain.map((proxy) => proxy.name).toList();
    if (_chainProfileId == profileId &&
        stringListEquality.equals(currentNames, chainNames)) {
      return;
    }
    final proxiesByName = {
      for (final group in groups)
        for (final proxy in group.all) proxy.name: proxy,
    };
    _chainProfileId = profileId;
    _chain
      ..clear()
      ..addAll(
        chainNames.map(
          (name) => proxiesByName[name] ?? Proxy(name: name, type: ''),
        ),
      );
  }

  Widget _buildMoreButton() {
    return Consumer(
      builder: (_, ref, _) {
        final isMobileView = ref.watch(isMobileViewProvider);
        return IconButton(
          onPressed: _showMoreMenu,
          icon: isMobileView
              ? const Icon(Icons.expand_more)
              : const Icon(Icons.chevron_right),
        );
      },
    );
  }

  void _showMoreMenu() {
    showSheet(
      context: context,
      props: SheetProps(isScrollControlled: false),
      builder: (_, type) {
        return AdaptiveSheetScaffold(
          type: type,
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Consumer(
              builder: (_, ref, _) {
                final state = ref.watch(proxiesTabControllerStateProvider);
                final groupNames = state.a;
                final currentGroupName = state.b;
                return SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    runSpacing: 8,
                    spacing: 8,
                    children: [
                      for (final groupName in groupNames)
                        SettingTextCard(
                          groupName,
                          onPressed: () {
                            final index = groupNames.indexWhere(
                              (item) => item == groupName,
                            );
                            if (index == -1) return;
                            _tabController?.animateTo(index);
                            appController.updateCurrentGroupName(groupName);
                            Navigator.of(context).pop();
                          },
                          isSelected: groupName == currentGroupName,
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          title: appLocalizations.proxyGroup,
        );
      },
    );
  }

  void _tabControllerListener([int? index]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      int? groupIndex = index;
      if (groupIndex == -1) {
        return;
      }
      if (groupIndex == null) {
        final currentIndex = _tabController?.index;
        groupIndex = currentIndex;
      }
      final currentGroups = appController.getCurrentGroups();
      if (groupIndex == null || groupIndex >= currentGroups.length) {
        return;
      }
      final currentGroup = currentGroups[groupIndex];
      appController.updateCurrentGroupName(currentGroup.name);
    });
  }

  void _destroyTabController() {
    _tabController?.removeListener(_tabControllerListener);
    _tabController?.dispose();
    _tabController = null;
  }

  void _updateTabController(int length, int index) {
    _destroyTabController();
    if (length == 0) {
      return;
    }
    final realIndex = index == -1 ? 0 : index;
    _tabController ??= TabController(
      length: length,
      initialIndex: realIndex,
      vsync: this,
    );
    _tabControllerListener(realIndex);
    _tabController?.addListener(_tabControllerListener);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(themeSettingProvider.select((state) => state.textScale));
    final state = ref.watch(proxiesTabStateProvider.select((state) => state));
    final groups = state.groups;
    final allGroups = ref.watch(
      currentGroupsStateProvider.select((state) => state.value),
    );
    _syncChainProfile(allGroups);
    if (groups.isEmpty || _tabController == null) {
      return NullStatus(
        illustration: ProxyEmptyIllustration(),
        label: appLocalizations.nullTip(appLocalizations.proxies),
      );
    }
    _keyMap = {};
    final currentIndex = _tabController!.index;
    final currentGroup = currentIndex >= 0 && currentIndex < groups.length
        ? groups[currentIndex]
        : null;
    final showChainBar = currentGroup != null && _isChainGroup(currentGroup);
    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (scrollNotification) {
            _hasMoreButtonNotifier.value =
                scrollNotification.metrics.maxScrollExtent > 0;
            return false;
          },
          child: ValueListenableBuilder(
            valueListenable: _hasMoreButtonNotifier,
            builder: (_, value, child) {
              return Stack(
                alignment: AlignmentDirectional.centerStart,
                children: [
                  TabBar(
                    controller: _tabController,
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 16 + (value ? 16 : 0),
                    ),
                    dividerColor: Colors.transparent,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    overlayColor: const WidgetStatePropertyAll(
                      Colors.transparent,
                    ),
                    tabs: [
                      for (final group in groups)
                        Tab(
                          child: Builder(
                            builder: (context) {
                              return EmojiText(
                                group.name,
                                style: DefaultTextStyle.of(context).style,
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                  if (value) Positioned(right: 0, child: child!),
                ],
              );
            },
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    context.colorScheme.surface.opacity10,
                    context.colorScheme.surface,
                  ],
                  stops: const [0.0, 0.1],
                ),
              ),
              child: _buildMoreButton(),
            ),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              for (final group in groups)
                ProxyGroupView(
                  key: _keyMap.updateCacheValue(
                    group.name,
                    () => GlobalObjectKey<_ProxyGroupViewState>(group.name),
                  ),
                  group: group,
                  columns: state.columns,
                  cardType: state.proxyCardType,
                ),
            ],
          ),
        ),
        if (showChainBar)
          Padding(
            padding: const EdgeInsets.only(
              left: 16,
              right:
                  16 + _chainBarHeight + _chainBarFabGap,
              bottom: 16,
            ),
            child: _ProxyChainBar(
              key: _chainBarKey,
              proxies: _chain,
              onDrop: _insertChainNode,
              onRemove: _removeChainNode,
            ),
          ),
      ],
    );
  }
}

class ProxyGroupView extends ConsumerStatefulWidget {
  final Group group;
  final int columns;
  final ProxyCardType cardType;

  const ProxyGroupView({
    super.key,
    required this.group,
    required this.columns,
    required this.cardType,
  });

  @override
  ConsumerState<ProxyGroupView> createState() => _ProxyGroupViewState();
}

class _ProxyGroupViewState extends ConsumerState<ProxyGroupView> {
  late final ScrollController _controller;

  List<Proxy> currentProxies = [];
  String? testUrl;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
  }

  PageStorageKey _getPageStorageKey() {
    final profile = appController.currentProfile;
    final key =
        '${profile?.id}_${ScrollPositionCacheKey.proxiesTabList.name}_${widget.group.name}';
    return ProxiesTabView.pageListStoreMap.updateCacheValue(
      key,
      () => PageStorageKey(key),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void scrollToSelected() {
    if (_controller.position.maxScrollExtent == 0) {
      return;
    }
    _controller.animateTo(
      min(
        16 +
            getScrollToSelectedOffset(
              groupName: widget.group.name,
              proxies: currentProxies,
            ),
        _controller.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeIn,
    );
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final hasChainNode = _isChainGroup(group);
    final proxies = group.all
        .where((proxy) => proxy.name != internalChainProxyName)
        .toList();
    testUrl = group.testUrl;
    currentProxies = hasChainNode ? [_chainProxy, ...proxies] : proxies;
    return CommonScrollBar(
      controller: _controller,
      child: GridView.builder(
        key: _getPageStorageKey(),
        controller: _controller,
        padding: const EdgeInsets.only(
          top: 16,
          left: 16,
          right: 16,
          bottom: 96,
        ),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: widget.columns,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          mainAxisExtent: getItemHeight(widget.cardType),
        ),
        itemCount: currentProxies.length,
        itemBuilder: (_, index) {
          if (hasChainNode && index == 0) {
            return ChainProxyCard(
              type: widget.cardType,
              groupName: group.name,
              testUrl: group.testUrl,
            );
          }
          final proxyIndex = index - (hasChainNode ? 1 : 0);
          final proxy = proxies[proxyIndex];
          final card = ProxyCard(
            testUrl: group.testUrl,
            groupType: group.type,
            type: widget.cardType,
            proxy: proxy,
            groupName: group.name,
          );
          if (!hasChainNode) {
            return card;
          }
          return DraggableProxyCard(
            proxy: proxy,
            cardType: widget.cardType,
            child: card,
          );
        },
      ),
    );
  }
}

class ChainProxyCard extends ConsumerWidget {
  final ProxyCardType type;
  final String groupName;
  final String? testUrl;

  const ChainProxyCard({
    super.key,
    required this.type,
    required this.groupName,
    required this.testUrl,
  });

  Future<void> _handleTestCurrentDelay() async {
    try {
      await proxyDelayTest(_chainProxy, testUrl);
    } catch (error) {
      globalState.showNotifier(error.toString());
    }
  }

  void _selectChain() {
    appController.updateCurrentSelectedMap(groupName, internalChainProxyName);
    appController.changeProxyDebounce(groupName, internalChainProxyName);
  }

  Widget _buildDelayText(BuildContext context, WidgetRef ref) {
    final measure = globalState.measure;
    final delay = ref.watch(
      getDelayProvider(proxyName: internalChainProxyName, testUrl: testUrl),
    );
    return SizedBox(
      height: measure.labelSmallHeight,
      child: FadeThroughBox(
        alignment: type == ProxyCardType.expand
            ? Alignment.centerLeft
            : Alignment.centerRight,
        child: delay == 0 || delay == null
            ? SizedBox(
                height: measure.labelSmallHeight,
                width: measure.labelSmallHeight,
                child: delay == 0
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : IconButton(
                        icon: const Icon(Icons.bolt),
                        iconSize: measure.labelSmallHeight,
                        padding: EdgeInsets.zero,
                        onPressed: () {
                          _handleTestCurrentDelay();
                        },
                      ),
              )
            : GestureDetector(
                onTap: () {
                  _handleTestCurrentDelay();
                },
                child: Text(
                  delay > 0 ? '$delay ms' : 'Timeout',
                  style: context.textTheme.labelSmall?.copyWith(
                    overflow: TextOverflow.ellipsis,
                    color: utils.getDelayColor(delay),
                  ),
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final measure = globalState.measure;
    final title = Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        height: measure.bodyMediumHeight * (type == ProxyCardType.min ? 1 : 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.account_tree, size: measure.bodyMediumHeight),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Chain',
                maxLines: type == ProxyCardType.min ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
    final delayText = _buildDelayText(context, ref);
    final selectedProxyName = ref.watch(
      getSelectedProxyNameProvider(groupName),
    );
    return CommonCard(
      onPressed: () {
        _selectChain();
      },
      isSelected: selectedProxyName == internalChainProxyName,
      child: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            title,
            const SizedBox(height: 8),
            if (type == ProxyCardType.expand) ...[
              SizedBox(
                height: measure.bodySmallHeight,
                child: Text(
                  appLocalizations.proxyChains,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.bodySmall?.copyWith(
                    color: context.textTheme.bodySmall?.color?.opacity80,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              delayText,
            ] else
              SizedBox(
                height: measure.bodySmallHeight,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        appLocalizations.proxyChains,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.textTheme.bodySmall?.copyWith(
                          color: context.textTheme.bodySmall?.color?.opacity80,
                        ),
                      ),
                    ),
                    delayText,
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class DraggableProxyCard extends StatelessWidget {
  final Proxy proxy;
  final ProxyCardType cardType;
  final Widget child;

  const DraggableProxyCard({
    super.key,
    required this.proxy,
    required this.cardType,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final data = _ProxyChainDragData(proxy: proxy);
        final feedback = Material(
          color: Colors.transparent,
          child: SizedBox(
            width: constraints.maxWidth,
            height: getItemHeight(cardType),
            child: IgnorePointer(
              child: Opacity(opacity: 0.92, child: child),
            ),
          ),
        );
        final childWhenDragging = Opacity(opacity: 0.35, child: child);
        if (system.isDesktop) {
          return Draggable<_ProxyChainDragData>(
            data: data,
            feedback: feedback,
            childWhenDragging: childWhenDragging,
            rootOverlay: true,
            child: child,
          );
        }
        return LongPressDraggable<_ProxyChainDragData>(
          data: data,
          feedback: feedback,
          childWhenDragging: childWhenDragging,
          rootOverlay: true,
          child: child,
        );
      },
    );
  }
}

class _ProxyChainBar extends StatefulWidget {
  final List<Proxy> proxies;
  final void Function(_ProxyChainDragData data, int index) onDrop;
  final void Function(int index) onRemove;

  const _ProxyChainBar({
    super.key,
    required this.proxies,
    required this.onDrop,
    required this.onRemove,
  });

  @override
  State<_ProxyChainBar> createState() => _ProxyChainBarState();
}

class _ProxyChainBarState extends State<_ProxyChainBar> {
  _ProxyChainDragData? _activeDrag;
  int? _previewTargetIndex;
  int? _acceptedTargetIndex;
  bool _settleImmediately = false;
  int? _landingIndex;
  int _landingAnimationId = 0;

  int _clampTargetIndex(int index) {
    return min(max(index, 0), widget.proxies.length);
  }

  void _handleDragStarted(_ProxyChainDragData data) {
    setState(() {
      _activeDrag = data;
      _previewTargetIndex = null;
      _acceptedTargetIndex = null;
    });
  }

  void _handleDragMove(_ProxyChainDragData data, int targetIndex) {
    final nextTargetIndex = _clampTargetIndex(targetIndex);
    final sourceIndex = data.chainIndex;
    final nextPreviewTargetIndex = sourceIndex != null &&
            nextTargetIndex == sourceIndex
        ? null
        : nextTargetIndex;
    if (identical(data, _activeDrag) &&
        _previewTargetIndex == nextPreviewTargetIndex) {
      return;
    }
    setState(() {
      _activeDrag = data;
      _previewTargetIndex = nextPreviewTargetIndex;
      _acceptedTargetIndex = null;
    });
  }

  void _finishDrag(VoidCallback commit, {int? landingIndex}) {
    setState(() {
      _activeDrag = null;
      _previewTargetIndex = null;
      _acceptedTargetIndex = null;
      _settleImmediately = true;
      _landingIndex = landingIndex;
      if (landingIndex != null) {
        _landingAnimationId++;
      }
    });
    commit();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _settleImmediately = false;
      });
    });
  }

  void _handleAccept(_ProxyChainDragData data, int targetIndex) {
    final nextTargetIndex = _clampTargetIndex(targetIndex);
    if (data.chainIndex == null) {
      _finishDrag(
        () => widget.onDrop(data, nextTargetIndex),
        landingIndex: nextTargetIndex,
      );
      return;
    }
    _handleDragMove(data, nextTargetIndex);
    _acceptedTargetIndex = nextTargetIndex;
  }

  void _handleDragEnd(
    _ProxyChainDragData data,
    DraggableDetails details,
  ) {
    final sourceIndex = data.chainIndex;
    final targetIndex = _acceptedTargetIndex;
    if (sourceIndex == null) {
      return;
    }
    if (details.wasAccepted && targetIndex != null) {
      final landingIndex = sourceIndex < targetIndex
          ? targetIndex - 1
          : targetIndex;
      _finishDrag(
        () => widget.onDrop(data, targetIndex),
        landingIndex: landingIndex,
      );
      return;
    }
    _finishDrag(() => widget.onRemove(sourceIndex));
  }

  void _handleBarLeave(_ProxyChainDragData? data) {
    if (!identical(data, _activeDrag) || _previewTargetIndex == null) {
      return;
    }
    setState(() {
      _previewTargetIndex = null;
      if (data?.chainIndex == null) {
        _activeDrag = null;
      }
    });
  }

  int _targetIndexForHop(_ProxyChainDragData data, int hopIndex) {
    final sourceIndex = data.chainIndex;
    if (sourceIndex == hopIndex) {
      return hopIndex;
    }
    return sourceIndex != null && sourceIndex > hopIndex
        ? hopIndex
        : hopIndex + 1;
  }

  bool _showLeadingArrow(int index) {
    if (index == 0) {
      return true;
    }
    if (_activeDrag?.chainIndex == 0 && index == 1) {
      return false;
    }
    if (_previewTargetIndex == index) {
      return true;
    }
    if (index >= widget.proxies.length ||
        _activeDrag?.chainIndex == index) {
      return false;
    }
    return true;
  }

  bool _showTrailingArrow(int index) {
    return _previewTargetIndex == index &&
        index < widget.proxies.length &&
        _activeDrag?.chainIndex != index;
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<_ProxyChainDragData>(
      onWillAcceptWithDetails: (_) => true,
      onMove: (details) {
        _handleDragMove(details.data, widget.proxies.length);
      },
      onAcceptWithDetails: (details) {
        _handleAccept(details.data, widget.proxies.length);
      },
      onLeave: _handleBarLeave,
      builder: (context, candidateData, _) {
        final isHovering = candidateData.isNotEmpty;
        final animationDuration = _settleImmediately
            ? Duration.zero
            : _chainDragDuration;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: _chainBarHeight,
          decoration: BoxDecoration(
            color: isHovering
                ? context.colorScheme.secondaryContainer
                : context.colorScheme.surfaceContainerLow,
            border: Border.all(
              color: isHovering
                  ? context.colorScheme.primary
                  : context.colorScheme.outlineVariant,
              width: isHovering ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Tooltip(
                message: appLocalizations.proxyChains,
                child: const SizedBox(
                  width: 40,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Icon(Icons.account_tree),
                  ),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(
                    children: [
                      for (
                        var index = 0;
                        index <= widget.proxies.length;
                        index++
                      ) ...[
                        _ChainInsertTarget(
                          showLeadingArrow: _showLeadingArrow(index),
                          showTrailingArrow: _showTrailingArrow(index),
                          isTerminal: index == widget.proxies.length,
                          previewProxy: _previewTargetIndex == index
                              ? _activeDrag?.proxy
                              : null,
                          animationDuration: animationDuration,
                          onMove: (data) => _handleDragMove(data, index),
                          onAccept: (data) => _handleAccept(data, index),
                        ),
                        if (index < widget.proxies.length)
                          _ChainHop(
                            proxy: widget.proxies[index],
                            index: index,
                            animationDuration: animationDuration,
                            landingAnimationId: _landingIndex == index
                                ? _landingAnimationId
                                : null,
                            onDragStarted: _handleDragStarted,
                            onDragEnd: _handleDragEnd,
                            onMove: (data) {
                              _handleDragMove(
                                data,
                                _targetIndexForHop(data, index),
                              );
                            },
                            onAccept: (data) {
                              _handleAccept(
                                data,
                                _targetIndexForHop(data, index),
                              );
                            },
                            onRemove: () => widget.onRemove(index),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ChainInsertTarget extends StatelessWidget {
  final bool showLeadingArrow;
  final bool showTrailingArrow;
  final bool isTerminal;
  final Proxy? previewProxy;
  final Duration animationDuration;
  final ValueChanged<_ProxyChainDragData> onMove;
  final ValueChanged<_ProxyChainDragData> onAccept;

  const _ChainInsertTarget({
    required this.showLeadingArrow,
    required this.showTrailingArrow,
    required this.isTerminal,
    required this.previewProxy,
    required this.animationDuration,
    required this.onMove,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<_ProxyChainDragData>(
      onWillAcceptWithDetails: (_) => true,
      onMove: (details) => onMove(details.data),
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, _, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: animationDuration,
              curve: Curves.easeOutCubic,
              width: showLeadingArrow
                  ? 28
                  : (isTerminal && previewProxy == null ? 12 : 0),
              height: 40,
              child: Center(
                child: showLeadingArrow
                    ? Icon(
                        Icons.chevron_right,
                        size: 18,
                        color:
                            context.colorScheme.onSurfaceVariant.opacity60,
                      )
                    : null,
              ),
            ),
            AnimatedSize(
              duration: animationDuration,
              curve: Curves.easeOutCubic,
              alignment: Alignment.centerLeft,
              child: previewProxy == null
                  ? const SizedBox.shrink()
                  : IgnorePointer(
                      child: ExcludeSemantics(
                        child: Opacity(
                          opacity: 0,
                          child: _ChainHopCard(
                            proxy: previewProxy!,
                            onRemove: () {},
                          ),
                        ),
                      ),
                    ),
            ),
            AnimatedContainer(
              duration: animationDuration,
              curve: Curves.easeOutCubic,
              width: showTrailingArrow ? 28 : 0,
              height: 40,
              child: Center(
                child: showTrailingArrow
                    ? Icon(
                        Icons.chevron_right,
                        size: 18,
                        color:
                            context.colorScheme.onSurfaceVariant.opacity60,
                      )
                    : null,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ChainHopCard extends StatelessWidget {
  final Proxy proxy;
  final bool isDropTarget;
  final VoidCallback onRemove;

  const _ChainHopCard({
    required this.proxy,
    required this.onRemove,
    this.isDropTarget = false,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      constraints: const BoxConstraints(minWidth: 96, maxWidth: 220),
      height: 40,
      decoration: BoxDecoration(
        color: isDropTarget
            ? context.colorScheme.secondaryContainer
            : context.colorScheme.surfaceContainerHigh,
        border: Border.all(
          color: isDropTarget
              ? context.colorScheme.primary
              : Colors.transparent,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 12),
          Flexible(
            child: EmojiText(
              proxy.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.bodyMedium,
            ),
          ),
          IconButton(
            tooltip: appLocalizations.remove,
            onPressed: onRemove,
            icon: const Icon(Icons.close),
            iconSize: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(
              width: 36,
              height: 40,
            ),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _ChainHop extends StatelessWidget {
  final Proxy proxy;
  final int index;
  final Duration animationDuration;
  final int? landingAnimationId;
  final ValueChanged<_ProxyChainDragData> onDragStarted;
  final void Function(_ProxyChainDragData data, DraggableDetails details)
      onDragEnd;
  final ValueChanged<_ProxyChainDragData> onMove;
  final ValueChanged<_ProxyChainDragData> onAccept;
  final VoidCallback onRemove;

  const _ChainHop({
    required this.proxy,
    required this.index,
    required this.animationDuration,
    required this.landingAnimationId,
    required this.onDragStarted,
    required this.onDragEnd,
    required this.onMove,
    required this.onAccept,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final data = _ProxyChainDragData(proxy: proxy, chainIndex: index);
    final feedback = Material(
      color: Colors.transparent,
      child: _ChainHopCard(proxy: proxy, onRemove: onRemove),
    );
    return DragTarget<_ProxyChainDragData>(
      onWillAcceptWithDetails: (_) => true,
      onMove: (details) => onMove(details.data),
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidateData, _) {
        final child = _ChainHopCard(
          proxy: proxy,
          isDropTarget: candidateData.isNotEmpty,
          onRemove: onRemove,
        );
        final landedChild = landingAnimationId == null
            ? child
            : TweenAnimationBuilder<double>(
                key: ValueKey(landingAnimationId),
                duration: _chainDropDuration,
                curve: Curves.easeOutCubic,
                tween: Tween(begin: 0.0, end: 1.0),
                child: child,
                builder: (context, value, child) {
                  return Opacity(
                    opacity: value,
                    child: Transform.scale(
                      alignment: Alignment.centerLeft,
                      scale: 0.98 + value * 0.02,
                      child: child,
                    ),
                  );
                },
              );
        final visibleChild = AnimatedSize(
          duration: animationDuration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.centerLeft,
          child: landedChild,
        );
        final childWhenDragging = AnimatedSize(
          duration: animationDuration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.centerLeft,
          child: const SizedBox.shrink(),
        );

        if (system.isDesktop) {
          return Draggable<_ProxyChainDragData>(
            data: data,
            feedback: feedback,
            childWhenDragging: childWhenDragging,
            onDragStarted: () => onDragStarted(data),
            onDragEnd: (details) => onDragEnd(data, details),
            rootOverlay: true,
            child: visibleChild,
          );
        }
        return LongPressDraggable<_ProxyChainDragData>(
          data: data,
          feedback: feedback,
          childWhenDragging: childWhenDragging,
          onDragStarted: () => onDragStarted(data),
          onDragEnd: (details) => onDragEnd(data, details),
          rootOverlay: true,
          child: visibleChild,
        );
      },
    );
  }
}

class DelayTestButton extends StatefulWidget {
  final Future Function() onClick;

  const DelayTestButton({super.key, required this.onClick});

  @override
  State<DelayTestButton> createState() => _DelayTestButtonState();
}

class _DelayTestButtonState extends State<DelayTestButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  Future<void> _healthcheck() async {
    if (_controller.isAnimating) {
      return;
    }
    _controller.forward();
    await widget.onClick();
    if (mounted) {
      _controller.reverse();
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _animation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutBack),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller.view,
      builder: (_, child) {
        return FadeTransition(
          opacity: _animation,
          child: ScaleTransition(scale: _animation, child: child),
        );
      },
      child: FloatingActionButton(
        heroTag: null,
        tooltip: appLocalizations.delayTest,
        onPressed: _healthcheck,
        child: const Icon(Icons.network_ping),
      ),
    );
  }
}
