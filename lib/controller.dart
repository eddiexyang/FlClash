import 'dart:async';
import 'dart:io';

import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'common/common.dart';
import 'database/database.dart';
import 'models/models.dart';
import 'providers/database.dart';

class AppController {
  late final BuildContext _context;
  late final WidgetRef _ref;
  bool isAttach = false;
  bool _expectedRunning = false;
  bool _isRecoveringCore = false;
  int _recoverSession = 0;
  int _trafficPollFailures = 0;
  int _coreHealthFailures = 0;
  bool _healthRecoveryRequested = false;
  DateTime? _lastCoreHealthCheck;

  static AppController? _instance;

  AppController._internal();

  factory AppController() {
    _instance ??= AppController._internal();
    return _instance!;
  }

  Future<void> attach(BuildContext context, WidgetRef ref) async {
    _context = context;
    _ref = ref;
    await _init();
    isAttach = true;
  }

  bool get expectedRunning => _expectedRunning;
}

class _SetupConfigMessageResult {
  final String message;
  final bool hasShownDialog;

  const _SetupConfigMessageResult({
    required this.message,
    required this.hasShownDialog,
  });
}

class _SetupConfigException implements Exception {
  final String message;
  final bool hasShownDialog;

  const _SetupConfigException({
    required this.message,
    this.hasShownDialog = false,
  });

  @override
  String toString() {
    return message;
  }
}

extension InitControllerExt on AppController {
  Future<void> _init() async {
    FlutterError.onError = (details) {
      commonPrint.log(
        'exception: ${details.exception} stack: ${details.stack}',
        logLevel: LogLevel.warning,
      );
    };
    updateTray();
    autoUpdateProfiles();
    autoLaunch?.updateStatus(_ref.read(appSettingProvider).autoLaunch);
    if (!_ref.read(appSettingProvider).silentLaunch) {
      window?.show();
    } else {
      window?.hide();
    }
    await _handleFailedPreference();
    await _connectCore();
    await _initCore();
    await _initStatus();
    _ref.read(initProvider.notifier).value = true;
  }

  Future<void> _handleFailedPreference() async {
    if (await preferences.isInit) {
      return;
    }
    final res = await globalState.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(text: appLocalizations.cacheCorrupt),
    );
    if (res == true) {
      final file = File(await appPath.sharedPreferencesPath);
      await file.safeDelete();
    }
    await handleExit();
  }

  Future<void> _initStatus() async {
    if (!globalState.needInitStatus) {
      commonPrint.log('init status cancel');
      return;
    }
    commonPrint.log('init status');
    if (system.isAndroid) {
      await globalState.updateStartTime();
    }
    final status = globalState.isStart == true
        ? true
        : _ref.read(appSettingProvider).autoRun;
    if (status == true) {
      await updateStatus(true, isInit: true);
    } else {
      await applyProfile(force: true, allowTunAuthorization: false);
    }
  }
}

extension StateControllerExt on AppController {
  Config get config {
    return _ref.read(configProvider);
  }

  bool get isMobile {
    return _ref.read(isMobileViewProvider);
  }

  bool get isStart {
    return _ref.read(isStartProvider);
  }

  List<Group> get groups {
    return _ref.read(groupsProvider);
  }

  String get ua => _ref.read(patchClashConfigProvider).globalUa.takeFirstValid([
    globalState.packageInfo.ua,
  ]);

  Profile? get currentProfile {
    return _ref.read(currentProfileProvider);
  }

  String? getSelectedProxyName(String groupName) {
    return _ref.read(getSelectedProxyNameProvider(groupName));
  }

  Future<SetupState> getSetupState(int profileId) async {
    return await _ref.read(setupStateProvider(profileId).future);
  }

  String getRealTestUrl(String? url) {
    return _ref.read(realTestUrlProvider(url));
  }

  int getProxiesColumns() {
    return _ref.read(getProxiesColumnsProvider);
  }

  SharedState get sharedState {
    return _ref.read(sharedStateProvider);
  }

  SetupParams get setupParams {
    final selectedMap = _ref.read(selectedMapProvider);
    final testUrl = _ref.read(
      appSettingProvider.select((state) => state.testUrl),
    );
    return SetupParams(selectedMap: selectedMap, testUrl: testUrl);
  }

  List<Group> getCurrentGroups() {
    return _ref.read(currentGroupsStateProvider.select((state) => state.value));
  }

  String? getCurrentGroupName() {
    final currentGroupName = _ref.read(
      currentProfileProvider.select((state) => state?.currentGroupName),
    );
    return currentGroupName;
  }
}

extension ProfilesControllerExt on AppController {
  Future<void> deleteProfile(int id) async {
    _ref.read(profilesProvider.notifier).del(id);
    clearEffect(id);
    final currentProfileId = _ref.read(currentProfileIdProvider);
    if (currentProfileId == id) {
      final profiles = _ref.read(profilesProvider);
      if (profiles.isNotEmpty) {
        final updateId = profiles.first.id;
        _ref.read(currentProfileIdProvider.notifier).value = updateId;
      } else {
        _ref.read(currentProfileIdProvider.notifier).value = null;
        updateStatus(false);
      }
    }
  }

