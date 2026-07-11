import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:math';

import 'package:animations/animations.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/widgets/dialog.dart';
import 'package:fl_clash/widgets/list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:material_color_utilities/palettes/core_palette.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'common/common.dart';
import 'database/database.dart';
import 'l10n/l10n.dart';
import 'models/models.dart';

typedef UpdateTasks = List<FutureOr Function()>;

class GlobalState {
  static GlobalState? _instance;
  final navigatorKey = GlobalKey<NavigatorState>();
  Timer? timer;
  Timer? runTimeTimer;
  int _updateSession = 0;
  int? _executingUpdateSession;
  bool isPre = true;
  late final String coreSHA256;
  late final PackageInfo packageInfo;
  Function? updateCurrentDelayDebounce;
  late Measure measure;
  late CommonTheme theme;
  late Color accentColor;
  bool needInitStatus = true;
  CorePalette? corePalette;
  DateTime? startTime;
  UpdateTasks tasks = [];
  SetupState? lastSetupState;
  VpnState? lastVpnState;

  bool get isStart => startTime != null && startTime!.isBeforeNow;

  GlobalState._internal();

  factory GlobalState() {
    _instance ??= GlobalState._internal();
    return _instance!;
  }

  Future<ProviderContainer> init(int version) async {
    coreSHA256 = const String.fromEnvironment('CORE_SHA256');
    isPre = const String.fromEnvironment('APP_ENV') != 'stable';
    await _initDynamicColor();
    return await _initData(version);
  }

  Future<void> _initDynamicColor() async {
    try {
      corePalette = await DynamicColorPlugin.getCorePalette();
      accentColor =
          await DynamicColorPlugin.getAccentColor() ??
          Color(defaultPrimaryColor);
    } catch (_) {}
  }

  Future<ProviderContainer> _initData(int version) async {
    final appState = AppState(
      brightness: WidgetsBinding.instance.platformDispatcher.platformBrightness,
      version: version,
      viewSize: Size.zero,
      requests: FixedList(maxLength),
      logs: FixedList(5000),
      traffics: FixedList(30),
      totalTraffic: Traffic(),
      systemUiOverlayStyle: SystemUiOverlayStyle(),
    );
    final appStateOverrides = buildAppStateOverrides(appState);
    packageInfo = await PackageInfo.fromPlatform();
    final configMap = await preferences.getConfigMap();
    final config = await migration.migrationIfNeeded(
      configMap,
      sync: (data) async {
        final newConfigMap = data.configMap;
        final config = Config.realFromJson(newConfigMap);
        await Future.wait([
          database.restore(data.profiles, data.scripts, data.rules, data.links),
          preferences.saveConfig(config),
        ]);
        return config;
      },
    );
    final configOverrides = buildConfigOverrides(config);
    final container = ProviderContainer(
      overrides: [...appStateOverrides, ...configOverrides],
    );
    final profiles = await database.profilesDao.all().get();
    container.read(profilesProvider.notifier).setAndReorder(profiles);
    await AppLocalizations.load(
      utils.getLocaleForString(config.appSettingProps.locale) ??
          WidgetsBinding.instance.platformDispatcher.locale,
    );
    await window?.init(version, config.windowProps);
    return container;
  }

  Future<void> startUpdateTasks([UpdateTasks? tasks]) async {
    if (tasks != null) {
      this.tasks = tasks;
    }
    if (this.tasks.isEmpty || startTime == null) {
      return;
    }
    if (timer?.isActive == true) return;
    final session = _updateSession;
    if (_executingUpdateSession == session) return;
    timer = null;
    _executingUpdateSession = session;
    try {
      await executorUpdateTask(session);
    } finally {
      if (_executingUpdateSession == session) {
        _executingUpdateSession = null;
      }
      if (session == _updateSession &&
          startTime != null &&
          this.tasks.isNotEmpty) {
        timer = Timer(const Duration(seconds: 1), () {
          unawaited(startUpdateTasks());
        });
      }
    }
  }

  Future<void> executorUpdateTask(int session) async {
    for (var index = 0; index < tasks.length; index++) {
      if (session != _updateSession) return;
      try {
        await tasks[index]();
      } catch (error, stackTrace) {
        commonPrint.log(
          'periodic_update_failed task=$index error=$error stack=$stackTrace',
          logLevel: LogLevel.warning,
        );
      }
    }
  }

