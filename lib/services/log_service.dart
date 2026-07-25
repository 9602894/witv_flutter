import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class LogService {
  static final LogService _instance = LogService._internal();
  factory LogService() => _instance;
  LogService._internal();

  static const String logFileName = 'witv_log.txt';
  static File? _logFile;

  /// 初始化日志文件（使用内部存储，避免权限问题）
  static Future<void> init() async {
    try {
      final internalDir = await getApplicationDocumentsDirectory();
      _logFile = File('${internalDir.path}/$logFileName');
    } catch (e) {
      final tempDir = Directory.systemTemp;
      _logFile = File('${tempDir.path}/$logFileName');
    }

    if (await _logFile!.exists()) {
      final size = await _logFile!.length();
      if (size > 1024 * 1024) {
        final dir = _logFile!.parent;
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final newName = 'witv_log_$timestamp.txt';
        await _logFile!.rename('${dir.path}/$newName');
        _logFile = File('${dir.path}/$logFileName');
      }
    }
    await write('=== 日志系统初始化，日志路径: ${_logFile!.path} ===');
  }

  /// 写入日志（返回 Future<void>）
  static Future<void> write(String message) async {
    if (_logFile == null) await init();
    final timestamp = DateTime.now().toIso8601String();
    final line = '[$timestamp] $message\n';
    try {
      await _logFile!.writeAsString(line, mode: FileMode.append);
    } catch (e) {
      // 忽略写入错误
    }
  }

  /// 写入崩溃日志（返回 Future<void>）
  static Future<void> writeCrashLog(dynamic error, dynamic stack) async {
    final message = 'CRASH: $error\nStack: $stack';
    await write(message);
  }

  static Future<String> read() async {
    if (_logFile == null) await init();
    if (!await _logFile!.exists()) return '';
    return await _logFile!.readAsString();
  }

  static Future<File> export() async {
    if (_logFile == null) await init();
    final dir = _logFile!.parent;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final exportFile = File('${dir.path}/witv_log_export_$timestamp.txt');
    final content = await read();
    await exportFile.writeAsString(content);
    return exportFile;
  }
}
