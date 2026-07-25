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

  static Future<Map<String, List<EpgProgram>>> loadAllEpg(String url) async {
    if (_allPrograms != null) return _allPrograms!;
    await LogService.write('开始加载EPG: $url');

    try {
      await loadAliasMap();

      final dir = await getApplicationDocumentsDirectory();
      final cacheFile = File('${dir.path}/epg_cache.xml');
      final hashFile = File('${dir.path}/epg_hash.txt');

      bool needDownload = true;
      try {
        final hashResponse = await Dio().get('$url.hash');
        final remoteHash = hashResponse.data as String;
        if (await hashFile.exists()) {
          final localHash = await hashFile.readAsString();
          if (localHash.trim() == remoteHash.trim() && await cacheFile.exists()) {
            needDownload = false;
          }
        }
        if (needDownload) {
          final response = await Dio().get(url);
          await cacheFile.writeAsString(response.data as String);
          await hashFile.writeAsString(remoteHash);
          await LogService.write('EPG下载完成，使用缓存');
        } else {
          await LogService.write('使用缓存的EPG文件');
        }
      } catch (e) {
        await LogService.write('获取哈希失败，直接下载: $e');
        final response = await Dio().get(url);
        await cacheFile.writeAsString(response.data as String);
        await LogService.write('EPG下载完成（无哈希）');
      }

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
      for (var prog in document.findAllElements('programme')) {
        final channelId = prog.getAttribute('channel')!;
        final startStr = prog.getAttribute('start')!.replaceAll(RegExp(r'[+\-]\d+$'), '');
        final stopStr = prog.getAttribute('stop')!.replaceAll(RegExp(r'[+\-]\d+$'), '');
        final start = DateTime.parse(startStr);
        final stop = DateTime.parse(stopStr);
        final title = prog.findAllElements('title').firstOrNull?.text.trim() ?? '';
        final desc = prog.findAllElements('desc').firstOrNull?.text.trim() ?? '';
        allPrograms.putIfAbsent(channelId, () => []);
        allPrograms[channelId]!.add(EpgProgram(start: start, end: stop, title: title, desc: desc));
      }
      await LogService.write('EPG节目总条目数: ${allPrograms.values.fold(0, (sum, list) => sum + list.length)}');

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
      rethrow;
    }
  }

  static List<EpgProgram> getProgramsForChannel(String channelName) {
    return _allPrograms?[channelName] ?? [];
  }
}