  void startRunTimeTask(VoidCallback task) {
    runTimeTimer?.cancel();
    task();
    runTimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (startTime != null) {
        task();
      }
    });
  }

  void stopUpdateTasks() {
    _updateSession++;
    timer?.cancel();
    timer = null;
    runTimeTimer?.cancel();
    runTimeTimer = null;
  }

  void stopRunningState() {
    startTime = null;
    stopUpdateTasks();
  }

  Future<void> handleStart({UpdateTasks? tasks, VoidCallback? onTick}) async {
    startTime ??= DateTime.now();
    try {
      await coreController.startListener();
      final didStart = await service?.start();
      if (didStart == false) {
        throw StateError('Android VPN service failed to start');
      }
    } catch (_) {
      startTime = null;
      await coreController.stopListener();
      rethrow;
    }
    if (onTick != null) {
      startRunTimeTask(onTick);
    }
    unawaited(startUpdateTasks(tasks));
  }

  Future updateStartTime() async {
    startTime = await service?.getRunTime();
  }

  Future handleStop() async {
    await coreController.stopListener();
    final didStop = await service?.stop();
    if (didStop == false) {
      await coreController.startListener();
      throw StateError('Android VPN service failed to stop');
    }
    stopRunningState();
  }

  Future<bool?> showMessage({
    required InlineSpan message,
    BuildContext? context,
    String? title,
    String? confirmText,
    String? cancelText,
    bool cancelable = true,
    bool? dismissible,
    bool showCopyAction = true,
  }) async {
    return await showCommonDialog<bool>(
      context: context,
      dismissible: dismissible ?? false,
      child: Builder(
        builder: (context) {
          return CommonDialog(
            title: title ?? appLocalizations.tip,
            actions: [
              if (cancelable)
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop(false);
                  },
                  child: Text(cancelText ?? appLocalizations.cancel),
                ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(true);
                },
                child: Text(confirmText ?? appLocalizations.confirm),
              ),
            ],
            child: Container(
              constraints: BoxConstraints(
                maxHeight: min(MediaQuery.sizeOf(context).height - 180, 420),
              ),
              child: Scrollbar(
                child: SingleChildScrollView(
                  child: SelectableText.rich(
                    TextSpan(
                      style: Theme.of(context).textTheme.labelLarge,
                      children: [message],
                    ),
                    style: const TextStyle(overflow: TextOverflow.visible),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<bool?> showAllUpdatingMessagesDialog(
    List<UpdatingMessage> messages,
  ) async {
    return await showCommonDialog<bool>(
      child: Builder(
        builder: (context) {
          return CommonDialog(
            padding: EdgeInsets.zero,
            title: appLocalizations.tip,
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(true);
                },
                child: Text(appLocalizations.confirm),
              ),
            ],
            child: Container(
              padding: EdgeInsets.symmetric(vertical: 4),
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.separated(
                itemBuilder: (_, index) {
                  final message = messages[index];
                  return ListItem(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    title: Text(message.label),
                    subtitle: Text(message.message),
                  );
                },
                itemCount: messages.length,
                separatorBuilder: (_, _) => Divider(height: 0),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<T?> showCommonDialog<T>({
    required Widget child,
    BuildContext? context,
    bool? dismissible,
    bool filter = true,
  }) async {
    return await showModal<T>(
      useRootNavigator: false,
      context: context ?? globalState.navigatorKey.currentContext!,
      configuration: FadeScaleTransitionConfiguration(
        barrierColor: Colors.black38,
        barrierDismissible: dismissible ?? true,
      ),
      builder: (_) => child,
      filter: filter ? commonFilter : null,
    );
  }

  void showNotifier(String text, {MessageActionState? actionState}) {
    if (text.isEmpty) {
      return;
    }
    navigatorKey.currentContext?.showNotifier(text, actionState: actionState);
  }

  Future<void> openUrl(String url) async {
    final res = await showMessage(
      message: TextSpan(text: url),
      title: appLocalizations.externalLink,
      confirmText: appLocalizations.go,
    );
    if (res != true) {
      return;
    }
    launchUrl(Uri.parse(url));
  }

  Future<Map<String, dynamic>> handleEvaluate(
    String scriptContent,
    Map<String, dynamic> config,
  ) async {
    if (config['proxy-providers'] == null) {
      config['proxy-providers'] = {};
    }
    final configJs = json.encode(config);
    final runtime = getJavascriptRuntime();
    final res = await runtime.evaluateAsync('''
      $scriptContent
      main($configJs)
    ''');
    if (res.isError) {
      throw res.stringResult;
    }
    final value = switch (res.rawResult is ffi.Pointer) {
      true => runtime.convertValue<Map<String, dynamic>>(res),
      false => Map<String, dynamic>.from(res.rawResult),
    };
    return value ?? config;
  }
}

final globalState = GlobalState();