  Future<void> autoUpdateProfiles() async {
    for (final profile in _ref.read(profilesProvider)) {
      if (!profile.autoUpdate) continue;
      final isNotNeedUpdate = profile.lastUpdateDate
          ?.add(profile.autoUpdateDuration)
          .isBeforeNow;
      if (isNotNeedUpdate == false || profile.type == ProfileType.file) {
        continue;
      }
      try {
        await updateProfile(profile);
      } catch (e) {
        commonPrint.log(e.toString(), logLevel: LogLevel.warning);
      }
    }
  }

  void putProfile(Profile profile) {
    _ref.read(profilesProvider.notifier).put(profile);
    if (_ref.read(currentProfileIdProvider) != null) return;
    _ref.read(currentProfileIdProvider.notifier).value = profile.id;
  }

  Future<void> updateProfiles() async {
    for (final profile in _ref.read(profilesProvider)) {
      if (profile.type == ProfileType.file) {
        continue;
      }
      await updateProfile(profile);
    }
  }

  Future<void> updateProfile(
    Profile profile, {
    bool showLoading = false,
  }) async {
    try {
      if (showLoading) {
        _ref.read(isUpdatingProvider(profile.updatingKey).notifier).value =
            true;
      }
      final newProfile = await profile.update();
      _ref.read(profilesProvider.notifier).put(newProfile);
      if (profile.id == _ref.read(currentProfileIdProvider)) {
        applyProfileDebounce(silence: true);
      }
    } finally {
      _ref.read(isUpdatingProvider(profile.updatingKey).notifier).value = false;
    }
  }

  Future<void> addProfileFormURL(String url) async {
    if (globalState.navigatorKey.currentState?.canPop() ?? false) {
      globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    toProfiles();
    final profile = await loadingRun(tag: LoadingTag.profiles, () async {
      return await Profile.normal(url: url).update();
    }, title: appLocalizations.addProfile);
    if (profile != null) {
      putProfile(profile);
    }
  }

  void setProfileAndAutoApply(Profile profile) {
    _ref.read(profilesProvider.notifier).put(profile);
    if (profile.id == _ref.read(currentProfileIdProvider)) {
      applyProfileDebounce();
    }
  }

  Future<void> addProfileFormFile() async {
    final platformFile = await safeRun(picker.pickerFile);
    final bytes = platformFile?.bytes;
    if (bytes == null) {
      return;
    }
    if (!_context.mounted) return;
    globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    toProfiles();
    final profile = await loadingRun(tag: LoadingTag.profiles, () async {
      return await Profile.normal(label: platformFile?.name).saveFile(bytes);
    }, title: appLocalizations.addProfile);
    if (profile != null) {
      putProfile(profile);
    }
  }

  Future<void> addProfileFormQrCode() async {
    final url = await safeRun(picker.pickerConfigQRCode);
    if (url == null) return;
    addProfileFormURL(url);
  }

  void reorder(List<Profile> profiles) {
    _ref.read(profilesProvider.notifier).reorder(profiles);
  }

  Future<void> clearEffect(int profileId) async {
    final profilePath = await appPath.getProfilePath(profileId.toString());
    final providersDirPath = await appPath.getProvidersDirPath(
      profileId.toString(),
    );
    final profileFile = File(profilePath);
    final isExists = await profileFile.exists();
    if (isExists) {
      await profileFile.safeDelete(recursive: true);
    }
    await coreController.deleteFile(providersDirPath);
  }
}

extension LogsControllerExt on AppController {
  void addLog(Log log) {
    _ref.read(logsProvider).add(log);
  }

  Future<bool> exportLogs() async {
    final logString = await encodeLogsTask(_ref.read(logsProvider).list);
    final tempFilePath = await appPath.tempFilePath;
    final file = File(tempFilePath);
    await file.safeWriteAsString(logString);
    bool res = false;
    res = await picker.saveFileWithPath(utils.logFile, tempFilePath) != null;
    return res;
  }
}

extension ProxiesControllerExt on AppController {
  void updateGroupsDebounce([Duration? duration]) {
    debouncer.call(FunctionTag.updateGroups, updateGroups, duration: duration);
  }

  void changeProxyDebounce(String groupName, String proxyName) {
    debouncer.call(FunctionTag.changeProxy, (
      String groupName,
      String proxyName,
    ) async {
      await changeProxy(groupName: groupName, proxyName: proxyName);
      updateGroupsDebounce();
    }, args: [groupName, proxyName]);
  }

  Future<void> updateGroups() async {
    try {
      commonPrint.log('updateGroups');
      _ref.read(groupsProvider.notifier).value = await retry(
        task: () async {
          final sortType = _ref.read(
            proxiesStyleSettingProvider.select((state) => state.sortType),
          );
          final delayMap = _ref.read(delayDataSourceProvider);
          final testUrl = _ref.read(
            appSettingProvider.select((state) => state.testUrl),
          );
          final selectedMap = _ref.read(
            currentProfileProvider.select((state) => state?.selectedMap ?? {}),
          );
          return await coreController.getProxiesGroups(
            selectedMap: selectedMap,
            sortType: sortType,
            delayMap: delayMap,
            defaultTestUrl: testUrl,
          );
        },
        retryIf: (res) => res.isEmpty,
      );
    } catch (e) {
      commonPrint.log('updateGroups error: $e');
      _ref.read(groupsProvider.notifier).value = [];
    }
  }

  void updateCurrentGroupName(String groupName) {
    final profile = _ref.read(currentProfileProvider);
    if (profile == null || profile.currentGroupName == groupName) {
      return;
    }
    _ref
        .read(profilesProvider.notifier)
        .put(profile.copyWith(currentGroupName: groupName));
  }

