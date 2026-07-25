import 'dart:io';
import 'package:path_provider/path_provider.dart';

class LogService {
  static File? _logFile;

  static Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _logFile = File('${dir.path}/witv_log.txt');
      await _logFile!.writeAsString('', mode: FileMode.append);
      await write('=== 日志系统初始化 ===');
    } catch (e) {
      // 忽略
    }
  }

  static Future<void> write(String message) async {
    if (_logFile == null) return;
    final timestamp = DateTime.now().toIso8601String();
    final line = '[$timestamp] $message\n';
    try {
      await _logFile!.writeAsString(line, mode: FileMode.append);
    } catch (e) {
      // 忽略
    }
  }

  static Future<void> writeCrashLog(dynamic error, dynamic stack) async {
    await write('CRASH: $error\nStack: $stack');
  }

  static Future<String> read() async {
    if (_logFile == null) return '';
    if (!await _logFile!.exists()) return '';
    return await _logFile!.readAsString();
  }

  static Future<File> export() async {
    if (_logFile == null) await init();
    final dir = _logFile!.parent;
    final exportFile = File('${dir.path}/witv_log_export_${DateTime.now().millisecondsSinceEpoch}.txt');
    final content = await read();
    await exportFile.writeAsString(content);
    return exportFile;
  }
}
