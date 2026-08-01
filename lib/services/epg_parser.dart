import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';
import '../models/epg_program.dart';
import 'log_service.dart';
import 'config_service.dart';

// 顶层函数，供 compute 调用
Map<String, List<EpgProgram>> _parseEpgXmlIsolate(String xmlContent) {
  return EpgParser._parseEpgXml(xmlContent);
}

// 顶层函数，按频道列表过滤
Map<String, List<EpgProgram>> _filterEpgIsolate(
    Map<String, List<EpgProgram>> fullMap, List<String> channelNames) {
  final result = <String, List<EpgProgram>>{};
  for (var name in channelNames) {
    if (fullMap.containsKey(name)) {
      result[name] = fullMap[name]!;
    } else {
      for (var key in fullMap.keys) {
        if (key.contains(name) || name.contains(key)) {
          result[name] = fullMap[key]!;
          break;
        }
      }
    }
  }
  return result;
}

class EpgParser {
  static const String epgCacheDirName = 'epgCache';
  static const String hashFileName = 'epg_hash.txt';

  static Directory? _cacheDir;
  static Map<String, List<EpgProgram>>? _programsCache;

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

  /// 检查远程哈希，若有更新则下载新文件并缓存
  static Future<bool> _checkHashUpdate(String epgUrl) async {
    try {
      final hashUrl = '$epgUrl.hash';
      final response = await Dio().get(hashUrl);
      final remoteHash = response.data.toString().trim();
      if (remoteHash.isEmpty) return false;

      final hashFile = File('${_cacheDir!.path}/$hashFileName');
      String localHash = '';
      if (await hashFile.exists()) {
        localHash = await hashFile.readAsString();
      }

      if (localHash != remoteHash) {
        // 删除旧文件
        if (await hashFile.exists()) {
          final oldHash = localHash;
          final oldXml = File('${_cacheDir!.path}/epg_$oldHash.xml');
          if (await oldXml.exists()) {
            await oldXml.delete();
          }
          await hashFile.delete();
        }

        // 下载新 XML
        final xmlResponse = await Dio().get(epgUrl);
        final xmlContent = xmlResponse.data as String;
        final newHash = _computeHash(xmlContent);

        final newXmlFile = File('${_cacheDir!.path}/epg_$newHash.xml');
        await newXmlFile.writeAsString(xmlContent);
        await hashFile.writeAsString(newHash);
        await LogService.write('EPG 更新完成，新哈希: $newHash');

        // 清空内存缓存以便重新加载
        _programsCache = null;
        return true;
      }
      await LogService.write('EPG 哈希未变化，无需更新');
      return false;
    } catch (e) {
      await LogService.write('EPG 哈希检查失败: $e');
      return false;
    }
  }

  /// 从本地缓存加载 EPG 数据到内存（如果已存在）
  static Future<void> _loadCachedEpg() async {
    if (_programsCache != null) return;
    await _initCache();

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
      final xmlContent = await xmlFile.readAsString();
      // 简单校验是否为有效 XML
      if (xmlContent.trim().isEmpty || !xmlContent.trim().startsWith('<')) {
        await xmlFile.delete(); // 删除损坏文件
        _programsCache = {};
        await LogService.write('EPG XML 内容无效，已删除并重置缓存');
        return;
      }
      _programsCache = await compute(_parseEpgXmlIsolate, xmlContent);
      await LogService.write('EPG 缓存加载成功，频道数: ${_programsCache!.length}');
    } catch (e) {
      await LogService.write('EPG 缓存解析失败: $e，将删除损坏文件');
      await xmlFile.delete();
      _programsCache = {};
    }
  }

  static Map<String, List<EpgProgram>> _parseEpgXml(String xmlContent) {
    final document = XmlDocument.parse(xmlContent);
    final programs = <String, List<EpgProgram>>{};

    final channelMap = <String, String>{};
    for (var channel in document.findAllElements('channel')) {
      final id = channel.getAttribute('id');
      final displayName = channel.findElements('display-name').firstOrNull?.text ?? id;
      if (id != null && displayName != null) {
        channelMap[id] = displayName;
      }
    }

    for (var programme in document.findAllElements('programme')) {
      final channelId = programme.getAttribute('channel');
      if (channelId == null) continue;

      final channelName = channelMap[channelId];
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
  }

  /// 解析 XMLTV 时间字符串（格式：YYYYMMDDHHMMSS + 时区）
  /// 直接返回本地时间（北京时间），不做任何时区转换
  static DateTime? _parseDateTime(String str) {
    try {
      String dateStr = str.substring(0, 14);
      int year = int.parse(dateStr.substring(0, 4));
      int month = int.parse(dateStr.substring(4, 6));
      int day = int.parse(dateStr.substring(6, 8));
      int hour = int.parse(dateStr.substring(8, 10));
      int minute = int.parse(dateStr.substring(10, 12));
      int second = int.parse(dateStr.substring(12, 14));
      // 直接使用本地时间构造
      return DateTime(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  // ========== 对外接口 ==========

  /// 检查更新（仅在定时器或手动触发时调用）
  static Future<bool> checkForUpdate() async {
    await _initCache();
    final url = await _getEpgUrl();
    if (url == null) {
      await LogService.write('EPG URL 未配置，跳过更新');
      return false;
    }
    return await _checkHashUpdate(url);
  }

  /// 获取某个频道的 EPG（直接从内存缓存返回）
  static Future<List<EpgProgram>> getProgramsForChannel(String channelName) async {
    await _initCache();
    if (_programsCache == null) {
      await _loadCachedEpg();
    }
    if (_programsCache == null) return [];

    if (_programsCache!.containsKey(channelName)) {
      return _programsCache![channelName]!;
    }

    // 尝试模糊匹配
    for (var key in _programsCache!.keys) {
      if (key.contains(channelName) || channelName.contains(key)) {
        return _programsCache![key]!;
      }
    }
    return [];
  }

  /// 获取当前分组频道的 EPG（过滤）
  static Future<Map<String, List<EpgProgram>>> getGroupPrograms(
      List<String> channelNames) async {
    await _initCache();
    if (_programsCache == null) {
      await _loadCachedEpg();
    }
    if (_programsCache == null) return {};
    return _filterEpgIsolate(_programsCache!, channelNames);
  }

  /// 获取全量 EPG（仅从内存返回，不触发下载）
  static Future<Map<String, List<EpgProgram>>> getAllPrograms() async {
    await _initCache();
    if (_programsCache == null) {
      await _loadCachedEpg();
    }
    if (_programsCache == null) return {};
    return Map.from(_programsCache!);
  }

  /// 预加载缓存（开机时调用，确保内存中有数据）
  static Future<void> preloadAll() async {
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