  void updateCurrentSelectedMap(String groupName, String proxyName) {
    final currentProfile = _ref.read(currentProfileProvider);
    if (currentProfile != null &&
        currentProfile.selectedMap[groupName] != proxyName) {
      final selectedMap = Map<String, String>.from(currentProfile.selectedMap)
        ..[groupName] = proxyName;
      _ref
          .read(profilesProvider.notifier)
          .put(currentProfile.copyWith(selectedMap: selectedMap));
    }
  }

  void updateCurrentUnfoldSet(Set<String> value) {
    final currentProfile = _ref.read(currentProfileProvider);
    if (currentProfile == null) {
      return;
    }
    _ref
        .read(profilesProvider.notifier)
        .put(currentProfile.copyWith(unfoldSet: value));
  }

  void setDelay(Delay delay) {
    _ref.read(delayDataSourceProvider.notifier).setDelay(delay);
  }

  Future<void> changeProxy({
    required String groupName,
    required String proxyName,
  }) async {
    await coreController.changeProxy(
      ChangeProxyParams(groupName: groupName, proxyName: proxyName),
    );
    if (_ref.read(appSettingProvider).closeConnections) {
      await coreController.closeConnections();
    } else {
      await coreController.resetConnections();
    }
    addCheckIp();
  }

  void setProvider(ExternalProvider? provider) {
    _ref.read(providersProvider.notifier).setProvider(provider);
  }

  Future<void> updateProviders() async {
    _ref.read(providersProvider.notifier).value = await coreController
        .getExternalProviders();
  }

  Future<String> updateProvider(
    ExternalProvider provider, {
    bool showLoading = false,
  }) async {
    try {
      if (showLoading) {
        _ref.read(isUpdatingProvider(provider.updatingKey).notifier).value =
            true;
      }
      final message = await coreController.updateExternalProvider(
        providerName: provider.name,
      );
      if (message.isNotEmpty) return message;
      setProvider(await coreController.getExternalProvider(provider.name));
      return '';
    } finally {
      _ref.read(isUpdatingProvider(provider.updatingKey).notifier).value =
          false;
    }
  }

  int addSortNum() {
    return _ref.read(sortNumProvider.notifier).add();
  }
}

extension SetupControllerExt on AppController {
  void _setExpectedRunning(bool value) {
    _expectedRunning = value;
    if (!value) {
      _recoverSession++;
      _resetCoreHealthState();
    }
  }

  void _clearRunningState({bool clearTraffic = false}) {
    globalState.stopRunningState();
    _ref.read(runTimeProvider.notifier).value = null;
    if (!clearTraffic) {
      return;
    }
    _ref.read(trafficsProvider.notifier).clear();
    _ref.read(totalTrafficProvider.notifier).value = Traffic();
  }

  void fullSetup() {
    if (!_ref.read(initProvider)) {
      return;
    }
    _ref.read(delayDataSourceProvider.notifier).value = {};
    applyProfile(force: true);
    _ref.read(logsProvider.notifier).value = FixedList(5000);
    _ref.read(requestsProvider.notifier).value = FixedList(500);
  }

  Future<void> updateStatus(bool isStart, {bool isInit = false}) async {
    if (isStart) {
      _setExpectedRunning(true);
      if (!isInit) {
        final res = await tryStartCore(true);
        if (res) {
          return;
        }
        if (!_ref.read(initProvider)) {
          return;
        }
        await globalState.handleStart(
          tasks: [updateTraffic, updateCoreHealth],
          onTick: updateRunTime,
        );
        applyProfileDebounce(force: true, silence: true);
      } else {
        globalState.needInitStatus = false;
        await applyProfile(
          force: true,
          preloadInvoke: () async {
            await globalState.handleStart(
              tasks: [updateTraffic, updateCoreHealth],
              onTick: updateRunTime,
            );
          },
        );
      }
    } else {
      _setExpectedRunning(false);
      await globalState.handleStop();
      coreController.resetTraffic();
      _clearRunningState(clearTraffic: true);
      addCheckIp();
    }
  }

  Future<bool> needSetup() async {
    final profileId = _ref.read(currentProfileIdProvider);
    if (profileId == null) {
      return false;
    }
    final setupState = await _ref.read(setupStateProvider(profileId).future);
    return setupState.needSetup(globalState.lastSetupState) == true;
  }

  Future<void> updateConfigDebounce() async {
    debouncer.call(FunctionTag.updateConfig, () async {
      await safeRun(() async {
        final updateParams = _ref.read(updateParamsProvider);
        final res = await _requestAdmin(updateParams.tun.enable);
        if (res.isError) {
          return;
        }
        final realTunEnable = _ref.read(realTunEnableProvider);
        final message = await coreController.updateConfig(
          updateParams.copyWith.tun(enable: realTunEnable),
        );
        if (message.isNotEmpty) throw message;
      });
    });
  }

  void addCheckIp() {
    _ref.read(checkIpNumProvider.notifier).add();
  }

  void tryCheckIp() {
    final isTimeout = _ref.read(
      networkDetectionProvider.select(
        (state) => state.ipInfo == null && state.isLoading == false,
      ),
    );
    if (!isTimeout) {
      return;
    }
    _ref.read(checkIpNumProvider.notifier).add();
  }

  void applyProfileDebounce({bool silence = false, bool force = false}) {
    debouncer.call(FunctionTag.applyProfile, (silence, force) {
      applyProfile(silence: silence, force: force);
    }, args: [silence, force]);
  }

