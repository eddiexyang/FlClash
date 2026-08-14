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
}) {
  final chainProxy =
      _proxyFromData(proxiesData.proxies, internalChainProxyName) ??
      const Proxy(name: internalChainProxyName, type: 'Relay');
  return groups
      .map(
        (group) => group.copyWith(
          all: [
            chainProxy,
            ...group.all.where(
              (proxy) => !isInternalChainProxyName(proxy.name),
            ),
          ],
        ),
      )
      .toList();
}
