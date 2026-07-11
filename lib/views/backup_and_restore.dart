import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/dialog.dart';
import 'package:fl_clash/widgets/input.dart';
import 'package:fl_clash/widgets/list.dart';
import 'package:fl_clash/widgets/scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

class BackupAndRestore extends ConsumerWidget {
  const BackupAndRestore({super.key});

  Future<void> _backupOnLocal() async {
    final res = await appController.loadingRun<bool>(
      () async {
        final path = await appController.backup();
        if (path.isEmpty) {
          return false;
        }
        final value = await picker.saveFileWithPath(
          utils.getBackupFileName(),
          path,
        );
        if (value == null) return false;
        return true;
      },
      title: appLocalizations.backup,
      tag: LoadingTag.backup_restore,
    );
    if (res != true) return;
    globalState.showMessage(
      title: appLocalizations.backup,
      message: TextSpan(text: appLocalizations.backupSuccess),
    );
  }

  Future<void> _restoreOnLocal(RestoreOption option) async {
    final file = await picker.pickerFile(withData: false);
    final path = file?.path;
    if (path == null) return;
    await File(path).safeCopy(await appPath.backupFilePath);
    final res = await appController.loadingRun<bool>(
      () async {
        await appController.restore(option);
        return true;
      },
      tag: LoadingTag.backup_restore,
      title: appLocalizations.restore,
    );
    if (res != true) return;
    globalState.showMessage(
      title: appLocalizations.restore,
      message: TextSpan(text: appLocalizations.restoreSuccess),
    );
  }

  Future<void> _handleRestoreOnLocal(BuildContext context) async {
    final option = await globalState.showCommonDialog<RestoreOption>(
      child: const RestoreOptionsDialog(),
    );
    if (option == null || !context.mounted) return;
    _restoreOnLocal(option);
  }

  Future<void> _handleUpdateRestoreStrategy(WidgetRef ref) async {
    final restoreStrategy = ref.read(
      appSettingProvider.select((state) => state.restoreStrategy),
    );
    final res = await globalState.showCommonDialog(
      child: OptionsDialog<RestoreStrategy>(
        title: appLocalizations.restoreStrategy,
        options: RestoreStrategy.values,
        textBuilder: (mode) => Intl.message('restoreStrategy_${mode.name}'),
        value: restoreStrategy,
      ),
    );
    if (res == null) {
      return;
    }
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(restoreStrategy: res));
  }

  @override
  Widget build(BuildContext context, ref) {
    final isLoading = ref.watch(loadingProvider(LoadingTag.backup_restore));
    return CommonScaffold(
      isLoading: isLoading,
      title: appLocalizations.backupAndRestore,
      body: ListView(
        children: [
          ListItem(
            onTap: () {
              _backupOnLocal();
            },
            title: Text(appLocalizations.backup),
            subtitle: Text(appLocalizations.localBackupDesc),
          ),
          ListItem(
            onTap: () {
              _handleRestoreOnLocal(context);
            },
            title: Text(appLocalizations.restore),
            subtitle: Text(appLocalizations.restoreFromFileDesc),
          ),
          ListHeader(title: appLocalizations.options),
          Consumer(
            builder: (_, ref, _) {
              final restoreStrategy = ref.watch(
                appSettingProvider.select((state) => state.restoreStrategy),
              );
              return ListItem(
                onTap: () {
                  _handleUpdateRestoreStrategy(ref);
                },
                title: Text(appLocalizations.restoreStrategy),
                trailing: FilledButton(
                  onPressed: () {
                    _handleUpdateRestoreStrategy(ref);
                  },
                  child: Text(
                    Intl.message('restoreStrategy_${restoreStrategy.name}'),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class RestoreOptionsDialog extends StatefulWidget {
  const RestoreOptionsDialog({super.key});

  @override
  State<RestoreOptionsDialog> createState() => _RestoreOptionsDialogState();
}

class _RestoreOptionsDialogState extends State<RestoreOptionsDialog> {
  void _handleOnTab(RestoreOption? option) {
    if (option == null) return;
    Navigator.of(context).pop(option);
  }

  @override
  Widget build(BuildContext context) {
    return CommonDialog(
      title: appLocalizations.restore,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
      child: Wrap(
        children: [
          ListItem(
            onTap: () {
              _handleOnTab(RestoreOption.onlyProfiles);
            },
            title: Text(appLocalizations.restoreOnlyConfig),
          ),
          ListItem(
            onTap: () {
              _handleOnTab(RestoreOption.all);
            },
            title: Text(appLocalizations.restoreAllData),
          ),
        ],
      ),
    );
  }
}
