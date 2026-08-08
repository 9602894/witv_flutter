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
Map<String, List<EpgProgram>> _parseEpgXmlIsolate(String xmlPath) {
  return EpgParser._parseEpgXml(xmlPath);
}

// ---- 在 isolate 中执行下载更新（只下载，不解析） ----
Future<bool> _downloadEpgIsolate(Map<String, String> params) async {
  final epgUrl = params['epgUrl']!;
  final cacheDirPath = params['cacheDirPath']!;
  final hashFileName = EpgParser.hashFileName;

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
    if (await hashFile.exists()) {
      final localHash = await hashFile.readAsString();
      if (localHash == remoteHash) return false; // 哈希未变化
    }

    // 2. 下载新 XML
    final tempFile = File(
        '$cacheDirPath/epg_temp_${DateTime.now().millisecondsSinceEpoch}.xml');
    await Dio().download(
      epgUrl,
      tempFile.path,
      options: Options(
        receiveTimeout: Duration(seconds: 30),
        sendTimeout: Duration(seconds: 10),
      ),
    );

    if (!await tempFile.exists()) return false;

    // 3. 验证内容
    final content = await tempFile.readAsString();
    if (content.trim().isEmpty || !content.trim().startsWith('<')) {
      await tempFile.delete();
      return false;
    }

    // 4. 计算哈希并保存
    final newHash = md5.convert(utf8.encode(content)).toString();

    // 5. 删除旧文件
    if (await hashFile.exists()) {
      final oldHash = await hashFile.readAsString();
      final oldXml = File('$cacheDirPath/epg_$oldHash.xml');
      if (await oldXml.exists()) await oldXml.delete();
    }

    // 6. 保存新文件
    final newXmlFile = File('$cacheDirPath/epg_$newHash.xml');
    await tempFile.copy(newXmlFile.path);
    await tempFile.delete();
    await hashFile.writeAsString(newHash);

    return true;
  } catch (e) {
    return false;
  }
}

class EpgParser {
  static const String epgCacheDirName = 'epgCache';
  static const String hashFileName = 'epg_hash.txt';
  static const String epgDataFileName = 'epg_data.json';

  static Directory? _cacheDir;
  static Map<String, List<EpgProgram>>? _programsCache;
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

  static Future<void> _loadEpgData() async {
    if (_epgDataLoaded) return;
    try {
      String content;
      final appDocDir = await getApplicationDocumentsDirectory();
      final localFile = File(p.join(appDocDir.path, epgDataFileName));

      final token = await ConfigService.getGitHubToken();
      if (token != null && token.isNotEmpty) {
        try {
          final url = '${_baseConfigUrl}epg_data.json';
          LogService.write('EpgParser: 加载 epg_data.json...');
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
          } else {
            throw Exception('HTTP ${response.statusCode}');
          }
        } catch (e) {
          LogService.write('EpgParser: 远程加载失败: $e');
          if (await localFile.exists()) {
            content = await localFile.readAsString();
          } else {
            content = await rootBundle.loadString('assets/$epgDataFileName');
          }
        }
      } else {
        if (await localFile.exists()) {
          content = await localFile.readAsString();
        } else {
          content = await rootBundle.loadString('assets/$epgDataFileName');
        }
      }

      final decoded = jsonDecode(content);
      List<dynamic> jsonList;
      if (decoded is List) {
        jsonList = decoded;
      } else if (decoded is Map<String, dynamic>) {
        jsonList = (decoded['epgs'] ?? decoded['data'] ?? decoded['channels'] ?? <dynamic>[]) as List<dynamic>;
      } else {
        jsonList = [];
      }

      _nameToEpgId = {};
      for (var item in jsonList) {
        if (item is! Map<String, dynamic>) continue;
        final epgid = item['epgid'] as String?;
        final nameStr = item['name'] as String?;
        if (epgid != null && nameStr != null) {
          final names = nameStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
          for (var n in names) {
            _nameToEpgId![n] = epgid;
          }
        }
      }
      LogService.write('EpgParser: 映射数 ${_nameToEpgId?.length}');
    } catch (e) {
      _nameToEpgId = {};
      LogService.write('EpgParser: 加载失败: $e');
    }
    _epgDataLoaded = true;
  }

  /// 检查并下载更新（只下载，不解析）
  static Future<bool> checkForUpdate() async {
    await _initCache();
    final url = await _getEpgUrl();
    if (url == null) {
      LogService.write('EPG URL 未配置');
      return false;
    }

    final start = DateTime.now();
    final result = await compute(
      _downloadEpgIsolate,
      {'epgUrl': url, 'cacheDirPath': _cacheDir!.path},
    );
    final elapsed = DateTime.now().difference(start).inMilliseconds;
    LogService.write('EPG 下载完成，耗时 ${elapsed}ms, 更新: $result');

    if (result) {
      // 下载成功，清除缓存，下次请求时重新加载
      _programsCache = null;
    }
    return result;
  }

  static Map<String, List<EpgProgram>> _parseEpgXml(String xmlPath) {
    try {
      final xmlContent = File(xmlPath).readAsStringSync();
      final document = XmlDocument.parse(xmlContent);
      final programs = <String, List<EpgProgram>>{};

      // 建立 channel id -> name 映射
      final idToName = <String, String>{};
      for (var channel in document.findAllElements('channel')) {
        final id = channel.getAttribute('id');
        if (id == null || id.isEmpty) continue;
        final displayNameNode = channel.findElements('display-name').firstOrNull;
        if (displayNameNode != null) {
          final name = displayNameNode.text.trim();
          if (name.isNotEmpty) idToName[id] = name;
        }
      }

      // 解析节目
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

  static Future<void> _loadCachedEpg() async {
    if (_programsCache != null) return;
    await _initCache();

    final hashFile = File('${_cacheDir!.path}/$hashFileName');
    if (!await hashFile.exists()) {
      _programsCache = {};
      return;
    }

    final hash = await hashFile.readAsString();
    final xmlFile = File('${_cacheDir!.path}/epg_$hash.xml');
    if (!await xmlFile.exists()) {
      _programsCache = {};
      return;
    }

    final start = DateTime.now();
    try {
      _programsCache = await compute(_parseEpgXmlIsolate, xmlFile.path);
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      LogService.write('EPG 加载完成，${_programsCache!.length} 个频道，耗时 ${elapsed}ms');
    } catch (e) {
      LogService.write('EPG 加载失败: $e');
      _programsCache = {};
    }
  }

  // ---- 对外接口 ----
  static Future<Map<String, String>> getNameToEpgId() async {
    await _loadEpgData();
    return Map.from(_nameToEpgId ?? {});
  }

  static Future<List<EpgProgram>> getProgramsForChannel(String channelName) async {
    await _loadEpgData();
    if (_programsCache == null) await _loadCachedEpg();
    if (_programsCache == null || _nameToEpgId == null) return [];

    final epgid = _nameToEpgId![channelName];
    if (epgid == null) return [];
    return _programsCache![epgid] ?? [];
  }

  static Future<Map<String, List<EpgProgram>>> getGroupPrograms(List<String> channelNames) async {
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

  static Future<List<String>> getAllChannelNames() async {
    await _loadCachedEpg();
    return _programsCache?.keys.toList() ?? [];
  }

  static Future<void> preloadAll() async {
    await _loadEpgData();
    await _loadCachedEpg();
  }

  static Future<void> clearCache() async {
    await _initCache();
    if (await _cacheDir!.exists()) {
      await _cacheDir!.delete(recursive: true);
      await _cacheDir!.create();
    }
    _programsCache = null;
    _nameToEpgId = null;
    _epgDataLoaded = false;
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
