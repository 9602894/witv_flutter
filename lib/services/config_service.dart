import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart' show rootBundle;

class ConfigService {
  static const String configFileName = 'configuration.json';
  static Map<String, dynamic>? _config;

  // 返回 Configuration 对象（直接返回内部 map）
  static Future<Map<String, dynamic>> getConfig() async {
    if (_config != null) return _config!;
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$configFileName');
    String jsonString;
    if (await file.exists()) {
      jsonString = await file.readAsString();
    } else {
      jsonString = await rootBundle.loadString('assets/$configFileName');
      await file.writeAsString(jsonString);
    }
    final fullMap = jsonDecode(jsonString) as Map<String, dynamic>;
    // 假设结构为 {"Configuration": {...}}
    _config = fullMap['Configuration'] as Map<String, dynamic>? ?? fullMap;
    return _config!;
  }

  static Future<void> saveConfig(Map<String, dynamic> config) async {
    // 保存时重新包装成 {"Configuration": config}
    final fullMap = {'Configuration': config};
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$configFileName');
    await file.writeAsString(jsonEncode(fullMap));
    _config = config;
  }

  static Future<void> resetToDefault() async {
    final jsonString = await rootBundle.loadString('assets/$configFileName');
    final fullMap = jsonDecode(jsonString) as Map<String, dynamic>;
    final config = fullMap['Configuration'] as Map<String, dynamic>? ?? fullMap;
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$configFileName');
    await file.writeAsString(jsonEncode({'Configuration': config}));
    _config = config;
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
    final jsonString = await target.readAsString();
    final fullMap = jsonDecode(jsonString) as Map<String, dynamic>;
    _config = fullMap['Configuration'] as Map<String, dynamic>? ?? fullMap;
  }
}
