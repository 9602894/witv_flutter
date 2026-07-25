import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart' show rootBundle;

class ConfigService {
  static const String configFileName = 'configuration.json';
  static Map<String, dynamic>? _config;

  static Future<Map<String, dynamic>> getConfig() async {
    if (_config != null) return _config!;
    // 优先从外部存储加载
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$configFileName');
    String jsonString;
    if (await file.exists()) {
      jsonString = await file.readAsString();
    } else {
      // 从 assets 复制到外部
      jsonString = await rootBundle.loadString('assets/$configFileName');
      await file.writeAsString(jsonString);
    }
    _config = jsonDecode(jsonString) as Map<String, dynamic>;
    return _config!;
  }

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

  // 备份：复制 configuration.json 到备份目录
  static Future<void> backup() async {
    final dir = await getApplicationDocumentsDirectory();
    final src = File('${dir.path}/$configFileName');
    if (!await src.exists()) return;
    final backupDir = Directory('${dir.path}/backup');
    if (!await backupDir.exists()) await backupDir.create();
    final backupFile = File('${backupDir.path}/${DateTime.now().millisecondsSinceEpoch}_$configFileName');
    await src.copy(backupFile.path);
  }

  // 恢复：从备份列表中选择一个覆盖
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
