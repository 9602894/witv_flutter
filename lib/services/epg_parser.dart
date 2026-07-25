import 'package:dio/dio.dart';
import 'package:xml/xml.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import '../models/epg_program.dart';
import 'log_service.dart';

class EpgParser {
  static Map<String, String>? _aliasMap; // key: channel name, value: epgid
  static Map<String, List<EpgProgram>>? _allPrograms;
  static Map<String, String>? _channelIdMap; // key: display-name, value: channel-id

  /// 加载别名映射（epg_data.json）
  static Future<Map<String, String>> loadAliasMap() async {
    if (_aliasMap != null) return _aliasMap!;
    try {
      final jsonString = await rootBundle.loadString('assets/epg_data.json');
      final json = jsonDecode(jsonString);
      final map = <String, String>{};
      for (var item in json['epgs']) {
        final epgid = item['epgid'];
        final names = (item['name'] as String).split(',');
        for (var name in names) {
          map[name.trim()] = epgid;
        }
      }
      _aliasMap = map;
      await LogService.write('别名映射加载完成，条目数: ${map.length}');
      return map;
    } catch (e, stack) {
      await LogService.writeCrashLog(e, stack);
      rethrow;
    }
  }

  /// 加载所有 EPG 数据（支持缓存）
  static Future<Map<String, List<EpgProgram>>> loadAllEpg(String url) async {
    if (_allPrograms != null) return _allPrograms!;
    await LogService.write('开始加载EPG: $url');

    try {
      // 确保别名映射已加载
      await loadAliasMap();

      final dir = await getApplicationDocumentsDirectory();
      final cacheFile = File('${dir.path}/epg_cache.xml');
      final hashFile = File('${dir.path}/epg_hash.txt');

      bool needDownload = true;
      // 尝试使用哈希缓存
      try {
        final hashUrl = '$url.hash';
        final hashResponse = await Dio().get(hashUrl);
        final remoteHash = hashResponse.data as String;
        if (await hashFile.exists()) {
          final localHash = await hashFile.readAsString();
          if (localHash.trim() == remoteHash.trim() && await cacheFile.exists()) {
            needDownload = false;
            await LogService.write('使用缓存的EPG文件（哈希匹配）');
          }
        }
        if (needDownload) {
          final response = await Dio().get(url);
          await cacheFile.writeAsString(response.data as String);
          await hashFile.writeAsString(remoteHash);
          await LogService.write('EPG下载完成，已缓存');
        }
      } catch (e) {
        // 无哈希或哈希失败，直接下载
        await LogService.write('获取哈希失败，直接下载: $e');
        final response = await Dio().get(url);
        await cacheFile.writeAsString(response.data as String);
        await LogService.write('EPG下载完成（无哈希）');
      }

      // 解析 XML
      final xmlString = await cacheFile.readAsString();
      final document = XmlDocument.parse(xmlString);
      final allPrograms = <String, List<EpgProgram>>{};
      final displayNameToChannelId = <String, String>{};

      // 第一步：构建 display-name -> channel-id 映射
      for (var channel in document.findAllElements('channel')) {
        final id = channel.getAttribute('id')!;
        final displayNames = channel.findAllElements('display-name').map((e) => e.text.trim()).toList();
        for (var name in displayNames) {
          displayNameToChannelId[name] = id;
        }
      }
      _channelIdMap = displayNameToChannelId;
      await LogService.write('EPG中频道数: ${displayNameToChannelId.length}');

      // 第二步：解析 programme
      int programCount = 0;
      for (var prog in document.findAllElements('programme')) {
        final channelId = prog.getAttribute('channel')!;
        // 去除时区偏移（如 +0800）
        String startStr = prog.getAttribute('start')!.replaceAll(RegExp(r'[+\-]\d+$'), '');
        String stopStr = prog.getAttribute('stop')!.replaceAll(RegExp(r'[+\-]\d+$'), '');
        try {
          final start = DateTime.parse(startStr);
          final stop = DateTime.parse(stopStr);
          final title = prog.findAllElements('title').firstOrNull?.text.trim() ?? '';
          final desc = prog.findAllElements('desc').firstOrNull?.text.trim() ?? '';
          allPrograms.putIfAbsent(channelId, () => []);
          allPrograms[channelId]!.add(EpgProgram(start: start, end: stop, title: title, desc: desc));
          programCount++;
        } catch (e) {
          await LogService.write('解析节目失败: $e');
        }
      }
      await LogService.write('EPG节目总条目数: $programCount');

      // 第三步：利用别名映射将直播频道名映射到 channel id
      final mapped = <String, List<EpgProgram>>{};
      int successCount = 0, failCount = 0;
      for (var entry in _aliasMap!.entries) {
        final channelName = entry.key;
        final epgid = entry.value;
        final channelId = displayNameToChannelId[epgid];
        if (channelId != null && allPrograms.containsKey(channelId)) {
          mapped[channelName] = allPrograms[channelId]!;
          successCount++;
        } else {
          failCount++;
        }
      }
      await LogService.write('别名映射结果: 成功 $successCount，失败 $failCount');
      _allPrograms = mapped;
      return mapped;
    } catch (e, stack) {
      await LogService.writeCrashLog(e, stack);
      // 返回空映射，避免应用崩溃
      _allPrograms = {};
      return _allPrograms!;
    }
  }

  /// 获取某个频道的 EPG 节目列表
  static List<EpgProgram> getProgramsForChannel(String channelName) {
    return _allPrograms?[channelName] ?? [];
  }

  /// 获取所有 EPG 数据（用于调试）
  static Map<String, List<EpgProgram>> getAllPrograms() {
    return _allPrograms ?? {};
  }
}
