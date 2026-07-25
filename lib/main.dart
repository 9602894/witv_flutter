import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'screens/home_screen.dart';
import 'services/settings_service.dart';
import 'services/log_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LogService.init();

  // 同步初始化 media_kit，确保在播放器使用前完成
  try {
    MediaKit.ensureInitialized();
    await LogService.write('MediaKit 初始化成功');
  } catch (e, stack) {
    await LogService.writeCrashLog(e, stack);
    // 即使失败也继续启动，播放器会尝试重试
  }

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
