import 'dart:io';
import 'package:path_provider/path_provider.dart';

class LogService {
  static final LogService _instance = LogService._internal();
  factory LogService() => _instance;
  LogService._internal();

  static const String logFileName = 'witv_log.txt';
  static File? _logFile;
  static bool _initialized = false;

  /// 初始化日志文件（使用内部存储，避免权限问题）
  static Future<void> init() async {
    if (_initialized) return;
    try {
      final internalDir = await getApplicationDocumentsDirectory();
      _logFile = File('${internalDir.path}/$logFileName');
    } catch (e) {
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
    _initialized = true;
    // 写入初始化信息，不等待
    _writeInternal('=== 日志系统初始化，日志路径: ${_logFile!.path} ===');
  }

  /// 内部写入方法，不等待完成
  static void _writeInternal(String message) {
    if (_logFile == null) return;
    final timestamp = DateTime.now().toIso8601String();
    final line = '[$timestamp] $message\n';
    // 使用 unawaited 在后台执行，不阻塞调用者
    unawaited(_logFile!.writeAsString(line, mode: FileMode.append).catchError((e) {}));
  }

  /// 写入日志（外部调用，不阻塞）
  static void write(String message) {
    if (!_initialized) {
      // 如果未初始化，先同步初始化
      init().then((_) => _writeInternal(message));
      return;
    }
    _writeInternal(message);
  }

  /// 写入崩溃日志
  static void writeCrashLog(dynamic error, dynamic stack) {
    final message = 'CRASH: $error\nStack: $stack';
    write(message);
  }

  /// 读取完整日志（同步，用于导出）
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
