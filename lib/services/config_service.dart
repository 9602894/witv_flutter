import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'log_service.dart';

class ConfigService {
  static const String _configFileName = 'configuration.json';
  static const String _configCacheName = 'config_cache.json';
  static const String _tokenKey = 'GITHUB_TOKEN';

  static Map<String, dynamic>? _cachedConfig;
  static String? _githubToken;

  // 配置和 EPG 数据仓库（witv_flutter）
  static const String _baseConfigUrl =
      'https://raw.githubusercontent.com/tytestelle/witv_flutter/main/assets/';

  /// 获取 GitHub 令牌
  static Future<String?> getGitHubToken() async {
    if (_githubToken != null) return _githubToken;
    try {
      final config = await getConfig();
      final inner = config['Configuration'] as Map<String, dynamic>?;
      _githubToken = inner?[_tokenKey] as String?;
      return _githubToken;
    } catch (e) {
      return null;
    }
  }

  /// 保存 GitHub 令牌
  static Future<void> saveGitHubToken(String token) async {
    final config = await getConfig();
    config['Configuration'] ??= {};
    config['Configuration'][_tokenKey] = token;
    _githubToken = token;
    await _saveConfigToCache(config);
  }

  /// 获取完整配置（优先从缓存加载，若无则从 assets 加载）
  static Future<Map<String, dynamic>> getConfig() async {
    if (_cachedConfig != null) return _cachedConfig!;
    try {
      // 1. 尝试从本地缓存加载
      final cacheFile = await _getCacheFile();
      if (await cacheFile.exists()) {
        final content = await cacheFile.readAsString();
        _cachedConfig = jsonDecode(content) as Map<String, dynamic>;
        LogService.write('ConfigService: 从本地缓存加载配置');
        return _cachedConfig!;
      }

      // 2. 从 assets 加载（兜底）
      final content = await rootBundle.loadString('assets/$_configFileName');
      _cachedConfig = jsonDecode(content) as Map<String, dynamic>;
      await _saveConfigToCache(_cachedConfig!);
      LogService.write('ConfigService: 从 assets 加载配置');
      return _cachedConfig!;
    } catch (e) {
      LogService.write('ConfigService: 加载配置失败: $e');
      return {'Configuration': {}};
    }
  }

  /// 保存配置（公开方法，供设置 EPG URL 等使用）
  static Future<void> saveConfig(Map<String, dynamic> config) async {
    _cachedConfig = config;
    await _saveConfigToCache(config);
  }

  /// 从远程仓库更新配置（witv_flutter）
  static Future<bool> updateConfigFromRemote() async {
    try {
      final token = await getGitHubToken();
      if (token == null || token.isEmpty) {
        LogService.write('ConfigService: 未设置 GitHub 令牌，无法更新配置');
        return false;
      }

      final url = '${_baseConfigUrl}configuration.json';
      LogService.write('ConfigService: 从远程加载配置...');
      final response = await Dio().get(
        url,
        options: Options(
          headers: {'Authorization': 'token $token'},
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      if (response.statusCode == 200) {
        final config = jsonDecode(response.data.toString()) as Map<String, dynamic>;
        _cachedConfig = config;
        await _saveConfigToCache(config);
        LogService.write('ConfigService: 远程配置更新成功');
        return true;
      } else {
        LogService.write('ConfigService: 远程配置加载失败 (HTTP ${response.statusCode})');
        return false;
      }
    } catch (e) {
      LogService.write('ConfigService: 远程配置更新异常: $e');
      return false;
    }
  }

  static Future<void> _saveConfigToCache(Map<String, dynamic> config) async {
    try {
      final cacheFile = await _getCacheFile();
      await cacheFile.writeAsString(jsonEncode(config));
    } catch (e) {
      LogService.write('ConfigService: 保存缓存失败: $e');
    }
  }

  static Future<File> _getCacheFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _configCacheName));
  }

  static Future<void> clearCache() async {
    try {
      final cacheFile = await _getCacheFile();
      if (await cacheFile.exists()) await cacheFile.delete();
      _cachedConfig = null;
    } catch (e) {}
  }
}
