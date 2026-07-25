import 'dart:io';
import 'package:path_provider/path_provider.dart';

class LogService {
  static final LogService _instance = LogService._internal();
  factory LogService() => _instance;
  LogService._internal();

  static const String logFileName = 'witv_log.txt';
  static File? _logFile;
  static String? _logDirPath;

  /// 初始化日志（优先外部存储，便于用户直接访问）
  static Future<void> init() async {
    try {
      Directory? dir;
      // 尝试获取外部存储目录（Android/data/包名/files）
      try {
        final externalDir = await getExternalStorageDirectory();
        if (externalDir != null) {
          dir = externalDir;
        }
      } catch (_) {}

      // 如果外部存储不可用，回退到内部文档目录
      if (dir == null) {
        dir = await getApplicationDocumentsDirectory();
      }

      _logDirPath = dir.path;
      _logFile = File('${dir.path}/$logFileName');

      // 如果文件超过1MB，重命名
      if (await _logFile!.exists()) {
        final size = await _logFile!.length();
        if (size > 1024 * 1024) {
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final newName = 'witv_log_$timestamp.txt';
          await _logFile!.rename('${dir.path}/$newName');
          _logFile = File('${dir.path}/$logFileName');
        }
      }
    } catch (e) {
      // 如果都失败，使用临时目录（极少情况）
      final tempDir = Directory.systemTemp;
      _logFile = File('${tempDir.path}/$logFileName');
      _logDirPath = tempDir.path;
    }
    await write('=== 日志系统初始化，日志路径: ${_logFile!.path} ===');
  }

  static Future<void> write(String message) async {
    if (_logFile == null) await init();
    final timestamp = DateTime.now().toIso8601String();
    final line = '[$timestamp] $message\n';
    try {
      await _logFile!.writeAsString(line, mode: FileMode.append);
    } catch (_) {}
  }

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

  static String get logDirPath => _logDirPath ?? '';
}
