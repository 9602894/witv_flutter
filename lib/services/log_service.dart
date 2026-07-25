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
      // 若获取目录失败，使用临时目录
      final tempDir = Directory.systemTemp;
      _logFile = File('${tempDir.path}/$logFileName');
    }

    // 如果文件超过1MB，重命名旧文件
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

  /// 写入日志（非阻塞）
  static Future<void> write(String message) async {
    if (_logFile == null) await init();
    final timestamp = DateTime.now().toIso8601String();
    final line = '[$timestamp] $message\n';
    try {
      await _logFile!.writeAsString(line, mode: FileMode.append);
    } catch (e) {
      // 避免递归
    }
  }

  /// 写入崩溃日志
  static Future<void> writeCrashLog(dynamic error, dynamic stack) async {
    final message = 'CRASH: $error\nStack: $stack';
    await write(message);
  }

  /// 读取完整日志
  static Future<String> read() async {
    if (_logFile == null) await init();
    if (!await _logFile!.exists()) return '';
    return await _logFile!.readAsString();
  }

  /// 导出日志
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
