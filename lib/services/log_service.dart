import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart'; // 如需分享日志，可添加此依赖

class LogService {
  static final LogService _instance = LogService._internal();
  factory LogService() => _instance;
  LogService._internal();

  static const String logFileName = 'witv_log.txt';
  static File? _logFile;

  /// 初始化日志文件
  static Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    _logFile = File('${dir.path}/$logFileName');
    // 如果文件超过 1MB，清空
    if (await _logFile!.exists()) {
      final size = await _logFile!.length();
      if (size > 1024 * 1024) {
        await _logFile!.writeAsString('', flush: true);
      }
    }
    await write('=== 日志系统初始化 ===');
  }

  /// 写入日志
  static Future<void> write(String message) async {
    if (_logFile == null) await init();
    final timestamp = DateTime.now().toIso8601String();
    final line = '[$timestamp] $message\n';
    try {
      await _logFile!.writeAsString(line, mode: FileMode.append);
    } catch (e) {
      print('写入日志失败: $e');
    }
  }

  /// 读取完整日志
  static Future<String> read() async {
    if (_logFile == null) await init();
    if (!await _logFile!.exists()) return '';
    return await _logFile!.readAsString();
  }

  /// 清空日志
  static Future<void> clear() async {
    if (_logFile == null) await init();
    await _logFile!.writeAsString('');
    await write('日志已清空');
  }

  /// 导出日志到文件（用于分享或保存）
  static Future<File> export() async {
    if (_logFile == null) await init();
    final dir = await getApplicationDocumentsDirectory();
    final exportFile = File('${dir.path}/witv_log_${DateTime.now().millisecondsSinceEpoch}.txt');
    final content = await read();
    await exportFile.writeAsString(content);
    return exportFile;
  }
}
