import 'package:fl_clash/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/material.dart';

class CommonPrint {
  static CommonPrint? _instance;
  static const int _maxPendingLogs = 5000;

  final List<Log> _pendingLogs = [];

  CommonPrint._internal();

  factory CommonPrint() {
    _instance ??= CommonPrint._internal();
    return _instance!;
  }

  void log(String? text, {LogLevel logLevel = LogLevel.info}) {
    final payload = '[APP] $text';
    final log = Log.app(payload).copyWith(logLevel: logLevel);
    debugPrint(payload);
    if (!appController.isAttach) {
      if (_pendingLogs.length >= _maxPendingLogs) {
        _pendingLogs.removeAt(0);
      }
      _pendingLogs.add(log);
      return;
    }
    flush();
    appController.addLog(log);
  }

  void flush() {
    if (!appController.isAttach || _pendingLogs.isEmpty) {
      return;
    }
    for (final log in _pendingLogs) {
      appController.addLog(log);
    }
    _pendingLogs.clear();
  }
}

final commonPrint = CommonPrint();