  void changeMode(Mode mode) {
    _ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith(mode: mode));
    if (mode == Mode.global) {
      updateCurrentGroupName(GroupName.GLOBAL.name);
    }
    addCheckIp();
  }

  void autoApplyProfile() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      applyProfile();
    });
  }

  Future<void> applyProfile({
    bool silence = false,
    bool force = false,
    bool allowTunAuthorization = true,
    VoidCallback? preloadInvoke,
  }) async {
    if (!force && !await needSetup()) {
      return;
    }
    await loadingRun(
      () async {
        await _setupConfig(
          preloadInvoke: preloadInvoke,
          allowTunAuthorization: allowTunAuthorization,
        );
        await updateGroups();
        await updateProviders();
      },
      silence: true,
      tag: !silence ? LoadingTag.proxies : null,
    );
  }

  Future<Map<String, dynamic>> getProfile({
    required SetupState setupState,
    required ClashConfig patchConfig,
  }) async {
    final profileId = setupState.profileId;
    if (profileId == null) {
      return {};
    }
    final defaultUA = globalState.packageInfo.ua;
    final networkVM2 = _ref.read(
      networkSettingProvider.select(
        (state) => VM2(state.appendSystemDns, state.routeMode),
      ),
    );
    final overrideDns = _ref.read(overrideDnsProvider);
    final appendSystemDns = networkVM2.a;
    final routeMode = networkVM2.b;
    final configMap = await coreController.getConfig(profileId);
    String? scriptContent;
    final List<Rule> addedRules = [];
    if (setupState.overwriteType == OverwriteType.script) {
      scriptContent = await setupState.script?.content;
    } else {
      addedRules.addAll(setupState.addedRules);
    }
    final realPatchConfig = patchConfig.copyWith(
      tun: patchConfig.tun.getRealTun(routeMode),
    );
    Map<String, dynamic> rawConfig = configMap;
    if (scriptContent?.isNotEmpty == true) {
      rawConfig = await globalState.handleEvaluate(scriptContent!, rawConfig);
    }
    final directory = await appPath.profilesPath;
    final res = makeRealProfileTask(
      MakeRealProfileState(
        profilesPath: directory,
        profileId: profileId,
        rawConfig: rawConfig,
        realPatchConfig: realPatchConfig,
        overrideDns: overrideDns,
        appendSystemDns: appendSystemDns,
        addedRules: addedRules,
        defaultUA: defaultUA,
      ),
    );
    return res;
  }

  Future<Map> getProfileWithId(int profileId) async {
    var res = {};
    try {
      final setupState = await _ref.read(setupStateProvider(profileId).future);
      final patchClashConfig = _ref.read(patchClashConfigProvider);
      res = await getProfile(
        setupState: setupState,
        patchConfig: patchClashConfig,
      );
    } catch (e) {
      globalState.showNotifier(e.toString());
    }
    return res;
  }

  Future<void> _setupConfig({
    VoidCallback? preloadInvoke,
    bool allowTunAuthorization = true,
  }) async {
    commonPrint.log('setup ===>');
    var profile = _ref.read(currentProfileProvider);
    final nextProfile = await profile?.checkAndUpdateAndCopy();
    if (nextProfile != null) {
      profile = nextProfile;
      _ref.read(profilesProvider.notifier).put(nextProfile);
    }
    final patchConfig = _ref.read(patchClashConfigProvider);
    bool realTunEnable;
    if (allowTunAuthorization) {
      final res = await _requestAdmin(patchConfig.tun.enable);
      if (res.isError) {
        return;
      }
      realTunEnable = _ref.read(realTunEnableProvider);
    } else {
      realTunEnable = false;
      _ref.read(realTunEnableProvider.notifier).value = false;
    }
    final realPatchConfig = patchConfig.copyWith.tun(enable: realTunEnable);
    final setupState = await _ref.read(setupStateProvider(profile?.id).future);
    globalState.lastSetupState = setupState;
    if (system.isAndroid) {
      globalState.lastVpnState = _ref.read(vpnStateProvider);
      await preferences.saveShareState(this.sharedState);
    }
    final config = await getProfile(
      setupState: setupState,
      patchConfig: realPatchConfig,
    );
    final configFilePath = await appPath.configFilePath;
    final yamlString = await encodeYamlTask(config);
    await File(configFilePath).safeWriteAsString(yamlString);
    var message = await coreController.setupConfig(
      setupState: setupState,
      params: setupParams,
      preloadInvoke: preloadInvoke,
    );
    var hasShownDialog = false;
    if (message.isNotEmpty) {
      final result = await _handleSetupConfigForMacOSSshAuthorization(
        message: message,
        setupState: setupState,
      );
      message = result.message;
      hasShownDialog = result.hasShownDialog;
    }
    if (message.isNotEmpty) {
      throw _SetupConfigException(
        message: message,
        hasShownDialog: hasShownDialog,
      );
    }
    addCheckIp();
  }

  bool _isMacOSSshPrivateKeyPermissionError(String message) {
    if (!system.isMacOS) {
      return false;
    }
    final lowerMessage = message.toLowerCase();
    final isPermissionDenied =
        lowerMessage.contains('operation not permitted') ||
        lowerMessage.contains('permission denied');
    if (!isPermissionDenied) {
      return false;
    }
    final hasSshPath =
        lowerMessage.contains('/.ssh/') || lowerMessage.contains('~/.ssh');
    if (!hasSshPath) {
      return false;
    }
    return lowerMessage.contains('private key') ||
        lowerMessage.contains('private-key');
  }

  String? _extractSshPrivateKeyPath(String message) {
    final pathRegExp = RegExp(
      r'((?:~|/Users/[^/\s]+)/(?:\.ssh)/[^\s]+)',
      caseSensitive: false,
    );
    final match = pathRegExp.firstMatch(message);
    return match?.group(1);
  }

  bool _isMacOSSshSafePathsError(String message) {
    if (!system.isMacOS) {
      return false;
    }
    final lowerMessage = message.toLowerCase();
    final isSafePathError = lowerMessage.contains(
      'path is not subpath of home directory or safe_paths',
    );
    if (!isSafePathError) {
      return false;
    }
    return lowerMessage.contains('/.ssh/') || lowerMessage.contains('~/.ssh');
  }

  String? _extractAllowedPaths(String message) {
    final match = RegExp(
      r'allowed paths:\s*(.+)',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(message);
    return match?.group(1)?.trim();
  }

  Future<_SetupConfigMessageResult> _handleSetupConfigForMacOSSshAuthorization({
    required String message,
    required SetupState setupState,
  }) async {
    if (_isMacOSSshPrivateKeyPermissionError(message)) {
      final privateKeyPath = _extractSshPrivateKeyPath(message) ?? '~/.ssh/*';
      final shouldAuthorize = await globalState.showMessage(
        title: appLocalizations.tip,
        message: TextSpan(
          text:
              'macOS blocked access to SSH private key:\n$privateKeyPath\n\n'
              'Please grant system file access permission, then retry.',
        ),
        confirmText: appLocalizations.go,
      );
      if (shouldAuthorize != true) {
        return _SetupConfigMessageResult(
          message: message,
          hasShownDialog: true,
        );
      }
      await system.openMacOSFileAuthorizationSettings();
      final retry = await globalState.showMessage(
        title: appLocalizations.tip,
        cancelable: false,
        confirmText: appLocalizations.confirm,
        message: TextSpan(
          text:
              'After granting permission in macOS settings, return and click Confirm to retry reading this key.',
        ),
      );
      if (retry != true) {
        return _SetupConfigMessageResult(
          message: message,
          hasShownDialog: true,
        );
      }
      final retryMessage = await coreController.setupConfig(
        setupState: setupState,
        params: setupParams,
      );
      return _SetupConfigMessageResult(
        message: retryMessage,
        hasShownDialog: true,
      );
    }

    if (_isMacOSSshSafePathsError(message)) {
      final privateKeyPath = _extractSshPrivateKeyPath(message) ?? '~/.ssh/*';
      final coreHomeDir = await appPath.homeDirPath;
      final allowedPaths = _extractAllowedPaths(message);
      await globalState.showMessage(
        title: appLocalizations.tip,
        cancelable: false,
        message: TextSpan(
          text:
              '无法读取 SSH 私钥：\n$privateKeyPath\n\n'
              '原因：当前 core 只允许读取 Home Dir 或 SAFE_PATHS 白名单中的路径，'
              '而 ~/.ssh 不在允许列表里。\n\n'
              'Core Home Dir:\n$coreHomeDir\n\n'
              '${allowedPaths != null ? 'allowed paths:\n$allowedPaths\n\n' : ''}'
              '解决方案：\n'
              '1. 将私钥复制到 Home Dir 下（例如：$coreHomeDir/ssh/id_ed25519）。\n'
              '2. 在节点/配置里把 private key 路径改成新路径。\n'
              '3. 重新应用配置。\n\n'
              '高级方案：启动应用时设置 SAFE_PATHS，显式包含 ~/.ssh。',
        ),
      );
      return _SetupConfigMessageResult(message: message, hasShownDialog: true);
    }

    return _SetupConfigMessageResult(message: message, hasShownDialog: false);
  }
}

