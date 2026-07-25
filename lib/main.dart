import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'screens/home_screen.dart';
import 'services/settings_service.dart';
import 'services/log_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LogService.init();

  // 使用 scheduleMicrotask 延迟初始化 MediaKit，避免阻塞 UI 启动
  scheduleMicrotask(() {
    try {
      MediaKit.ensureInitialized();
      LogService.write('MediaKit 初始化成功');
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  });

  // 捕获错误
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
    LogService.writeCrashLog(details.exception, details.stack);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    LogService.writeCrashLog(error, stack);
    return true;
  };

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => SettingsService(),
      child: MaterialApp(
        title: 'Witv',
        theme: ThemeData.dark(),
        home: HomeScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
