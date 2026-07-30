import 'dart:io';
import 'package:path_provider/path_provider.dart';

class LogService {
  static const String logFileName = 'witv_log.txt';
  static File? _logFile;

  static Future<void> init() async {
    try {
      // 获取外部存储目录（应用专属）
      final externalDir = await getExternalStorageDirectory();
      if (externalDir != null) {
        _logFile = File('${externalDir.path}/$logFileName');
      } else {
        // 若外部不可用，回退到内部
        final internalDir = await getApplicationDocumentsDirectory();
        _logFile = File('${internalDir.path}/$logFileName');
      }
      // 确保父目录存在
      await _logFile!.parent.create(recursive: true);
    } catch (e) {
      // 如果都失败，使用临时目录
      final tempDir = Directory.systemTemp;
      _logFile = File('${tempDir.path}/$logFileName');
    }
    // 如果文件超过1MB，轮转
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

  static Future<void> write(String message) async {
    if (_logFile == null) await init();
    final timestamp = DateTime.now().toIso8601String();
    final line = '[$timestamp] $message\n';
    try {
      await _logFile!.writeAsString(line, mode: FileMode.append);
    } catch (e) {
      // ignore
    }
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
}
