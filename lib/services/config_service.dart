import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'log_service.dart';

class ConfigService {
  static const String configFileName = 'configuration.json';
  static Map<String, dynamic>? _config;

  static Future<Map<String, dynamic>> getConfig() async {
    if (_config != null) return _config!;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$configFileName');
      String jsonString;
      if (await file.exists()) {
        jsonString = await file.readAsString();
        // 尝试解析
        try {
          final raw = jsonDecode(jsonString) as Map<String, dynamic>;
          if (raw.containsKey('Configuration')) {
            _config = raw;
            await LogService.write('配置加载成功，键数: ${_config?.length}');
            return _config!;
          }
        } catch (e) {
          await LogService.write('外部配置文件解析失败: $e，从 assets 重新复制');
          await file.delete(); // 删除损坏文件
        }
      }
      // 从 assets 复制
      jsonString = await rootBundle.loadString('assets/$configFileName');
      await file.writeAsString(jsonString);
      final raw = jsonDecode(jsonString) as Map<String, dynamic>;
      _config = raw;
      await LogService.write('从 assets 加载配置成功，键数: ${_config?.length}');
    } catch (e) {
      await LogService.write('加载配置失败: $e，使用默认空配置');
      _config = {'Configuration': {}};
    }
    return _config!;
  }

  // 以下方法不变...
  static Future<void> saveConfig(Map<String, dynamic> config) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$configFileName');
    await file.writeAsString(jsonEncode(config));
    _config = config;
  }

  static Future<void> resetToDefault() async {
    final jsonString = await rootBundle.loadString('assets/$configFileName');
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$configFileName');
    await file.writeAsString(jsonString);
    _config = jsonDecode(jsonString) as Map<String, dynamic>;
  }

  static Future<void> backup() async {
    final dir = await getApplicationDocumentsDirectory();
    final src = File('${dir.path}/$configFileName');
    if (!await src.exists()) return;
    final backupDir = Directory('${dir.path}/backup');
    if (!await backupDir.exists()) await backupDir.create();
    final backupFile = File('${backupDir.path}/${DateTime.now().millisecondsSinceEpoch}_$configFileName');
    await src.copy(backupFile.path);
  }

  static Future<List<File>> getBackupFiles() async {
    final dir = await getApplicationDocumentsDirectory();
    final backupDir = Directory('${dir.path}/backup');
    if (!await backupDir.exists()) return [];
    return backupDir.listSync().whereType<File>().where((f) => f.path.endsWith('_$configFileName')).toList();
  }

  static Future<void> restoreFromBackup(File backupFile) async {
    final dir = await getApplicationDocumentsDirectory();
    final target = File('${dir.path}/$configFileName');
    await backupFile.copy(target.path);
    _config = jsonDecode(await target.readAsString()) as Map<String, dynamic>;
  }
}
