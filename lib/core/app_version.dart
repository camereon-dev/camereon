import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Read the installed APK, including CI's build name and build number.
class AppVersion extends StatefulWidget {
  const AppVersion({super.key});

  @override
  State<AppVersion> createState() => _AppVersionState();
}

class _AppVersionState extends State<AppVersion> {
  late final _version = const MethodChannel('dev.camereon/app_info')
      .invokeMapMethod<String, String>('version');

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, String>?>(
    future: _version,
    builder: (context, snapshot) {
      final info = snapshot.data;
      return Text(
        info == null
            ? (snapshot.hasError ? 'バージョンを取得できませんでした' : 'バージョンを確認中…')
            : 'バージョン ${info['versionName']} (${info['versionCode']})',
        style: Theme.of(context).textTheme.bodySmall,
      );
    },
  );
}