extension CoreControllerExt on AppController {
  Future<void> _initCore() async {
    final isInit = await coreController.isInit;
    final version = _ref.read(versionProvider);
    if (!isInit) {
      await coreController.init(version);
    } else {
      await updateGroups();
    }
  }

  Future<void> _connectCore() async {
    _ref.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
    final result = await Future.wait([
      coreController.preload(),
      Future.delayed(Duration(milliseconds: 300)),
    ]);
    final String message = result[0];
    if (message.isNotEmpty) {
      _ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
      if (_context.mounted) {
        _context.showNotifier(message);
      }
      return;
    }
    final isLogStarted = await coreController.startLog();
    if (!isLogStarted) {
      commonPrint.log(
        'core_log_subscription_failed',
        logLevel: LogLevel.warning,
      );
    }
    _ref.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    _resetCoreHealthState();
  }

  bool _shouldAutoRecoverCore() {
    return (system.isDesktop || system.isAndroid) &&
        _expectedRunning &&
        _ref.read(initProvider);
  }

  Future<void> _recoverCoreAfterCrash() async {
    if (_isRecoveringCore || !_shouldAutoRecoverCore()) {
      return;
    }
    _isRecoveringCore = true;
    final session = _recoverSession;
    const backoffSeconds = [1, 3, 10];
    try {
      for (var index = 0; index < backoffSeconds.length; index++) {
        if (session != _recoverSession || !_shouldAutoRecoverCore()) {
          return;
        }
        final attempt = index + 1;
        commonPrint.log(
          'auto_recover_start recover_attempt_count=$attempt',
          logLevel: LogLevel.warning,
        );
        try {
          await coreController.shutdown(false);
          await _connectCore();
          await _initCore();
          await updateStatus(true, isInit: true);
          if (_ref.read(coreStatusProvider) == CoreStatus.connected) {
            commonPrint.log(
              'auto_recover_success recover_attempt_count=$attempt',
            );
            return;
          }
          throw Exception('core status is disconnected after recover');
        } catch (e) {
          commonPrint.log(
            'auto_recover_fail recover_attempt_count=$attempt error=$e',
            logLevel: LogLevel.warning,
          );
          if (attempt < backoffSeconds.length) {
            await Future.delayed(Duration(seconds: backoffSeconds[index]));
          }
        }
      }
      if (session == _recoverSession && _shouldAutoRecoverCore()) {
        globalState.showNotifier(appLocalizations.restartCoreTip);
      }
    } finally {
      _isRecoveringCore = false;
    }
  }

