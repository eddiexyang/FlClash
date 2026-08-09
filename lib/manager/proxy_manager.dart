import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProxyManager extends ConsumerStatefulWidget {
  final Widget child;

  const ProxyManager({super.key, required this.child});

  @override
  ConsumerState createState() => _ProxyManagerState();
}

class _ProxyManagerState extends ConsumerState<ProxyManager> {
  Future<void> _updateQueue = Future.value();
  int _proxyRevision = 0;

  Future<bool> _updateProxy(ProxyState proxyState) async {
    final isStart = proxyState.isStart;
    final systemProxy = proxyState.systemProxy;
    final port = proxyState.port;
    if (isStart && systemProxy) {
      return await proxy?.startProxy(port, proxyState.bassDomain) == true;
    }
    return await proxy?.stopProxy() == true;
  }

  void _scheduleProxyUpdate(ProxyState proxyState) {
    final revision = ++_proxyRevision;
    final detectionCheckId = appController.isAttach
        ? ref.read(networkDetectionProvider.notifier).invalidateCheck()
        : null;
    _updateQueue = _updateQueue
        .then((_) async {
          if (revision != _proxyRevision || !mounted) {
            return;
          }
          var didApply = false;
          try {
            didApply = await _updateProxy(proxyState);
          } catch (error, stackTrace) {
            commonPrint.log(
              'update_system_proxy_failed error=$error stack=$stackTrace',
              logLevel: LogLevel.warning,
            );
          }
          if (revision != _proxyRevision || !mounted) {
            return;
          }
          if (!didApply) {
            commonPrint.log(
              'update_system_proxy_failed state=$proxyState',
              logLevel: LogLevel.warning,
            );
            if (detectionCheckId != null) {
              ref
                  .read(networkDetectionProvider.notifier)
                  .finishInvalidatedCheck(detectionCheckId);
            }
            return;
          }
          if (appController.isAttach) {
            appController.addCheckIp();
          } else if (detectionCheckId != null) {
            ref
                .read(networkDetectionProvider.notifier)
                .finishInvalidatedCheck(detectionCheckId);
          }
        })
        .catchError((error, stackTrace) {
          commonPrint.log(
            'update_system_proxy_queue_failed error=$error stack=$stackTrace',
            logLevel: LogLevel.warning,
          );
        });
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      proxyStateProvider,
      (prev, next) {
        if (prev != next) {
          _scheduleProxyUpdate(next);
        }
      },
      fireImmediately: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
