import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';
import '../models/epg_program.dart';
import 'log_service.dart';
import 'config_service.dart'; // 假设有获取 EPG URL 的方法

class EpgParser {
  static const String epgCacheDirName = 'epgCache';
  static const String hashFileName = 'epg_hash.txt';

  static Directory? _cacheDir;
  static String? _cachedXmlPath;
  static String? _cachedHash;
  static Map<String, List<EpgProgram>>? _programsCache; // 频道名 -> 节目列表
  static final Map<String, List<EpgProgram>> _channelCache = {};

  // 初始化缓存目录
  static Future<void> _initCache() async {
    if (_cacheDir != null) return;
    final appDocDir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory('${appDocDir.path}/$epgCacheDirName');
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }
  }

  // 获取当前 EPG 的 URL（从配置中读取）
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

  // 计算文件的 MD5 哈希
  static String _computeHash(String content) {
    return md5.convert(utf8.encode(content)).toString();
  }

  // 下载 EPG 并保存，返回哈希
  static Future<String?> _downloadEpg(String url) async {
    try {
      final response = await Dio().get(url);
      final content = response.data as String;
      final hash = _computeHash(content);
      // 保存 XML 文件
      final xmlFile = File('${_cacheDir!.path}/epg_$hash.xml');
      await xmlFile.writeAsString(content);
      // 保存哈希值
      final hashFile = File('${_cacheDir!.path}/$hashFileName');
      await hashFile.writeAsString(hash);
      await LogService.write('EPG 下载成功，哈希: $hash');
      return hash;
    } catch (e) {
      await LogService.write('EPG 下载失败: $e');
      return null;
    }
  }

  // 加载本地缓存的 EPG 数据（全量解析，但仅解析一次）
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
      final map = _parseEpgXml(xmlContent);
      _programsCache = map;
      await LogService.write('EPG 缓存加载成功，频道数: ${map.length}');
    } catch (e) {
      await LogService.write('EPG 缓存解析失败: $e');
      _programsCache = {};
    }
  }

  // 解析 XML 内容为 Map<String, List<EpgProgram>>
  static Map<String, List<EpgProgram>> _parseEpgXml(String xmlContent) {
    final document = XmlDocument.parse(xmlContent);
    final programs = <String, List<EpgProgram>>{};
    final channelElements = document.findAllElements('channel');
    // 先建立 channel 名 -> id 映射（如果有）
    final channelMap = <String, String>{};
    for (var channel in channelElements) {
      final id = channel.getAttribute('id');
      final displayName = channel.findElements('display-name').firstOrNull?.text ?? id;
      if (id != null) {
        channelMap[displayName] = id;
      }
    }
    // 遍历 programme 元素
    for (var programme in document.findAllElements('programme')) {
      final channelId = programme.getAttribute('channel');
      if (channelId == null) continue;
      // 查找对应的显示名称（优先反向匹配）
      String? channelName;
      for (var entry in channelMap.entries) {
        if (entry.value == channelId) {
          channelName = entry.key;
          break;
        }
      }
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
    // 按时间排序每个频道的节目
    for (var key in programs.keys) {
      programs[key]!.sort((a, b) => a.start.compareTo(b.start));
    }
    return programs;
  }

  static DateTime? _parseDateTime(String str) {
    try {
      // 格式：20260731113000 +0800 或 20260731113000
      String trimmed = str.trim();
      String dateStr;
      String offset = '';
      if (trimmed.length >= 14) {
        dateStr = trimmed.substring(0, 14);
        if (trimmed.length > 14) {
          offset = trimmed.substring(14).trim();
        }
      } else {
        return null;
      }
      int year = int.parse(dateStr.substring(0, 4));
      int month = int.parse(dateStr.substring(4, 6));
      int day = int.parse(dateStr.substring(6, 8));
      int hour = int.parse(dateStr.substring(8, 10));
      int minute = int.parse(dateStr.substring(10, 12));
      int second = int.parse(dateStr.substring(12, 14));
      // 如果有偏移，简单处理，我们只取 UTC
      return DateTime.utc(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  // ---------- 对外接口 ----------
  // 检查更新：对比远程哈希，如果有变化则下载新文件并删除旧文件
  static Future<bool> checkForUpdate() async {
    await _initCache();
    final url = await _getEpgUrl();
    if (url == null) return false;
    try {
      // 只获取头部，不下载全文（但部分服务器不支持HEAD，则下载）
      final response = await Dio().head(url);
      final remoteHash = response.headers.value('etag') ?? 
                         response.headers.value('x-hash') ?? 
                         response.headers.value('content-md5');
      if (remoteHash != null && remoteHash.isNotEmpty) {
        // 比较本地哈希
        final hashFile = File('${_cacheDir!.path}/$hashFileName');
        String localHash = '';
        if (await hashFile.exists()) {
          localHash = await hashFile.readAsString();
        }
        if (localHash != remoteHash) {
          // 有更新，删除旧文件
          if (await hashFile.exists()) {
            final oldHash = localHash;
            final oldXml = File('${_cacheDir!.path}/epg_$oldHash.xml');
            if (await oldXml.exists()) await oldXml.delete();
            await hashFile.delete();
          }
          // 下载新文件
          final newHash = await _downloadEpg(url);
          if (newHash != null) {
            _programsCache = null; // 清空缓存
            return true;
          }
        }
      } else {
        // 无法获取ETag，则下载整个文件并计算哈希
        final tempFile = File('${_cacheDir!.path}/temp_epg.xml');
        await Dio().download(url, tempFile.path);
        final content = await tempFile.readAsString();
        final newHash = _computeHash(content);
        final hashFile = File('${_cacheDir!.path}/$hashFileName');
        String localHash = '';
        if (await hashFile.exists()) {
          localHash = await hashFile.readAsString();
        }
        if (localHash != newHash) {
          // 删除旧文件
          if (await hashFile.exists()) {
            final oldHash = localHash;
            final oldXml = File('${_cacheDir!.path}/epg_$oldHash.xml');
            if (await oldXml.exists()) await oldXml.delete();
            await hashFile.delete();
          }
          // 保存新文件
          final newXmlFile = File('${_cacheDir!.path}/epg_$newHash.xml');
          await tempFile.copy(newXmlFile.path);
          await hashFile.writeAsString(newHash);
          await tempFile.delete();
          _programsCache = null;
          return true;
        } else {
          await tempFile.delete();
        }
      }
    } catch (e) {
      await LogService.write('EPG 更新检查失败: $e');
    }
    return false;
  }

  // 获取某个频道的节目列表（按需加载）
  static Future<List<EpgProgram>> getProgramsForChannel(String channelName) async {
    await _initCache();
    if (_programsCache == null) {
      await _loadCachedEpg();
    }
    // 如果缓存中没有该频道，尝试从缓存中查找（可能名称不匹配，需要模糊匹配）
    if (_programsCache != null && _programsCache!.containsKey(channelName)) {
      return _programsCache![channelName]!;
    }
    // 尝试模糊匹配
    if (_programsCache != null) {
      for (var key in _programsCache!.keys) {
        if (key.contains(channelName) || channelName.contains(key)) {
          return _programsCache![key]!;
        }
      }
    }
    return [];
  }

  // 预加载所有 EPG（慎用，仅用于后台预加载）
  static Future<void> preloadAll() async {
    await _loadCachedEpg();
  }

  // 清理缓存（删除所有文件）
  static Future<void> clearCache() async {
    await _initCache();
    if (await _cacheDir!.exists()) {
      await _cacheDir!.delete(recursive: true);
      await _cacheDir!.create();
    }
    _programsCache = null;
    await LogService.write('EPG 缓存已清空');
  }

  // 获取当前缓存的哈希值
  static Future<String?> getCachedHash() async {
    await _initCache();
    final hashFile = File('${_cacheDir!.path}/$hashFileName');
    if (await hashFile.exists()) {
      return await hashFile.readAsString();
    }
    return null;
  }
}
