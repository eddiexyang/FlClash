import 'dart:convert';

import 'package:fl_clash/common/constant.dart';

class ProxyChainOverlay {
  final Map<String, Map<String, dynamic>> sourceProxies;
  final List<Map<String, dynamic>> chainProxies;

  const ProxyChainOverlay({
    required this.sourceProxies,
    required this.chainProxies,
  });
}

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

String displayProxyName(String name) {
  if (name == internalChainProxyName) {
    return 'Chain';
  }
  if (!name.startsWith(internalChainHopPrefix)) {
    return name;
  }
  final value = name.substring(internalChainHopPrefix.length);
  final separator = value.indexOf('_');
  if (separator == -1 || separator == value.length - 1) {
    return 'Chain';
  }
  try {
    final encodedName = value.substring(separator + 1);
    final normalizedName = base64Url.normalize(encodedName);
    return utf8.decode(base64Url.decode(normalizedName));
  } catch (_) {
    return 'Chain';
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

Map<String, dynamic>? _builtInProxy(String name) {
  return switch (name) {
    'DIRECT' => {'name': name, 'type': 'direct'},
    'REJECT' => {'name': name, 'type': 'reject'},
    _ => null,
  };
}

List<Map<String, dynamic>> buildProxyChainProxies(
  List<String> proxyNames,
  Map<String, Map<String, dynamic>> sourceProxies,
) {
  final chainSources = <Map<String, dynamic>>[];
  for (final name in proxyNames) {
    if (isInternalChainProxyName(name)) {
      throw ArgumentError.value(name, 'proxyNames', 'Invalid proxy name');
    }
    final source = sourceProxies[name] ?? _builtInProxy(name);
    if (source == null) {
      throw StateError('Proxy "$name" is unavailable in the current profile');
    }
    chainSources.add(source);
  }

  final chainProxies = <Map<String, dynamic>>[];
  String? previousProxyName;
  for (var index = 0; index < chainSources.length; index++) {
    final isLast = index == chainSources.length - 1;
    final internalName = isLast
        ? internalChainProxyName
        : internalChainHopName(index, proxyNames[index]);
    final proxy = Map<String, dynamic>.from(chainSources[index])
      ..['name'] = internalName
      ..remove('dialer-proxy');
    if (previousProxyName != null) {
      proxy['dialer-proxy'] = previousProxyName;
    }
    chainProxies.add(proxy);
    previousProxyName = internalName;
  }
  if (chainProxies.isEmpty) {
    chainProxies.add({
      'name': internalChainProxyName,
      'type': 'reject',
    });
  }
  return chainProxies;
}

/// Adds a GUI-managed proxy chain to a regular mihomo configuration.
///
/// Every hop is a copy of its profile proxy and uses mihomo's native
/// `dialer-proxy` option. No Chain-specific mihomo adapter is required.
ProxyChainOverlay applyProxyChainOverlay(
  Map<String, dynamic> config,
  List<String> requestedProxyNames, {
  Map<String, Map<String, dynamic>> fallbackSourceProxies = const {},
}) {
  final sourceProxies = <String, Map<String, dynamic>>{};
  final cleanProxies = <Object?>[];
  final rawProxies = config['proxies'];
  if (rawProxies is List) {
    for (final rawProxy in rawProxies) {
      final proxy = _toStringMap(rawProxy);
      final name = proxy?['name'];
      if (name is String && isInternalChainProxyName(name)) {
        continue;
      }
      cleanProxies.add(rawProxy);
      if (proxy != null && name is String) {
        sourceProxies.putIfAbsent(name, () => proxy);
      }
    }
  }

  Map<String, dynamic>? proxyGroup;
  final rawGroups = config['proxy-groups'];
  if (rawGroups is List) {
    final cleanGroups = <Object?>[];
    for (final rawGroup in rawGroups) {
      final group = _toStringMap(rawGroup);
      if (group == null) {
        cleanGroups.add(rawGroup);
        continue;
      }
      final rawGroupProxies = group['proxies'];
      if (rawGroupProxies is List) {
        group['proxies'] = rawGroupProxies.where((name) {
          return name is! String || !isInternalChainProxyName(name);
        }).toList();
      }
      final name = group['name'];
      if (proxyGroup == null &&
          name is String &&
          name.toLowerCase() == 'proxy') {
        proxyGroup = group;
      }
      cleanGroups.add(group);
    }
    config['proxy-groups'] = cleanGroups;
  }

  final targetGroup = proxyGroup;
  if (targetGroup == null) {
    config['proxies'] = cleanProxies;
    if (requestedProxyNames.isNotEmpty) {
      throw StateError('PROXY group is unavailable in the current profile');
    }
    return ProxyChainOverlay(
      sourceProxies: sourceProxies,
      chainProxies: const [],
    );
  }

  for (final name in requestedProxyNames) {
    if (!sourceProxies.containsKey(name) &&
        fallbackSourceProxies.containsKey(name)) {
      sourceProxies[name] = Map<String, dynamic>.from(
        fallbackSourceProxies[name]!,
      );
    }
  }
  final chainProxies = buildProxyChainProxies(
    requestedProxyNames,
    sourceProxies,
  );

  config['proxies'] = [...cleanProxies, ...chainProxies];
  final rawGroupProxies = targetGroup['proxies'];
  final groupProxies = rawGroupProxies is List
      ? List<Object?>.from(rawGroupProxies)
      : <Object?>[];
  targetGroup['proxies'] = [internalChainProxyName, ...groupProxies];
  return ProxyChainOverlay(
    sourceProxies: sourceProxies,
    chainProxies: chainProxies,
  );
}
