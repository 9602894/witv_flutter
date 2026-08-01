import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'screens/home_screen.dart';
import 'services/settings_service.dart';
import 'services/log_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LogService.init();

  LogService.write('开始初始化 MediaKit');
  bool initialized = false;
  try {
    MediaKit.ensureInitialized();
    initialized = true;
    LogService.write('MediaKit 初始化成功');
  } catch (e, stack) {
    LogService.writeCrashLog('MediaKit 初始化失败: $e', stack);
    // 尝试延迟重试一次
    try {
      await Future.delayed(Duration(milliseconds: 500));
      MediaKit.ensureInitialized();
      initialized = true;
      LogService.write('MediaKit 第二次初始化成功');
    } catch (e2, stack2) {
      LogService.writeCrashLog('MediaKit 第二次初始化仍然失败: $e2', stack2);
    }
  }

  // 强制横屏
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // 捕获错误
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
    LogService.writeCrashLog(details.exception, details.stack);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    LogService.writeCrashLog(error, stack);
    return true;
  };

  runApp(MyApp(mediaKitInitialized: initialized));
}

class MyApp extends StatelessWidget {
  final bool mediaKitInitialized;
  const MyApp({Key? key, required this.mediaKitInitialized}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => SettingsService(),
      child: MaterialApp(
        title: 'Witv',
        theme: ThemeData.dark(),
        home: HomeScreen(mediaKitInitialized: mediaKitInitialized),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
