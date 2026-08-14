import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';

import 'constant.dart';
import 'proxy_chain.dart';

Proxy? _proxyFromData(
  Map<String, dynamic> proxies,
  String proxyName,
) {
  final rawProxy = proxies[proxyName];
  if (rawProxy is! Map) {
    return null;
  }
  final proxy = <String, Object?>{
    for (final entry in rawProxy.entries) entry.key.toString(): entry.value,
  }..putIfAbsent('name', () => proxyName);
  if (proxy['type'] is! String) {
    return null;
  }
  return Proxy.fromJson(proxy);
}

List<Group> buildProxyChainGuiGroups({
  required List<Group> groups,
  required ProxiesData proxiesData,
  required List<String> sourceProxyNames,
  required String testUrl,
}) {
  final chainProxies = sourceProxyNames
      .map((name) => _proxyFromData(proxiesData.proxies, name))
      .whereType<Proxy>()
      .toList();
  final chainProxy =
      _proxyFromData(proxiesData.proxies, internalChainProxyName) ??
      const Proxy(name: internalChainProxyName, type: 'Relay');
  final regularGroups = groups
      .where((group) => !isProxyChainEditorGroup(group.name))
      .map(
        (group) => group.copyWith(
          all: [
            chainProxy,
            ...group.all.where(
              (proxy) => !isInternalChainProxyName(proxy.name),
            ),
          ],
        ),
      );
  return [
    Group(
      type: GroupType.Selector,
      all: chainProxies,
      hidden: false,
      testUrl: testUrl,
      name: internalChainProxyName,
    ),
    ...regularGroups,
  ];
}
