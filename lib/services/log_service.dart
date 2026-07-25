import 'dart:io';
import 'package:path_provider/path_provider.dart';

class LogService {
  static final LogService _instance = LogService._internal();
  factory LogService() => _instance;
  LogService._internal();

  static const String logFileName = 'witv_log.txt';
  static File? _logFile;
  static bool _initialized = false;

  /// 初始化日志文件，带超时和回退
  static Future<void> init() async {
    if (_initialized) return;
    try {
      // 尝试获取外部存储目录，若超时或失败则回退内部
      Directory? externalDir;
      try {
        externalDir = await getExternalStorageDirectory().timeout(Duration(seconds: 2));
      } catch (e) {
        // ignore
      }
      if (externalDir != null) {
        _logFile = File('${externalDir.path}/$logFileName');
      } else {
        final internalDir = await getApplicationDocumentsDirectory();
        _logFile = File('${internalDir.path}/$logFileName');
      }

      // 检查文件大小，超过1MB轮转
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
      _initialized = true;
      await write('=== 日志系统初始化，日志路径: ${_logFile!.path} ===');
    } catch (e) {
      // 若全部失败，使用临时目录
      final tempDir = Directory.systemTemp;
      _logFile = File('${tempDir.path}/$logFileName');
      _initialized = true;
      await write('=== 日志系统初始化（临时目录），日志路径: ${_logFile!.path} ===');
    }
  }

  /// 写入日志（自动初始化）
  static Future<void> write(String message) async {
    if (!_initialized) await init();
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

  /// 读取日志
  static Future<String> read() async {
    if (!_initialized) await init();
    if (!await _logFile!.exists()) return '';
    return await _logFile!.readAsString();
  }

  /// 导出日志
  static Future<File> export() async {
    if (!_initialized) await init();
    final dir = _logFile!.parent;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final exportFile = File('${dir.path}/witv_log_export_$timestamp.txt');
    final content = await read();
    await exportFile.writeAsString(content);
    return exportFile;
  }

  /// 获取日志文件路径
  static String get logFilePath => _logFile?.path ?? '';
}
