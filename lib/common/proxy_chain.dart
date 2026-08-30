import 'dart:convert';

import 'package:fl_clash/common/constant.dart';

class ProxyChainOverlay {
  final Map<String, Map<String, dynamic>> sourceProxies;
  final List<String> availableProxyNames;
  final List<String> proxyNames;
  final List<Map<String, dynamic>> chainProxies;
  final String? resetReason;

  const ProxyChainOverlay({
    required this.sourceProxies,
    required this.availableProxyNames,
    required this.proxyNames,
    required this.chainProxies,
    this.resetReason,
  });
}

// Mihomo injects these names even when they are absent from the profile.
const _builtinProxyNames = {
  'DIRECT',
  'REJECT',
  'REJECT-DROP',
  'COMPATIBLE',
  'PASS',
  'PASS-RULE',
};

String internalChainHopName(int index, String proxyName) {
  final encodedName = base64Url
      .encode(utf8.encode(proxyName))
      .replaceAll('=', '');
  return '$internalChainHopPrefix${index}_$encodedName';
}

bool isInternalChainProxyName(String name) {
  return name == internalChainProxyName ||
      name.startsWith(internalChainHopPrefix);
}

bool isInternalChainHopName(String name) {
  return name.startsWith(internalChainHopPrefix);
}

bool isProxyChainSourceName(String name, Set<String> sourceProxyNames) {
  return !isInternalChainProxyName(name) && sourceProxyNames.contains(name);
}

String displayProxyName(String name) {
  if (name == internalChainProxyName) {
    return 'CHAIN';
  }
  if (!name.startsWith(internalChainHopPrefix)) {
    return name;
  }
  final value = name.substring(internalChainHopPrefix.length);
  final separator = value.indexOf('_');
  if (separator == -1 || separator == value.length - 1) {
    return 'CHAIN';
  }
  try {
    final encodedName = value.substring(separator + 1);
    final normalizedName = base64Url.normalize(encodedName);
    return utf8.decode(base64Url.decode(normalizedName));
  } catch (_) {
    return 'CHAIN';
  }
}

String displayProxyChain(Iterable<String> proxyNames) {
  return proxyNames.map(displayProxyName).join(' → ');
}

final _internalProxyNamePattern = RegExp(
  '${RegExp.escape(internalChainHopPrefix)}[0-9]+_[A-Za-z0-9_-]+'
  '|${RegExp.escape(internalChainProxyName)}',
);

String displayProxyText(String text) {
  return text.replaceAllMapped(
    _internalProxyNamePattern,
    (match) => displayProxyName(match.group(0)!),
  );
}

Map<String, dynamic>? _toStringMap(Object? value) {
  if (value is! Map) {
    return null;
  }
  return {
    for (final entry in value.entries) entry.key.toString(): entry.value,
  };
}

class _ProxyChainSource {
  final String name;
  final Map<String, dynamic> mapping;

  const _ProxyChainSource({required this.name, required this.mapping});
}

class _ProxyChainUnit {
  final List<_ProxyChainSource> sources;

  const _ProxyChainUnit({required this.sources});
}

_ProxyChainUnit _resolveProxyChainUnit(
  String proxyName,
  Map<String, Map<String, dynamic>> sourceProxies,
) {
  final sources = <_ProxyChainSource>[];
  final visited = <String>{};
  var currentName = proxyName;

  while (true) {
    if (isInternalChainProxyName(currentName)) {
      throw ArgumentError.value(
        currentName,
        'proxyNames',
        'Invalid proxy name',
      );
    }
    if (!visited.add(currentName)) {
      throw StateError(
        'Proxy "$proxyName" has a circular dialer-proxy dependency',
      );
    }

    final source = sourceProxies[currentName];
    if (source == null) {
      if (sources.isEmpty) {
        throw StateError(
          'Proxy "$proxyName" is unavailable in the current profile',
        );
      }
      break;
    }
    sources.add(_ProxyChainSource(name: currentName, mapping: source));

    final dialerProxy = source['dialer-proxy'];
    if (dialerProxy is! String || dialerProxy.isEmpty) {
      break;
    }
    if (!sourceProxies.containsKey(dialerProxy)) {
      break;
    }
    currentName = dialerProxy;
  }

  return _ProxyChainUnit(sources: sources.reversed.toList());
}

