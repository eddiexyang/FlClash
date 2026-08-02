import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';

class FlClashHttpOverrides extends HttpOverrides {
  static String resolveProxy(
    Uri url, {
    required bool isStart,
    required bool systemProxy,
    required int port,
  }) {
    final address = InternetAddress.tryParse(url.host);
    final isLoopback = url.host.toLowerCase() == 'localhost' ||
        (address?.isLoopback ?? false);
    if (isLoopback || !isStart || !systemProxy || port <= 0) {
      return 'DIRECT';
    }
    return 'PROXY localhost:$port';
  }

  static String handleFindProxy(Uri url) {
    final config = appController.config;
    final port = config.patchClashConfig.mixedPort;
    final isStart = appController.isStart;
    final systemProxy = system.isDesktop
        ? config.networkProps.systemProxy
        : config.vpnProps.systemProxy;
    final proxy = resolveProxy(
      url,
      isStart: isStart,
      systemProxy: systemProxy,
      port: port,
    );
    commonPrint.log(
      'find $url proxy:$proxy isStart:$isStart systemProxy:$systemProxy',
    );
    return proxy;
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (_, _, _) => true;
    client.findProxy = handleFindProxy;
    return client;
  }
}
