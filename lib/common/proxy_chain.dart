import 'dart:convert';

import 'package:fl_clash/common/constant.dart';

final _internalChainHopPattern = RegExp(
  '${RegExp.escape(internalChainHopPrefix)}[0-9]+_[A-Za-z0-9_-]+',
);

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

String displayProxyText(String text) {
  return text
      .replaceAll(internalChainProxyName, 'Chain')
      .replaceAllMapped(
        _internalChainHopPattern,
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

/// Adds a GUI-managed proxy chain to a regular mihomo configuration.
///
/// Every hop is a copy of its profile proxy and uses mihomo's native
/// `dialer-proxy` option. The core receives no Chain-specific runtime state.
List<String> applyProxyChainOverlay(
  Map<String, dynamic> config,
  List<String> requestedProxyNames,
) {
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
    return const [];
  }

  final effectiveProxyNames = <String>[];
  final chainSources = <Map<String, dynamic>>[];
  for (final name in requestedProxyNames) {
    if (isInternalChainProxyName(name)) {
      continue;
    }
    final source = sourceProxies[name] ?? _builtInProxy(name);
    if (source == null) {
      continue;
    }
    effectiveProxyNames.add(name);
    chainSources.add(source);
  }

  final chainProxies = <Map<String, dynamic>>[];
  String? previousProxyName;
  for (var index = 0; index < chainSources.length; index++) {
    final isLast = index == chainSources.length - 1;
    final internalName = isLast
        ? internalChainProxyName
        : internalChainHopName(index, effectiveProxyNames[index]);
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

  config['proxies'] = [...cleanProxies, ...chainProxies];
  final rawGroupProxies = targetGroup['proxies'];
  final groupProxies = rawGroupProxies is List
      ? List<Object?>.from(rawGroupProxies)
      : <Object?>[];
  targetGroup['proxies'] = [internalChainProxyName, ...groupProxies];
  return effectiveProxyNames;
}
