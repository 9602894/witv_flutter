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
        // 尝试解析，若失败则从 assets 重新复制
        try {
          final raw = jsonDecode(jsonString) as Map<String, dynamic>;
          if (raw.containsKey('Configuration')) {
            _config = raw;
            return _config!;
          }
        } catch (e) {
          await LogService.write('外部配置文件解析失败: $e，从 assets 重新复制');
          // 删除损坏文件
          await file.delete();
        }
      }
      // 从 assets 复制
      jsonString = await rootBundle.loadString('assets/$configFileName');
      await file.writeAsString(jsonString);
      final raw = jsonDecode(jsonString) as Map<String, dynamic>;
      _config = raw;
    } catch (e) {
      await LogService.write('加载配置失败: $e，使用默认空配置');
      _config = {'Configuration': {}};
    }
    return _config!;
  }

  // ... 其他方法保持不变
}