void _restoreUnavailableProxyChainSourceClosure(
  String proxyName,
  Map<String, Map<String, dynamic>> sourceProxies,
  Map<String, Map<String, dynamic>> fallbackSourceProxies,
  Set<String> configuredGroupNames,
  Set<String> visited,
) {
  if (isInternalChainProxyName(proxyName) ||
      configuredGroupNames.contains(proxyName) ||
      sourceProxies.containsKey(proxyName) ||
      !visited.add(proxyName)) {
    return;
  }
  final source = fallbackSourceProxies[proxyName];
  if (source == null) {
    return;
  }
  sourceProxies[proxyName] = Map<String, dynamic>.from(source);
  final dialerProxy = source['dialer-proxy'];
  if (dialerProxy is String && dialerProxy.isNotEmpty) {
    _restoreUnavailableProxyChainSourceClosure(
      dialerProxy,
      sourceProxies,
      fallbackSourceProxies,
      configuredGroupNames,
      visited,
    );
  }
}

List<Map<String, dynamic>> buildProxyChainProxies(
  List<String> proxyNames,
  Map<String, Map<String, dynamic>> sourceProxies,
) {
  final chainProxies = <Map<String, dynamic>>[];
  String? previousProxyName;
  var internalIndex = 0;
  for (var unitIndex = 0; unitIndex < proxyNames.length; unitIndex++) {
    final proxyName = proxyNames[unitIndex];
    final unit = _resolveProxyChainUnit(proxyName, sourceProxies);

    String? previousSourceName;
    for (var sourceIndex = 0; sourceIndex < unit.sources.length; sourceIndex++) {
      final source = unit.sources[sourceIndex];
      final isChainEntry = unitIndex == proxyNames.length - 1 &&
          sourceIndex == unit.sources.length - 1;
      final internalName = isChainEntry
          ? internalChainProxyName
          : internalChainHopName(internalIndex++, source.name);
      final proxy = Map<String, dynamic>.from(source.mapping)
        ..['name'] = internalName;
      if (previousSourceName != null) {
        proxy['dialer-proxy'] = previousSourceName;
      } else if (previousProxyName != null) {
        proxy['dialer-proxy'] = previousProxyName;
      }
      chainProxies.add(proxy);
      previousSourceName = internalName;
    }
    previousProxyName = previousSourceName;
  }
  if (chainProxies.isEmpty) {
    chainProxies.add({
      'name': internalChainProxyName,
      'type': 'reject',
    });
  }
  return chainProxies;
}

