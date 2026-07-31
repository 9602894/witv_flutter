import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:stack_trace/stack_trace.dart' as stack_trace;

class LogService {
  static File? _logFile;
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-');
      final logDir = Directory('${dir.path}/logs');
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      final fileName = 'app_$timestamp.log';
      _logFile = File('${logDir.path}/$fileName');
      await _logFile!.create(recursive: true); // 使用 ! 确保非空
      await write('=== 应用启动 ===');
      _initialized = true;
    } catch (e) {
      print('LogService init error: $e');
    }
  }

  static Future<void> write(String message) async {
    try {
      if (_logFile == null) await init();
      final line = '[${DateTime.now().toIso8601String()}] $message\n';
      await _logFile!.writeAsString(line, mode: FileMode.append);
    } catch (e) {
      // 静默失败
    }
  }

  static Future<void> writeCrashLog(dynamic error, StackTrace? stack) async {
    try {
      final trace = stack != null ? stack_trace.Trace.from(stack).terse : 'null';
      final lines = [
        '=== CRASH ===',
        'Error: $error',
        'Stack: $trace',
        '=== END CRASH ===',
      ];
      await write(lines.join('\n'));
    } catch (e) {
      // 忽略
    }
  }

  // 导出日志文件（供设置界面使用）
  static Future<File?> export() async {
    if (_logFile == null) await init();
    return _logFile;
  }

  // 可选清理旧日志
  static Future<void> cleanOldLogs({int keepCount = 10}) async {
    try {
      if (_logFile == null) return;
      final dir = _logFile!.parent;
      if (!await dir.exists()) return;
      final files = await dir.list().where((e) => e is File && e.path.endsWith('.log')).toList();
      if (files.length <= keepCount) return;
      files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      for (var i = 0; i < files.length - keepCount; i++) {
        await files[i].delete();
      }
    } catch (e) {
      // 忽略
    }
  }
}