  Future<Result<bool>> _requestAdmin(bool enableTun) async {
    final realTunEnable = _ref.read(realTunEnableProvider);
    if (enableTun != realTunEnable && realTunEnable == false) {
      final code = await system.authorizeCore();
      switch (code) {
        case AuthorizeCode.success:
          await restartCore();
          return Result.error('');
        case AuthorizeCode.none:
          break;
        case AuthorizeCode.error:
          _ref.read(realTunEnableProvider.notifier).value = false;
          _ref
              .read(patchClashConfigProvider.notifier)
              .update((state) => state.copyWith.tun(enable: false));
          enableTun = false;
          return Result.error('');
      }
    }
    _ref.read(realTunEnableProvider.notifier).value = enableTun;
    return Result.success(enableTun);
  }

  Future<void> restartCore([bool start = false]) async {
    final shouldStart = start || _expectedRunning || _ref.read(isStartProvider);
    _recoverSession++;
    _ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    await coreController.shutdown(true);
    await _connectCore();
    await _initCore();
    if (shouldStart) {
      await updateStatus(true, isInit: true);
    } else {
      await applyProfile(force: true);
    }
  }

  Future<bool> tryStartCore([bool start = false]) async {
    if (coreController.isCompleted) {
      return false;
    }
    await restartCore(start);
    return true;
  }

  void handleCoreDisconnected() {
    commonPrint.log('core_disconnected', logLevel: LogLevel.warning);
    _clearRunningState();
    _ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
  }

  Future<void> handleCoreCrash(String message) async {
    final coreStatus = _ref.read(coreStatusProvider);
    final runTime = _ref.read(runTimeProvider);
    if (coreStatus != CoreStatus.connected && runTime == null) {
      return;
    }
    if (message.contains('socket done')) {
      commonPrint.log(
        'socket_done_detected message=$message',
        logLevel: LogLevel.warning,
      );
    }
    handleCoreDisconnected();
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _context.showNotifier(message);
    }
    if (system.isAndroid) {
      await _stopAndroidRuntimeForRecovery();
    }
    await coreController.shutdown(false);
    unawaited(_recoverCoreAfterCrash());
  }

  Future<void> _stopAndroidRuntimeForRecovery() async {
    final androidService = service;
    if (androidService == null) return;
    try {
      await androidService.stop();
      for (var attempt = 0; attempt < 20; attempt++) {
        await Future.delayed(const Duration(milliseconds: 250));
        final runTime = await androidService.getRunTime().timeout(
          const Duration(seconds: 1),
        );
        if (runTime == null) {
          return;
        }
      }
      commonPrint.log(
        'android_runtime_stop_timeout',
        logLevel: LogLevel.warning,
      );
    } catch (error, stackTrace) {
      commonPrint.log(
        'android_runtime_stop_failed error=$error stack=$stackTrace',
        logLevel: LogLevel.warning,
      );
    }
  }
}

extension SystemControllerExt on AppController {
  Future<List<Package>> getPackages() async {
    if (_ref.read(isMobileViewProvider)) {
      await Future.delayed(commonDuration);
    }
    if (_ref.read(packagesProvider).isEmpty) {
      _ref.read(packagesProvider.notifier).value =
          await app?.getPackages() ?? [];
    }
    return _ref.read(packagesProvider);
  }

  Future<void> handleExit([bool needSave = false]) async {
    Future.delayed(Duration(seconds: 3), () {
      system.exit();
    });
    try {
      await Future.wait([
        if (needSave) preferences.saveConfig(config),
        if (macOS != null) macOS!.updateDns(true),
        if (proxy != null) proxy!.stopProxy(),
        if (tray != null) tray!.destroy(),
      ]);
      await coreController.destroy();
      commonPrint.log('exit');
    } finally {
      system.exit();
    }
  }

  Future<void> handleBackOrExit() async {
    if (_ref.read(backBlockProvider)) {
      return;
    }
    if (_ref.read(appSettingProvider).minimizeOnExit) {
      if (system.isDesktop) {
        await preferences.saveConfig(config);
      }
      await system.back();
    } else {
      await handleExit();
    }
  }

  Future<void> updateVisible() async {
    final visible = await window?.isVisible;
    if (visible != null && !visible) {
      window?.show();
    } else {
      window?.hide();
    }
  }

