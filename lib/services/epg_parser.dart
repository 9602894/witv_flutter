import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import '../models/epg_program.dart';
import 'log_service.dart';
import 'config_service.dart';

// ---- 顶层函数（供 compute 调用） ----
// 解析节目（接收 XML 文件路径）
Map<String, List<EpgProgram>> _parseEpgXmlIsolate(String xmlPath) {
  return EpgParser._parseEpgXml(xmlPath);
}

// 提取图标（接收 XML 文件路径）
Map<String, String> _extractIconsIsolate(String xmlPath) {
  return EpgParser._extractIconsFromChannels(xmlPath);
}

// ---- 新增：在 isolate 中执行下载更新（完全不影响主线程） ----
Future<bool> _checkHashUpdateIsolate(Map<String, String> params) async {
  final epgUrl = params['epgUrl']!;
  final cacheDirPath = params['cacheDirPath']!;
  final hashFileName = EpgParser.hashFileName;
  final iconCacheFileName = EpgParser.iconCacheFileName;

  try {
    // 1. 获取远程哈希
    final hashUrl = '$epgUrl.hash';
    final response = await Dio().get(
      hashUrl,
      options: Options(
        receiveTimeout: Duration(seconds: 10),
        sendTimeout: Duration(seconds: 5),
      ),
    );
    final remoteHash = response.data.toString().trim();
    if (remoteHash.isEmpty) return false;

    final hashFile = File('$cacheDirPath/$hashFileName');
    String localHash = '';
    if (await hashFile.exists()) {
      localHash = await hashFile.readAsString();
    }

    if (localHash == remoteHash) {
      // 哈希未变化，无需更新
      return false;
    }

    // 2. 下载新 XML（流式下载到临时文件）
    final tempFile = File(
        '$cacheDirPath/epg_temp_${DateTime.now().millisecondsSinceEpoch}.xml');
    await Dio().download(
      epgUrl,
      tempFile.path,
      options: Options(
        receiveTimeout: Duration(seconds: 60),
        sendTimeout: Duration(seconds: 10),
      ),
    );

    if (!await tempFile.exists()) return false;

    final xmlContent = await tempFile.readAsString();
    if (xmlContent.trim().isEmpty || !xmlContent.trim().startsWith('<')) {
      await tempFile.delete();
      return false;
    }

    // 3. 计算新哈希并保存
    final newHash = md5.convert(utf8.encode(xmlContent)).toString();

    // 4. 提取图标并缓存（在 isolate 中完成，不影响主线程）
    final icons = EpgParser._extractIconsFromChannels(xmlContent);
    if (icons.isNotEmpty) {
      final iconFile = File('$cacheDirPath/$iconCacheFileName');
      await iconFile.writeAsString(jsonEncode(icons));
    }

    // 5. 清理旧文件
    if (await hashFile.exists()) {
      final oldHash = await hashFile.readAsString();
      final oldXml = File('$cacheDirPath/epg_$oldHash.xml');
      if (await oldXml.exists()) await oldXml.delete();
      await hashFile.delete();
    }

    // 6. 保存新 XML 和哈希
    final newXmlFile = File('$cacheDirPath/epg_$newHash.xml');
    await tempFile.copy(newXmlFile.path);
    await tempFile.delete();
    await hashFile.writeAsString(newHash);

    return true;
  } catch (e) {
    // 下载失败，不影响已有缓存
    return false;
  }
}

class EpgParser {
  static const String epgCacheDirName = 'epgCache';
  static const String hashFileName = 'epg_hash.txt';
  static const String iconCacheFileName = 'epg_icons.json';
  static const String epgDataFileName = 'epg_data.json';

  static Directory? _cacheDir;
  static Map<String, List<EpgProgram>>? _programsCache;
  static Map<String, String>? _iconMapCache;
  static Map<String, String>? _nameToEpgId;
  static bool _epgDataLoaded = false;

  static const String _baseConfigUrl =
      'https://raw.githubusercontent.com/tytestelle/witv_flutter/main/assets/';

