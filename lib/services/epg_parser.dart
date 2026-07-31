import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart'; // 用于 compute
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
        if (await hashFile.exists()) {
          final oldHash = localHash;
          final oldXml = File('${_cacheDir!.path}/epg_$oldHash.xml');
          if (await oldXml.exists()) {
            await oldXml.delete();
            await LogService.write('删除旧 EPG 文件: epg_$oldHash.xml');
          }
          await hashFile.delete();
        }

        final xmlResponse = await Dio().get(epgUrl);
        final xmlContent = xmlResponse.data as String;
        final newHash = _computeHash(xmlContent);

        final newXmlFile = File('${_cacheDir!.path}/epg_$newHash.xml');
        await newXmlFile.writeAsString(xmlContent);
        await hashFile.writeAsString(newHash);
        await LogService.write('EPG 更新完成，新哈希: $newHash');

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

  // 使用 compute 异步解析 XML
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

    final xmlContent = await xmlFile.readAsString();
    try {
      // 在后台 isolate 解析，避免阻塞 UI
      _programsCache = await compute(_parseEpgXmlIsolate, xmlContent);
      await LogService.write('EPG 缓存加载成功，频道数: ${_programsCache!.length}');
    } catch (e) {
      await LogService.write('EPG 缓存解析失败: $e');
      _programsCache = {};
    }
  }

  // 实际解析函数（静态，供顶层函数调用）
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

  static DateTime? _parseDateTime(String str) {
    try {
      String dateStr = str.substring(0, 14);
      int year = int.parse(dateStr.substring(0, 4));
      int month = int.parse(dateStr.substring(4, 6));
      int day = int.parse(dateStr.substring(6, 8));
      int hour = int.parse(dateStr.substring(8, 10));
      int minute = int.parse(dateStr.substring(10, 12));
      int second = int.parse(dateStr.substring(12, 14));
      return DateTime.utc(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  // ========== 对外接口 ==========

  static Future<bool> checkForUpdate() async {
    await _initCache();
    final url = await _getEpgUrl();
    if (url == null) return false;
    return await _checkHashUpdate(url);
  }

  static Future<List<EpgProgram>> getProgramsForChannel(String channelName) async {
    await _initCache();
    if (_programsCache == null) {
      await _loadCachedEpg();
    }
    if (_programsCache == null) return [];

    if (_programsCache!.containsKey(channelName)) {
      return _programsCache![channelName]!;
    }

    for (var key in _programsCache!.keys) {
      if (key.contains(channelName) || channelName.contains(key)) {
        return _programsCache![key]!;
      }
    }
    return [];
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

  static Future<void> preloadAll() async {
    await _loadCachedEpg();
  }
}
