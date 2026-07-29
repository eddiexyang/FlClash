import 'dart:async';

import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCoreHandler extends CoreHandlerInterface {
  _FakeCoreHandler({
    required this.response,
    this.connected = true,
    this.responseDelay = Duration.zero,
  }) {
    if (connected) {
      _completer.complete(true);
    }
  }

  final bool? response;
  final bool connected;
  final Duration responseDelay;
  final Completer<bool> _completer = Completer<bool>();

  ActionMethod? invokedMethod;
  Duration? invokedTimeout;
  int invocationCount = 0;

  @override
  Completer get completer => _completer;

  @override
  FutureOr<bool> destroy() => true;

  @override
  Future<String> preload() async => '';

  @override
  Future<bool> shutdown(bool isUser) async => true;

  @override
  Future<T?> invoke<T>({
    required ActionMethod method,
    dynamic data,
    Duration? timeout,
  }) async {
    invocationCount++;
    invokedMethod = method;
    invokedTimeout = timeout;
    if (responseDelay > Duration.zero) {
      await Future<void>.delayed(responseDelay);
    }
    return response as T?;
  }
}

void main() {
  test('core health uses the control channel getIsInit action', () async {
    final handler = _FakeCoreHandler(response: true);
    const timeout = Duration(milliseconds: 50);

    expect(await handler.checkHealth(timeout: timeout), isTrue);
    expect(handler.invocationCount, 1);
    expect(handler.invokedMethod, ActionMethod.getIsInit);
    expect(handler.invokedTimeout, timeout);
  });

  test('core health fails without a connected control channel', () async {
    final handler = _FakeCoreHandler(response: true, connected: false);

    expect(await handler.checkHealth(), isFalse);
    expect(handler.invocationCount, 0);
  });

  test('core health rejects a negative initialization response', () async {
    final handler = _FakeCoreHandler(response: false);

    expect(await handler.checkHealth(), isFalse);
  });

  test('core health is bounded by its timeout', () async {
    final handler = _FakeCoreHandler(
      response: true,
      responseDelay: const Duration(milliseconds: 100),
    );

    expect(
      await handler.checkHealth(
        timeout: const Duration(milliseconds: 10),
      ),
      isFalse,
    );
  });
}
