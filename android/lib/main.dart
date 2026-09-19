import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n.dart';
import 'theme.dart';
import 'ui/home.dart';
import 'ui/editor.dart';
import 'ui/settings.dart';
import 'ui/lock.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.instance.load();
  runApp(const AppRoot());
}

/// 应用根：承载主题切换 + 语言切换 + 应用锁（启动/从后台返回需输入 PIN）。
class AppRoot extends StatefulWidget {
  const AppRoot({super.key});
  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> with WidgetsBindingObserver {
  bool _locked = AppSettings.instance.lockPin != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_locked) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed && AppSettings.instance.lockPin != null) {
      setState(() => _locked = true);
    }
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<int>(
        valueListenable: uiVersion,
        builder: (_, __, ___) {
          final mode = AppSettings.instance.themeMode;
          final resolved = mode == AppThemeMode.system
              ? (WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                      Brightness.dark
                  ? AppThemeMode.dark
                  : AppThemeMode.light)
              : mode;
          return MaterialApp(
            title: 'Hydro Note',
            theme: AppThemes.of(resolved),
            locale: L.localeOf(),
            supportedLocales: L.supportedLocales,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: _locked
                ? PinScreen(onUnlock: () {
                    _locked = false;
                    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
                    setState(() {});
                  })
                : const HomePage(),
            routes: {
              '/editor': (c) =>
                  EditorPage(ModalRoute.of(c)!.settings.arguments as String),
              '/settings': (c) => const SettingsPage(),
            },
            debugShowCheckedModeBanner: false,
          );
        },
      );
}