/// Builds the runtime proxies for a GUI-managed proxy chain.
///
/// Every hop is a copy of its profile proxy and uses mihomo's native
/// `dialer-proxy` option. Proxy group definitions remain unchanged except for
/// stale references to proxies that are no longer present in the profile.
ProxyChainOverlay applyProxyChainOverlay(
  Map<String, dynamic> config,
  List<String> requestedProxyNames, {
  Map<String, Map<String, dynamic>> fallbackSourceProxies = const {},
}) {
  final sourceProxies = <String, Map<String, dynamic>>{};
  final availableProxyNames = <String>[];
  final cleanProxies = <Object?>[];
  var removedInternalProxy = false;
  final rawProxies = config['proxies'];
  if (rawProxies is List) {
    for (final rawProxy in rawProxies) {
      final proxy = _toStringMap(rawProxy);
      final name = proxy?['name'];
      if (name is String && isInternalChainProxyName(name)) {
        removedInternalProxy = true;
        continue;
      }
      cleanProxies.add(rawProxy);
      if (proxy != null &&
          name is String &&
          !sourceProxies.containsKey(name)) {
        sourceProxies[name] = proxy;
        availableProxyNames.add(name);
      }
    }
  }

  final configuredGroupNames = <String>{};
  final rawGroups = config['proxy-groups'];
  final knownProxyNames = <String>{
    ..._builtinProxyNames,
    ...sourceProxies.keys,
  };
  if (rawGroups is List) {
    for (final rawGroup in rawGroups) {
      final group = _toStringMap(rawGroup);
      final groupName = group?['name'];
      if (groupName is String) {
        configuredGroupNames.add(groupName);
        knownProxyNames.add(groupName);
      }
    }
  }

  final cleanGroups = <Object?>[];
  var removedGroupReference = false;
  if (rawGroups is List) {
    for (final rawGroup in rawGroups) {
      final group = _toStringMap(rawGroup);
      if (group == null) {
        cleanGroups.add(rawGroup);
        continue;
      }
      final rawGroupProxies = group['proxies'];
      if (rawGroupProxies is List) {
        final cleanGroupProxies = rawGroupProxies.where((name) {
          return name is! String ||
              (!isInternalChainProxyName(name) &&
                  knownProxyNames.contains(name));
        }).toList();
        if (cleanGroupProxies.length != rawGroupProxies.length) {
          removedGroupReference = true;
          group['proxies'] = cleanGroupProxies;

          // Mihomo rejects a group whose `proxies` and `use` are both empty.
          // Keep a group that lost all of its stale entries usable, including
          // when rules or another group still refer to it.
          if (cleanGroupProxies.isEmpty &&
              rawGroupProxies.isNotEmpty &&
              !_hasProxyGroupSource(group)) {
            group['proxies'] = [
              _proxyGroupFallbackName(
                group,
                knownProxyNames,
                configuredGroupNames,
              ),
            ];
          }
          cleanGroups.add(group);
          continue;
        }
      }
      cleanGroups.add(rawGroup);
    }
  }

  final configuredSourceProxies = Map<String, Map<String, dynamic>>.from(
    sourceProxies,
  );
  final restoredSourceNames = <String>{};
  for (final name in requestedProxyNames) {
    _restoreUnavailableProxyChainSourceClosure(
      name,
      sourceProxies,
      fallbackSourceProxies,
      configuredGroupNames,
      restoredSourceNames,
    );
  }
  var proxyNames = List<String>.from(requestedProxyNames);
  late List<Map<String, dynamic>> chainProxies;
  String? resetReason;
  try {
    chainProxies = buildProxyChainProxies(proxyNames, sourceProxies);
  } catch (error) {
    if (error is! ArgumentError && error is! StateError) {
      rethrow;
    }
    resetReason = error.toString();
    proxyNames = [];
    sourceProxies
      ..clear()
      ..addAll(configuredSourceProxies);
    chainProxies = buildProxyChainProxies(const [], sourceProxies);
  }

  if (rawProxies is List && removedInternalProxy) {
    config['proxies'] = cleanProxies;
  }
  if (rawGroups is List && removedGroupReference) {
    config['proxy-groups'] = cleanGroups;
  }
  return ProxyChainOverlay(
    sourceProxies: sourceProxies,
    availableProxyNames: availableProxyNames,
    proxyNames: proxyNames,
    chainProxies: chainProxies,
    resetReason: resetReason,
  );
}

bool _hasProxyGroupSource(Map<String, dynamic> group) {
  final use = group['use'];
  if (use is List && use.isNotEmpty) {
    return true;
  }
  return group['include-all-proxies'] == true ||
      group['include-all-providers'] == true ||
      group['include-all'] == true;
}

String _proxyGroupFallbackName(
  Map<String, dynamic> group,
  Set<String> knownProxyNames,
  Set<String> configuredGroupNames,
) {
  // Respect a valid configured fallback, while avoiding group names (which
  // mihomo explicitly disallows for `empty-fallback`).
  final fallback = group['empty-fallback'];
  if (fallback is String &&
      knownProxyNames.contains(fallback) &&
      !configuredGroupNames.contains(fallback)) {
    return fallback;
  }
  return 'COMPATIBLE';
}