  static Future<void> _initCache() async {
    if (_cacheDir != null) return;
    final appDocDir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory('${appDocDir.path}/$epgCacheDirName');
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }
  }

  static Future<String?> _getEpgUrl() async {
    final config = await ConfigService.getConfig();
    final inner = config['Configuration'] as Map<String, dynamic>?;
    final epgUrlRaw = inner?['EPG_URLS'] as String?;
    if (epgUrlRaw == null || epgUrlRaw.isEmpty) return null;
    if (epgUrlRaw.contains(r'$')) {
      return epgUrlRaw.split(r'$')[0].trim();
    }
    return epgUrlRaw.trim();
  }

  static String _computeHash(String content) {
    return md5.convert(utf8.encode(content)).toString();
  }

  /// 加载 epg_data.json（优先远程，其次本地缓存，最后 assets）
  static Future<void> _loadEpgData() async {
    if (_epgDataLoaded) return;
    try {
      String content;
      final appDocDir = await getApplicationDocumentsDirectory();
      final localFile = File(p.join(appDocDir.path, epgDataFileName));

      // 1. 尝试从远程加载
      final token = await ConfigService.getGitHubToken();
      if (token != null && token.isNotEmpty) {
        try {
          final url = '${_baseConfigUrl}epg_data.json';
          LogService.write('EpgParser: 尝试从远程加载 epg_data.json...');
          final response = await Dio().get(
            url,
            options: Options(
              headers: {'Authorization': 'token $token'},
              receiveTimeout: const Duration(seconds: 10),
            ),
          );
          if (response.statusCode == 200) {
            content = response.data.toString();
            await localFile.writeAsString(content);
            LogService.write('EpgParser: 从远程加载 epg_data.json 成功');
          } else {
            throw Exception('HTTP ${response.statusCode}');
          }
        } catch (e) {
          LogService.write('EpgParser: 远程加载失败: $e，尝试本地缓存');
          if (await localFile.exists()) {
            content = await localFile.readAsString();
            LogService.write('EpgParser: 从本地缓存加载 epg_data.json');
          } else {
            content = await rootBundle.loadString('assets/$epgDataFileName');
            LogService.write('EpgParser: 从 assets 加载 epg_data.json');
            await localFile.writeAsString(content);
          }
        }
      } else {
        LogService.write('EpgParser: 未设置令牌，尝试本地缓存或 assets');
        if (await localFile.exists()) {
          content = await localFile.readAsString();
        } else {
          content = await rootBundle.loadString('assets/$epgDataFileName');
          await localFile.writeAsString(content);
        }
      }

      final decoded = jsonDecode(content);
      List<dynamic> jsonList;
      if (decoded is List) {
        jsonList = decoded;
      } else if (decoded is Map<String, dynamic>) {
        jsonList = (decoded['epgs'] ??
                decoded['data'] ??
                decoded['channels'] ??
                decoded['list'] ??
                <dynamic>[])
            as List<dynamic>;
      } else {
        jsonList = [];
      }

      _nameToEpgId = {};
      for (var item in jsonList) {
        if (item is! Map<String, dynamic>) continue;
        final epgid = item['epgid'] as String?;
        final nameStr = item['name'] as String?;
        if (epgid != null && nameStr != null) {
          final names = nameStr
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
          for (var n in names) {
            _nameToEpgId![n] = epgid;
          }
        }
      }
      LogService.write(
          'EpgParser: epg_data.json 加载成功，映射数 ${_nameToEpgId?.length}');
    } catch (e, stack) {
      _nameToEpgId = {};
      LogService.write('EpgParser: 加载 epg_data.json 失败: $e');
    }
    _epgDataLoaded = true;
  }

  /// 手动更新 epg_data.json
  static Future<bool> updateEpgData() async {
    try {
      final token = await ConfigService.getGitHubToken();
      if (token == null || token.isEmpty) {
        LogService.write('EpgParser: 未设置令牌，无法更新');
        return false;
      }
      final url = '${_baseConfigUrl}epg_data.json';
      LogService.write('EpgParser: 手动更新 epg_data.json...');
      final response = await Dio().get(
        url,
        options: Options(
          headers: {'Authorization': 'token $token'},
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      if (response.statusCode == 200) {
        final appDocDir = await getApplicationDocumentsDirectory();
        final localFile = File(p.join(appDocDir.path, epgDataFileName));
        await localFile.writeAsString(response.data.toString());
        // 重新加载映射
        _nameToEpgId = null;
        _epgDataLoaded = false;
        await _loadEpgData();
        LogService.write('EpgParser: 手动更新 epg_data.json 成功');
        return true;
      }
      return false;
    } catch (e) {
      LogService.write('EpgParser: 手动更新失败: $e');
      return false;
    }
  }

  /// 检查并更新 EPG（哈希对比+下载）—— 下载在 isolate 中执行，不影响播放
  static Future<bool> checkForUpdate() async {
    await _initCache();
    final url = await _getEpgUrl();
    if (url == null) {
      await LogService.write('EPG URL 未配置，跳过更新');
      return false;
    }
    return await _checkHashUpdate(url);
  }

  static Future<bool> _checkHashUpdate(String epgUrl) async {
    await _initCache();
    final cacheDirPath = _cacheDir!.path;

    // 在 isolate 中执行下载更新，完全不影响主线程
    final result = await compute(
      _checkHashUpdateIsolate,
      {'epgUrl': epgUrl, 'cacheDirPath': cacheDirPath},
    );

    if (result) {
      // 下载成功，清除旧缓存，下次加载时会重新读取
      _programsCache = null;
      _iconMapCache = null;
      await LogService.write('EPG 更新完成（在 isolate 中完成）');
    }
    return result;
  }

  // ---- 以下为解析相关方法（完全不变） ----
  static Map<String, String> _extractIconsFromChannels(String xmlContent) {
    try {
      final document = XmlDocument.parse(xmlContent);
      final icons = <String, String>{};
      for (var channel in document.findAllElements('channel')) {
        final id = channel.getAttribute('id');
        if (id == null || id.isEmpty) continue;
        final displayNameNode = channel.findElements('display-name').firstOrNull;
        if (displayNameNode == null) continue;
        final name = displayNameNode.text.trim();
        if (name.isEmpty) continue;
        final icon = channel.findElements('icon').firstOrNull?.getAttribute('src');
        if (icon != null && icon.isNotEmpty) {
          icons[name] = icon;
        }
      }
      return icons;
    } catch (e) {
      return {};
    }
  }

  static Map<String, List<EpgProgram>> _parseEpgXml(String xmlPath) {
    try {
      final xmlContent = File(xmlPath).readAsStringSync();
      final document = XmlDocument.parse(xmlContent);
      final programs = <String, List<EpgProgram>>{};

      final idToName = <String, String>{};
      for (var channel in document.findAllElements('channel')) {
        final id = channel.getAttribute('id');
        if (id == null || id.isEmpty) continue;
        final displayNameNode = channel.findElements('display-name').firstOrNull;
        if (displayNameNode != null) {
          final name = displayNameNode.text.trim();
          if (name.isNotEmpty) {
            idToName[id] = name;
          }
        }
      }

      for (var programme in document.findAllElements('programme')) {
        final channelId = programme.getAttribute('channel');
        if (channelId == null) continue;
        final channelName = idToName[channelId];
        if (channelName == null) continue;

        final startStr = programme.getAttribute('start');
        final stopStr = programme.getAttribute('stop');
        if (startStr == null || stopStr == null) continue;

        final start = _parseDateTime(startStr);
        final stop = _parseDateTime(stopStr);
        if (start == null || stop == null) continue;

        final title = programme.findElements('title').firstOrNull?.text ?? '';
        final desc = programme.findElements('desc').firstOrNull?.text ?? '';

        final epg = EpgProgram(
          title: title,
          start: start,
          end: stop,
          desc: desc.isNotEmpty ? desc : null,
        );

        programs.putIfAbsent(channelName, () => []);
        programs[channelName]!.add(epg);
      }

      for (var key in programs.keys) {
        programs[key]!.sort((a, b) => a.start.compareTo(b.start));
      }
      return programs;
    } catch (e) {
      return {};
    }
  }

  static DateTime? _parseDateTime(String str) {
    try {
      String dateStr = str.substring(0, 14);
      int year = int.parse(dateStr.substring(0, 4));
      int month = int.parse(dateStr.substring(4, 6));
      int day = int.parse(dateStr.substring(6, 8));
      int hour = int.parse(dateStr.substring(8, 10));
      int minute = int.parse(dateStr.substring(10, 12));
      int second = int.parse(dateStr.substring(12, 14));
      return DateTime(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  // ---- 缓存加载（解析仍使用 compute，但注意 _parseEpgXml 现在接收文件路径） ----
  static Future<void> _loadCachedEpg() async {
    if (_programsCache != null && _iconMapCache != null) return;
    await _initCache();

    final iconFile = File('${_cacheDir!.path}/$iconCacheFileName');
    if (await iconFile.exists()) {
      try {
        final content = await iconFile.readAsString();
        final map = jsonDecode(content) as Map<String, dynamic>;
        _iconMapCache = map.map((k, v) => MapEntry(k, v.toString()));
      } catch (e) {
        _iconMapCache = {};
        LogService.write('EPG 图标缓存加载失败: $e');
      }
    } else {
      _iconMapCache = {};
    }

    final hashFile = File('${_cacheDir!.path}/$hashFileName');
    if (!await hashFile.exists()) {
      _programsCache = {};
      await LogService.write('EPG 缓存文件不存在，初始化空缓存');
      return;
    }

    final hash = await hashFile.readAsString();
    final xmlFile = File('${_cacheDir!.path}/epg_$hash.xml');
    if (!await xmlFile.exists()) {
      _programsCache = {};
      await LogService.write('EPG XML 缓存文件缺失，初始化空缓存');
      return;
    }

    try {
      // 解析使用 compute，传入 XML 文件路径
      _programsCache = await compute(_parseEpgXmlIsolate, xmlFile.path);

      // 如果图标缓存为空，尝试从 XML 提取（通常下载时已提取，这里是兜底）
      if (_iconMapCache == null || _iconMapCache!.isEmpty) {
        final icons = await compute(_extractIconsIsolate, xmlFile.path);
        if (icons.isNotEmpty) {
          _iconMapCache = icons;
          await _saveIconCache(icons);
        }
      }
      await LogService.write(
          'EPG 缓存加载成功，频道数: ${_programsCache!.length}');
    } catch (e) {
      await LogService.write('EPG 缓存解析失败: $e，将删除损坏文件');
      await xmlFile.delete();
      _programsCache = {};
    }
  }

  static Future<void> _saveIconCache(Map<String, String> icons) async {
    try {
      final iconFile = File('${_cacheDir!.path}/$iconCacheFileName');
      await iconFile.writeAsString(jsonEncode(icons));
    } catch (e) {
      await LogService.write('保存图标缓存失败: $e');
    }
  }

  // ---- 对外接口（完全不变） ----
  static Future<Map<String, String>> getNameToEpgId() async {
    await _loadEpgData();
    return Map.from(_nameToEpgId ?? {});
  }

  static Future<String?> getChannelIconUrl(String channelName) async {
    if (_iconMapCache == null) await _loadCachedEpg();
    return _iconMapCache?[channelName];
  }

  static Future<List<EpgProgram>> getProgramsForChannel(
      String channelName) async {
    await _loadEpgData();
    if (_programsCache == null) await _loadCachedEpg();
    if (_programsCache == null || _nameToEpgId == null) return [];

    final epgid = _nameToEpgId![channelName];
    if (epgid == null) return [];
    final programs = _programsCache![epgid];
    return programs ?? [];
  }

  static Future<Map<String, List<EpgProgram>>> getGroupPrograms(
      List<String> channelNames) async {
    await _loadEpgData();
    if (_programsCache == null) await _loadCachedEpg();
    if (_programsCache == null || _nameToEpgId == null) return {};

    final result = <String, List<EpgProgram>>{};
    for (var name in channelNames) {
      final epgid = _nameToEpgId![name];
      if (epgid != null && _programsCache!.containsKey(epgid)) {
        result[name] = _programsCache![epgid]!;
      }
    }
    return result;
  }

  static Future<Map<String, List<EpgProgram>>> getAllPrograms() async {
    if (_programsCache == null) await _loadCachedEpg();
    return Map.from(_programsCache ?? {});
  }

  static Future<Map<String, String>> getAllChannelIcons() async {
    if (_iconMapCache == null) await _loadCachedEpg();
    return Map.from(_iconMapCache ?? {});
  }

  static Future<void> preloadAll() async {
    await _loadEpgData();
    await _loadCachedEpg();
  }

  static Future<List<String>> getAllChannelNames() async {
    await _loadCachedEpg();
    return _programsCache?.keys.toList() ?? [];
  }

  static Future<void> clearCache() async {
    await _initCache();
    if (await _cacheDir!.exists()) {
      await _cacheDir!.delete(recursive: true);
      await _cacheDir!.create();
    }
    _programsCache = null;
    _iconMapCache = null;
    _nameToEpgId = null;
    _epgDataLoaded = false;
    await LogService.write('EPG 缓存已清空');
  }

  static Future<String?> getCachedHash() async {
    await _initCache();
    final hashFile = File('${_cacheDir!.path}/$hashFileName');
    if (await hashFile.exists()) {
      return await hashFile.readAsString();
    }
    return null;
  }
}
