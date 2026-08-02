import 'package:fl_clash/common/http.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const remoteUrl = 'https://example.com/profile.yaml';

  test('uses the normal network path when system proxy is disabled', () {
    final proxy = FlClashHttpOverrides.resolveProxy(
      Uri.parse(remoteUrl),
      isStart: true,
      systemProxy: false,
      port: 64444,
    );

    expect(proxy, 'DIRECT');
  });

  test('uses the mixed listener when system proxy is enabled', () {
    final proxy = FlClashHttpOverrides.resolveProxy(
      Uri.parse(remoteUrl),
      isStart: true,
      systemProxy: true,
      port: 64444,
    );

    expect(proxy, 'PROXY localhost:64444');
  });

  test('uses the normal network path while the core is stopped', () {
    final proxy = FlClashHttpOverrides.resolveProxy(
      Uri.parse(remoteUrl),
      isStart: false,
      systemProxy: true,
      port: 64444,
    );

    expect(proxy, 'DIRECT');
  });

  test('never sends loopback traffic back through the mixed listener', () {
    for (final url in [
      'http://localhost:1234/ping',
      'http://127.0.0.1:1234/ping',
      'http://[::1]:1234/ping',
    ]) {
      final proxy = FlClashHttpOverrides.resolveProxy(
        Uri.parse(url),
        isStart: true,
        systemProxy: true,
        port: 64444,
      );

      expect(proxy, 'DIRECT', reason: url);
    }
  });
}
