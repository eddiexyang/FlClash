import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';

class Migration {
  static Migration? _instance;
  late int _oldVersion;

  Migration._internal();

  final currentVersion = 2;

  factory Migration() {
    _instance ??= Migration._internal();
    return _instance!;
  }

  Future<Config> migrationIfNeeded(
    Map<String, Object?>? configMap, {
    required Future<Config> Function(MigrationData data) sync,
  }) async {
    _oldVersion = await preferences.getVersion();
    if (_oldVersion == currentVersion) {
      try {
        return Config.realFromJson(configMap);
      } catch (_) {
        final isV0 = configMap?['proxiesStyle'] != null;
        if (isV0) {
          _oldVersion = 0;
        } else {
          throw 'Local data is damaged. A reset is required to fix this issue.';
        }
      }
    }
    MigrationData data = MigrationData(configMap: configMap);
    if (_oldVersion == 0 && configMap != null) {
      final clashConfigMap = await preferences.getClashConfigMap();
      if (clashConfigMap != null) {
        configMap['patchClashConfig'] = clashConfigMap;
        await preferences.clearClashConfig();
      }
      data = await _oldToNow(configMap);
    }
    data = await _migrateLogLevelDefaultToInfo(data);
    final res = await sync(data);
    await preferences.setVersion(currentVersion);
    return res;
  }

  Future<MigrationData> _oldToNow(Map<String, Object?> configMap) async {
    return await oldToNowTask(configMap);
  }

  Future<MigrationData> _migrateLogLevelDefaultToInfo(
    MigrationData data,
  ) async {
    final hasMigrated = await preferences.getBool(logLevelInfoMigrationDoneKey);
    if (hasMigrated == true) {
      return data;
    }
    final configMap = data.configMap;
    if (configMap == null) {
      await preferences.setBool(logLevelInfoMigrationDoneKey, true);
      return data;
    }
    final patch = configMap['patchClashConfig'];
    if (patch is! Map) {
      await preferences.setBool(logLevelInfoMigrationDoneKey, true);
      return data;
    }
    final patchConfig = Map<String, Object?>.from(
      patch.map((key, value) => MapEntry('$key', value)),
    );
    final logLevel = patchConfig['log-level'];
    if (logLevel == 'error') {
      patchConfig['log-level'] = 'info';
      final nextConfig = Map<String, Object?>.from(configMap);
      nextConfig['patchClashConfig'] = patchConfig;
      await preferences.setBool(logLevelInfoMigrationDoneKey, true);
      return data.copyWith(configMap: nextConfig);
    }
    await preferences.setBool(logLevelInfoMigrationDoneKey, true);
    return data;
  }
}

final migration = Migration();
