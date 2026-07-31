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
      await _logFile.create(recursive: true);
      await write('=== 应用启动 ===');
      _initialized = true;
    } catch (e) {
      // 如果无法创建日志文件，输出到控制台
      print('LogService init error: $e');
    }
  }

  static Future<void> write(String message) async {
    try {
      if (_logFile == null) await init();
      final line = '[${DateTime.now().toIso8601String()}] $message\n';
      await _logFile!.writeAsString(line, mode: FileMode.append);
    } catch (e) {
      // 静默失败，避免干扰主逻辑
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
      // 忽略写入错误
    }
  }

  // 可选：清理旧日志（保留最近N个文件）
  static Future<void> cleanOldLogs({int keepCount = 10}) async {
    try {
      final dir = _logFile?.parent;
      if (dir == null || !await dir.exists()) return;
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
