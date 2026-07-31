import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';
import '../models/epg_program.dart';
import 'log_service.dart';
import 'config_service.dart';

class EpgParser {
  static const String epgCacheDirName = 'epgCache';
  static const String hashFileName = 'epg_hash.txt';

  static Directory? _cacheDir;
  static Map<String, List<EpgProgram>>? _programsCache;

  // 初始化缓存目录
  static Future<void> _initCache() async {
    if (_cacheDir != null) return;
    final appDocDir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory('${appDocDir.path}/$epgCacheDirName');
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }
  }

  // 获取 EPG URL
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

  // 计算文件内容的 MD5
  static String _computeHash(String content) {
    return md5.convert(utf8.encode(content)).toString();
  }

  // 下载哈希文件并比对
  static Future<bool> _checkHashUpdate(String epgUrl) async {
    try {
      final hashUrl = '$epgUrl.hash';
      final response = await Dio().get(hashUrl);
      final remoteHash = response.data.toString().trim();
      
      if (remoteHash.isEmpty) return false;

      // 读取本地哈希
      final hashFile = File('${_cacheDir!.path}/$hashFileName');
      String localHash = '';
      if (await hashFile.exists()) {
        localHash = await hashFile.readAsString();
      }

      // 如果哈希不同，需要更新
      if (localHash != remoteHash) {
        // 删除旧文件
        if (await hashFile.exists()) {
          final oldHash = localHash;
          final oldXml = File('${_cacheDir!.path}/epg_$oldHash.xml');
          if (await oldXml.exists()) {
            await oldXml.delete();
            await LogService.write('删除旧 EPG 文件: epg_$oldHash.xml');
          }
          await hashFile.delete();
        }

        // 下载新 XML
        final xmlResponse = await Dio().get(epgUrl);
        final xmlContent = xmlResponse.data as String;
        final newHash = _computeHash(xmlContent);
        
        // 保存新文件
        final newXmlFile = File('${_cacheDir!.path}/epg_$newHash.xml');
        await newXmlFile.writeAsString(xmlContent);
        await hashFile.writeAsString(newHash);
        await LogService.write('EPG 更新完成，新哈希: $newHash');
        
        _programsCache = null; // 清空内存缓存
        return true;
      }
      
      await LogService.write('EPG 哈希未变化，无需更新');
      return false;
    } catch (e) {
      await LogService.write('EPG 哈希检查失败: $e');
      return false;
    }
  }

  // 加载本地缓存的 EPG 数据
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
      _programsCache = _parseEpgXml(xmlContent);
      await LogService.write('EPG 缓存加载成功，频道数: ${_programsCache!.length}');
    } catch (e) {
      await LogService.write('EPG 缓存解析失败: $e');
      _programsCache = {};
    }
  }

  // 解析 XML
  static Map<String, List<EpgProgram>> _parseEpgXml(String xmlContent) {
    final document = XmlDocument.parse(xmlContent);
    final programs = <String, List<EpgProgram>>{};
    
    // 建立频道 ID -> 名称映射
    final channelMap = <String, String>{};
    for (var channel in document.findAllElements('channel')) {
      final id = channel.getAttribute('id');
      final displayName = channel.findElements('display-name').firstOrNull?.text ?? id;
      if (id != null && displayName != null) {
        channelMap[id] = displayName;
      }
    }

    // 解析节目
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

    // 按时间排序
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

  // 检查 EPG 更新（通过 .hash 文件）
  static Future<bool> checkForUpdate() async {
    await _initCache();
    final url = await _getEpgUrl();
    if (url == null) return false;
    return await _checkHashUpdate(url);
  }

  // 获取某个频道的节目列表（按需加载）
  static Future<List<EpgProgram>> getProgramsForChannel(String channelName) async {
    await _initCache();
    if (_programsCache == null) {
      await _loadCachedEpg();
    }
    if (_programsCache == null) return [];

    // 精确匹配
    if (_programsCache!.containsKey(channelName)) {
      return _programsCache![channelName]!;
    }

    // 模糊匹配（处理别名）
    for (var key in _programsCache!.keys) {
      if (key.contains(channelName) || channelName.contains(key)) {
        return _programsCache![key]!;
      }
    }
    return [];
  }

  // 获取所有频道名称列表（用于调试）
  static Future<List<String>> getAllChannelNames() async {
    await _loadCachedEpg();
    return _programsCache?.keys.toList() ?? [];
  }

  // 清空缓存
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

  // 预加载所有 EPG（后台可用）
  static Future<void> preloadAll() async {
    await _loadCachedEpg();
  }
}