  void updateBrightness() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ref.read(systemBrightnessProvider.notifier).value =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
    });
  }

  void updateViewSize(Size size) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ref.read(viewSizeProvider.notifier).value = size;
    });
  }

  void initLink() {
    linkManager.initAppLinksListen((url) async {
      final res = await globalState.showMessage(
        title: '${appLocalizations.add}${appLocalizations.profile}',
        message: TextSpan(
          children: [
            TextSpan(text: appLocalizations.doYouWantToPass),
            TextSpan(
              text: ' $url ',
              style: TextStyle(
                color: _context.colorScheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: _context.colorScheme.primary,
              ),
            ),
            TextSpan(
              text: '${appLocalizations.create}${appLocalizations.profile}',
            ),
          ],
        ),
      );

      if (res != true) {
        return;
      }
      addProfileFormURL(url);
    });
  }

  void updateTun() {
    _ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith.tun(enable: !state.tun.enable));
  }

  void updateSystemProxy() {
    _ref
        .read(networkSettingProvider.notifier)
        .update((state) => state.copyWith(systemProxy: !state.systemProxy));
  }

  void updateAutoLaunch() {
    _ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(autoLaunch: !state.autoLaunch));
  }

  Future<void> updateTray() async {
    tray?.update(
      trayState: _ref.read(trayStateProvider),
      traffic: _ref.read(
        trafficsProvider.select((state) => state.list.safeLast(Traffic())),
      ),
    );
  }

  Future<void> updateLocalIp() async {
    _ref.read(localIpProvider.notifier).value = null;
    await Future.delayed(commonDuration);
    _ref.read(localIpProvider.notifier).value = await utils.getLocalIpAddress();
  }
}

extension BackupControllerExt on AppController {
  Future<void> shakingStore() async {
    final profileIds = _ref.read(
      profilesProvider.select((state) => state.map((item) => item.id)),
    );
    final scriptIds = await _ref.read(
      scriptsProvider.future.select(
        (state) async => (await state).map((item) => item.id),
      ),
    );
    final pathsToDelete = await shakingProfileTask(VM2(profileIds, scriptIds));
    if (pathsToDelete.isNotEmpty) {
      final deleteFutures = pathsToDelete.map((path) async {
        try {
          final res = await coreController.deleteFile(path);
          if (res.isNotEmpty) {
            throw res;
          }
        } catch (e) {
          rethrow;
        }
      });

      await Future.wait(deleteFutures);
    }
  }

  Future<String> backup() async {
    final profileFileNames = _ref.read(
      profilesProvider.select((state) => state.map((item) => item.fileName)),
    );
    final scriptFileNames = await _ref.read(
      scriptsProvider.future.select(
        (state) async => (await state).map((item) => item.fileName),
      ),
    );
    final configMap = _ref.read(configProvider).toJson();
    configMap['version'] = await preferences.getVersion();
    return await backupTask(configMap, [
      ...profileFileNames,
      ...scriptFileNames,
    ]);
  }

  Future<void> restore(RestoreOption option) async {
    final restoreDirPath = await appPath.restoreDirPath;
    final restoreDir = Directory(restoreDirPath);
    final restoreStrategy = _ref.read(
      appSettingProvider.select((state) => state.restoreStrategy),
    );
    final isOverride = restoreStrategy == RestoreStrategy.override;
    try {
      final migrationData = await restoreTask();
      if (!await restoreDir.exists()) {
        throw appLocalizations.restoreException;
      }
      await database.restore(
        migrationData.profiles,
        migrationData.scripts,
        migrationData.rules,
        migrationData.links,
        isOverride: isOverride,
      );
      final configMap = migrationData.configMap;
      if (option == RestoreOption.onlyProfiles || configMap == null) {
        return;
      }
      final config = Config.fromJson(configMap);
      _ref.read(patchClashConfigProvider.notifier).value =
          config.patchClashConfig;
      _ref.read(appSettingProvider.notifier).value = config.appSettingProps;
      _ref.read(currentProfileIdProvider.notifier).value =
          config.currentProfileId;
      _ref.read(themeSettingProvider.notifier).value = config.themeProps;
      _ref.read(windowSettingProvider.notifier).value = config.windowProps;
      _ref.read(vpnSettingProvider.notifier).value = config.vpnProps;
      _ref.read(proxiesStyleSettingProvider.notifier).value =
          config.proxiesStyleProps;
      _ref.read(overrideDnsProvider.notifier).value = config.overrideDns;
      _ref.read(networkSettingProvider.notifier).value = config.networkProps;
      _ref.read(hotKeyActionsProvider.notifier).value = config.hotKeyActions;
      return;
    } finally {
      await restoreDir.safeDelete(recursive: true);
    }
  }
}

extension BackBlockControllExt on AppController {
  void backBlock() {
    _ref.read(backBlockProvider.notifier).value = true;
  }

  void unBackBlock() {
    _ref.read(backBlockProvider.notifier).value = false;
  }
}

extension StoreControllerExt on AppController {
  void savePreferencesDebounce() {
    debouncer.call(FunctionTag.savePreferences, () async {
      await preferences.saveConfig(config);
    });
  }

  Future handleClear() async {
    await preferences.clearPreferences();
    commonPrint.log('clear preferences');
    await database.close();
    await File(await appPath.databasePath).safeDelete(recursive: true);
    final homeDir = Directory(await appPath.profilesPath);
    await for (final file in homeDir.list(recursive: true)) {
      await coreController.deleteFile(file.path);
    }
    await preferences.clearPreferences();
    handleExit(false);
  }
}

extension CommonControllerExt on AppController {
  void toPage(PageLabel pageLabel) {
    _ref.read(currentPageLabelProvider.notifier).value = pageLabel;
  }

