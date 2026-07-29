import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop runtime closes mixed listener when system proxy is off', () {
    final container = ProviderContainer(
      overrides: [
        networkSettingProvider.overrideWithValue(
          const NetworkProps(systemProxy: false),
        ),
        patchClashConfigProvider.overrideWithValue(
          const ClashConfig(mixedPort: 7891),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(updateParamsProvider).mixedPort, 0);
    expect(container.read(patchClashConfigProvider).mixedPort, 7891);
  });

  test('desktop runtime opens configured port when system proxy is on', () {
    final container = ProviderContainer(
      overrides: [
        networkSettingProvider.overrideWithValue(
          const NetworkProps(systemProxy: true),
        ),
        patchClashConfigProvider.overrideWithValue(
          const ClashConfig(mixedPort: 7891),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(updateParamsProvider).mixedPort, 7891);
  });
}
