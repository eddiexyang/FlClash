import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps the internal chain proxy wherever GUI text contains it', () {
    expect(displayProxyName(internalChainProxyName), 'Chain');
    expect(
      displayProxyText('Selector($internalChainProxyName)'),
      'Selector(Chain)',
    );
  });

  test('maps an embedded internal hop back to its proxy name', () {
    final hopName = internalChainHopName(2, '🇺🇸 US-CO');

    expect(displayProxyText('Relay($hopName)'), 'Relay(🇺🇸 US-CO)');
  });

  test('builds Chain runtime proxies without rewriting configured groups', () {
    final config = <String, dynamic>{
      'proxies': [
        {'name': 'node-a', 'type': 'ss'},
        {'name': 'hop-only', 'type': 'trojan'},
      ],
      'proxy-groups': [
        {
          'name': 'PROXY',
          'type': 'select',
          'proxies': ['node-a'],
        },
        {
          'name': 'Automatic',
          'type': 'url-test',
          'proxies': ['node-a'],
        },
        {'name': 'Provider only', 'type': 'select', 'use': ['provider-a']},
      ],
    };

    final originalConfig = jsonDecode(jsonEncode(config));
    final originalProxies = config['proxies'];
    final originalGroups = config['proxy-groups'];
    final overlay = applyProxyChainOverlay(config, ['hop-only']);
    final configuredProxyNames = (config['proxies'] as List)
        .cast<Map>()
        .map((proxy) => proxy['name']);

    expect(config, originalConfig);
    expect(identical(config['proxies'], originalProxies), isTrue);
    expect(identical(config['proxy-groups'], originalGroups), isTrue);
    expect(configuredProxyNames, ['node-a', 'hop-only']);
    expect(overlay.sourceProxies.keys, containsAll(['node-a', 'hop-only']));
    expect(overlay.availableProxyNames, ['node-a', 'hop-only']);
    expect(overlay.chainProxies.single['name'], internalChainProxyName);
  });

  test('preserves arbitrary subscription group semantics', () {
    final groups = [
      {
        'name': 'Provider selector',
        'type': 'select',
        'use': ['provider-a'],
        'filter': 'HK|SG',
      },
      {
        'name': 'Automatic',
        'type': 'url-test',
        'include-all-proxies': true,
        'exclude-filter': 'Expired',
        'interval': 600,
      },
      {
        'name': 'Fallback',
        'type': 'fallback',
        'proxies': ['node-a'],
        'lazy': false,
      },
      {
        'name': 'Balance',
        'type': 'load-balance',
        'use': ['provider-a'],
        'strategy': 'consistent-hashing',
      },
    ];
    final config = <String, dynamic>{
      'proxies': [
        {'name': 'node-a', 'type': 'ss'},
      ],
      'proxy-groups': groups,
    };
    final originalGroups = jsonDecode(jsonEncode(groups));

    applyProxyChainOverlay(config, ['node-a']);

    expect(config['proxy-groups'], originalGroups);
  });

  test('preserves an absent or invalid subscription proxies field', () {
    final providerOnlyConfig = <String, dynamic>{
      'proxy-providers': {
        'provider-a': {'type': 'http'},
      },
    };
    final invalidConfig = <String, dynamic>{'proxies': 'invalid'};

    applyProxyChainOverlay(providerOnlyConfig, const []);
    applyProxyChainOverlay(invalidConfig, const []);

    expect(providerOnlyConfig.containsKey('proxies'), isFalse);
    expect(invalidConfig['proxies'], 'invalid');
  });

  test('keeps an empty Chain as a reject proxy for timeout tests', () {
    final config = <String, dynamic>{
      'proxies': [
        {'name': 'node-a', 'type': 'ss'},
      ],
      'proxy-groups': [
        {
          'name': 'Any configured name',
          'type': 'select',
          'proxies': ['node-a'],
        },
      ],
    };

    final overlay = applyProxyChainOverlay(config, const []);

    expect(overlay.chainProxies, [
      {'name': internalChainProxyName, 'type': 'reject'},
    ]);
    expect(((config['proxy-groups'] as List).single as Map)['proxies'], [
      'node-a',
    ]);
  });

  test('keeps an existing dialer-proxy closure as one Chain node', () {
    final sourceProxies = <String, Map<String, dynamic>>{
      'entry': {'name': 'entry', 'type': 'ss'},
      'exit': {
        'name': 'exit',
        'type': 'trojan',
        'dialer-proxy': 'entry',
      },
    };
    final originalSourceProxies = jsonDecode(jsonEncode(sourceProxies));

    final chainProxies = buildProxyChainProxies(['exit'], sourceProxies);
    final entryName = internalChainHopName(0, 'entry');

    expect(chainProxies, [
      {'name': entryName, 'type': 'ss'},
      {
        'name': internalChainProxyName,
        'type': 'trojan',
        'dialer-proxy': entryName,
      },
    ]);
    expect(sourceProxies, originalSourceProxies);
  });

  test('keeps a transitive dialer-proxy closure in dependency order', () {
    final sourceProxies = <String, Map<String, dynamic>>{
      'entry': {'name': 'entry', 'type': 'ss'},
      'middle': {
        'name': 'middle',
        'type': 'vmess',
        'dialer-proxy': 'entry',
      },
      'exit': {
        'name': 'exit',
        'type': 'trojan',
        'dialer-proxy': 'middle',
      },
    };

    final chainProxies = buildProxyChainProxies(['exit'], sourceProxies);
    final entryName = internalChainHopName(0, 'entry');
    final middleName = internalChainHopName(1, 'middle');

    expect(chainProxies, [
      {'name': entryName, 'type': 'ss'},
      {
        'name': middleName,
        'type': 'vmess',
        'dialer-proxy': entryName,
      },
      {
        'name': internalChainProxyName,
        'type': 'trojan',
        'dialer-proxy': middleName,
      },
    ]);
  });

  test('connects the root of a dialer closure to the previous Chain node', () {
    final sourceProxies = <String, Map<String, dynamic>>{
      'first': {'name': 'first', 'type': 'vmess'},
      'entry': {'name': 'entry', 'type': 'ss'},
      'exit': {
        'name': 'exit',
        'type': 'trojan',
        'dialer-proxy': 'entry',
      },
    };

    final chainProxies = buildProxyChainProxies([
      'first',
      'exit',
    ], sourceProxies);
    final firstName = internalChainHopName(0, 'first');
    final entryName = internalChainHopName(1, 'entry');

    expect(chainProxies, [
      {'name': firstName, 'type': 'vmess'},
      {'name': entryName, 'type': 'ss', 'dialer-proxy': firstName},
      {
        'name': internalChainProxyName,
        'type': 'trojan',
        'dialer-proxy': entryName,
      },
    ]);
  });

  test('copies a shared dialer closure for each explicit Chain node', () {
    final sourceProxies = <String, Map<String, dynamic>>{
      'entry': {'name': 'entry', 'type': 'ss'},
      'first-exit': {
        'name': 'first-exit',
        'type': 'vmess',
        'dialer-proxy': 'entry',
      },
      'second-exit': {
        'name': 'second-exit',
        'type': 'trojan',
        'dialer-proxy': 'entry',
      },
    };

    final chainProxies = buildProxyChainProxies([
      'first-exit',
      'second-exit',
    ], sourceProxies);
    final firstEntryName = internalChainHopName(0, 'entry');
    final firstExitName = internalChainHopName(1, 'first-exit');
    final secondEntryName = internalChainHopName(2, 'entry');

    expect(chainProxies, [
      {'name': firstEntryName, 'type': 'ss'},
      {
        'name': firstExitName,
        'type': 'vmess',
        'dialer-proxy': firstEntryName,
      },
      {
        'name': secondEntryName,
        'type': 'ss',
        'dialer-proxy': firstExitName,
      },
      {
        'name': internalChainProxyName,
        'type': 'trojan',
        'dialer-proxy': secondEntryName,
      },
    ]);
  });

  test('preserves an external dialer-proxy dependency for a whole first hop', () {
    final sourceProxies = <String, Map<String, dynamic>>{
      'exit': {
        'name': 'exit',
        'type': 'trojan',
        'dialer-proxy': 'Configured group',
      },
    };

    expect(buildProxyChainProxies(['exit'], sourceProxies), [
      {
        'name': internalChainProxyName,
        'type': 'trojan',
        'dialer-proxy': 'Configured group',
      },
    ]);
  });

  test('restores the full dialer closure retained by an active Chain', () {
    final config = <String, dynamic>{
      'proxies': <Map<String, dynamic>>[],
    };
    final fallbackSourceProxies = <String, Map<String, dynamic>>{
      'entry': {'name': 'entry', 'type': 'ss'},
      'exit': {
        'name': 'exit',
        'type': 'trojan',
        'dialer-proxy': 'entry',
      },
    };

    final overlay = applyProxyChainOverlay(
      config,
      ['exit'],
      fallbackSourceProxies: fallbackSourceProxies,
    );

    expect(overlay.sourceProxies.keys, containsAll(['entry', 'exit']));
    expect(overlay.availableProxyNames, isEmpty);
    expect(overlay.chainProxies, hasLength(2));
  });

  test('does not restore an old proxy over a current dialer group name', () {
    final config = <String, dynamic>{
      'proxies': [
        {
          'name': 'exit',
          'type': 'trojan',
          'dialer-proxy': 'Configured group',
        },
      ],
      'proxy-groups': [
        {
          'name': 'Configured group',
          'type': 'select',
          'proxies': ['DIRECT'],
        },
      ],
    };
    final fallbackSourceProxies = <String, Map<String, dynamic>>{
      'Configured group': {
        'name': 'Configured group',
        'type': 'ss',
      },
    };

    final overlay = applyProxyChainOverlay(
      config,
      ['exit'],
      fallbackSourceProxies: fallbackSourceProxies,
    );

    expect(overlay.sourceProxies.keys.toList(), ['exit']);
    expect(overlay.chainProxies.single['dialer-proxy'], 'Configured group');
  });

  test('does not restore a removed hop dependency over a current group', () {
    final config = <String, dynamic>{
      'proxies': <Map<String, dynamic>>[],
      'proxy-groups': [
        {
          'name': 'Configured group',
          'type': 'select',
          'proxies': ['DIRECT'],
        },
      ],
    };
    final fallbackSourceProxies = <String, Map<String, dynamic>>{
      'exit': {
        'name': 'exit',
        'type': 'trojan',
        'dialer-proxy': 'Configured group',
      },
      'Configured group': {
        'name': 'Configured group',
        'type': 'ss',
      },
    };

    final overlay = applyProxyChainOverlay(
      config,
      ['exit'],
      fallbackSourceProxies: fallbackSourceProxies,
    );

    expect(overlay.sourceProxies.keys.toList(), ['exit']);
    expect(overlay.chainProxies.single['dialer-proxy'], 'Configured group');
  });

  test('rejects a circular dialer-proxy closure', () {
    final sourceProxies = <String, Map<String, dynamic>>{
      'a': {'name': 'a', 'type': 'ss', 'dialer-proxy': 'b'},
      'b': {'name': 'b', 'type': 'ss', 'dialer-proxy': 'a'},
    };

    expect(
      () => buildProxyChainProxies(['a'], sourceProxies),
      throwsA(isA<StateError>()),
    );
  });

  test('only the Chain editor group blocks proxy interaction and tests', () {
    expect(proxyGroupAllowsDelayTest(internalChainProxyName), isFalse);
    expect(proxyGroupAllowsProxyInteraction(internalChainProxyName), isFalse);

    expect(proxyGroupAllowsDelayTest('PROXY'), isTrue);
    expect(proxyGroupAllowsProxyInteraction('PROXY'), isTrue);
    expect(proxyGroupAllowsDelayTest('Any configured name'), isTrue);
  });

  test('builds a first GUI-only Chain group without changing group semantics', () {
    const nodeA = Proxy(name: 'node-a', type: 'Shadowsocks');
    const nodeB = Proxy(name: 'hop-only', type: 'Trojan');
    const groups = [
      Group(
        name: 'PROXY',
        type: GroupType.Selector,
        all: [nodeA],
        now: 'node-a',
        testUrl: 'https://selector.test',
      ),
      Group(
        name: 'Automatic',
        type: GroupType.URLTest,
        all: [nodeA],
        now: 'node-a',
        hidden: false,
      ),
    ];
    final proxiesData = ProxiesData(
      proxies: {
        'node-a': nodeA.toJson(),
        'hop-only': nodeB.toJson(),
        internalChainProxyName: {
          'name': internalChainProxyName,
          'type': 'Reject',
        },
      },
      all: const ['PROXY', 'Automatic'],
    );

    final result = buildProxyChainGuiGroups(
      groups: groups,
      proxiesData: proxiesData,
      sourceProxyNames: const ['node-a', 'hop-only'],
      testUrl: defaultTestUrl,
    );

    expect(result.map((group) => group.name), [
      internalChainProxyName,
      'PROXY',
      'Automatic',
    ]);
    expect(result.first.all.map((proxy) => proxy.name), [
      'node-a',
      'hop-only',
    ]);
    expect(result[1].all.map((proxy) => proxy.name), [
      internalChainProxyName,
      'node-a',
    ]);
    expect(result[1].type, GroupType.Selector);
    expect(result[1].now, 'node-a');
    expect(result[1].testUrl, 'https://selector.test');
    expect(result[2].type, GroupType.URLTest);
    expect(groups.first.all, [nodeA]);
  });
}