  void toProfiles() {
    toPage(PageLabel.profiles);
  }

  void updateStart() {
    updateStatus(!_ref.read(isStartProvider));
  }

  void updateSpeedStatistics() {
    _ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(showTrayTitle: !state.showTrayTitle));
  }

  void updateMode() {
    _ref.read(patchClashConfigProvider.notifier).update((state) {
      final index = Mode.values.indexWhere((item) => item == state.mode);
      if (index == -1) {
        return null;
      }
      final nextIndex = index + 1 > Mode.values.length - 1 ? 0 : index + 1;
      return state.copyWith(mode: Mode.values[nextIndex]);
    });
  }

  void updateRunTime() {
    final startTime = globalState.startTime;
    if (startTime != null) {
      final startTimeStamp = startTime.millisecondsSinceEpoch;
      final nowTimeStamp = DateTime.now().millisecondsSinceEpoch;
      _ref.read(runTimeProvider.notifier).value = nowTimeStamp - startTimeStamp;
    } else {
      _ref.read(runTimeProvider.notifier).value = null;
    }
  }

  void _resetCoreHealthState() {
    _trafficPollFailures = 0;
    _coreHealthFailures = 0;
    _lastCoreHealthCheck = null;
  }

  void _requestCoreHealthRecovery(String source, Object error) {
    if (_healthRecoveryRequested || !_expectedRunning) return;
    _healthRecoveryRequested = true;
    commonPrint.log(
      'core_health_recovery_requested source=$source error=$error',
      logLevel: LogLevel.warning,
    );
    unawaited(
      handleCoreCrash('Core health check failed ($source)').whenComplete(() {
        _healthRecoveryRequested = false;
      }),
    );
  }

  Future<void> updateTraffic() async {
    final onlyStatisticsProxy = _ref.read(
      appSettingProvider.select((state) => state.onlyStatisticsProxy),
    );
    try {
      final values = await Future.wait([
        coreController.getTraffic(onlyStatisticsProxy),
        coreController.getTotalTraffic(onlyStatisticsProxy),
      ]).timeout(const Duration(seconds: 10));
      _ref.read(trafficsProvider.notifier).addTraffic(values[0]);
      _ref.read(totalTrafficProvider.notifier).value = values[1];
      _trafficPollFailures = 0;
    } catch (error, stackTrace) {
      _trafficPollFailures++;
      if (_trafficPollFailures >= 3) {
        _requestCoreHealthRecovery('traffic', error);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> updateCoreHealth() async {
    final now = DateTime.now();
    final startTime = globalState.startTime;
    if (startTime != null) {
      final runningFor = now.difference(startTime);
      if (!runningFor.isNegative && runningFor < const Duration(seconds: 30)) {
        return;
      }
    }
    final lastCheck = _lastCoreHealthCheck;
    if (lastCheck != null &&
        now.difference(lastCheck) < const Duration(seconds: 10)) {
      return;
    }
    _lastCoreHealthCheck = now;
    try {
      if (system.isAndroid) {
        final androidService = service;
        if (androidService == null) {
          throw StateError('Android service is unavailable');
        }
        final runTime = await androidService.getRunTime().timeout(
          const Duration(seconds: 3),
        );
        if (runTime == null) {
          throw StateError('Android VPN service is not running');
        }
      } else if (system.isDesktop) {
        final port = _ref.read(
          patchClashConfigProvider.select((state) => state.mixedPort),
        );
        if (port > 0) {
          final socket = await Socket.connect(
            InternetAddress.loopbackIPv4,
            port,
            timeout: const Duration(seconds: 2),
          );
          socket.destroy();
        }
      }
      _coreHealthFailures = 0;
    } catch (error, stackTrace) {
      _coreHealthFailures++;
      commonPrint.log(
        'core_health_check_failed count=$_coreHealthFailures error=$error '
        'stack=$stackTrace',
        logLevel: LogLevel.warning,
      );
      if (_coreHealthFailures >= 2) {
        _requestCoreHealthRecovery('runtime', error);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<T?> loadingRun<T>(
    FutureOr<T> Function() futureFunction, {
    String? title,
    required LoadingTag? tag,
    bool silence = false,
  }) async {
    return safeRun(
      futureFunction,
      silence: silence,
      title: title,
      onStart: () {
        if (tag == null) {
          return;
        }
        _ref.read(loadingProvider(tag).notifier).start();
      },
      onEnd: () {
        if (tag == null) {
          return;
        }
        _ref.read(loadingProvider(tag).notifier).stop();
      },
    );
  }

  Future<T?> safeRun<T>(
    FutureOr<T> Function() futureFunction, {
    String? title,
    VoidCallback? onStart,
    VoidCallback? onEnd,
    bool silence = true,
  }) async {
    try {
      if (onStart != null) {
        onStart();
      }
      final res = await futureFunction();
      return res;
    } catch (e, s) {
      commonPrint.log('$title ===> $e, $s', logLevel: LogLevel.warning);
      if (e is _SetupConfigException && e.hasShownDialog) {
        return null;
      }
      if (silence) {
        globalState.showNotifier(e.toString());
      } else {
        globalState.showMessage(
          title: title ?? appLocalizations.tip,
          message: TextSpan(text: e.toString()),
        );
      }
      return null;
    } finally {
      if (onEnd != null) {
        onEnd();
      }
    }
  }
}

final appController = AppController();
