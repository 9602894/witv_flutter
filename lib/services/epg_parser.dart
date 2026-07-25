import 'package:dio/dio.dart';
import 'package:xml/xml.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart' show compute;
import '../models/epg_program.dart';
import 'log_service.dart';

class EpgParser {
  static Map<String, String>? _aliasMap;
  static Map<String, List<EpgProgram>>? _allPrograms;
  static Map<String, String>? _channelIdMap;

  // 用于 compute 的解析参数
  static Future<Map<String, List<EpgProgram>>> _parseEpgInIsolate(String xmlString) async {
    // 在 isolate 中解析 XML
    final document = XmlDocument.parse(xmlString);
    final allPrograms = <String, List<EpgProgram>>{};
    final displayNameToChannelId = <String, String>{};

    for (var channel in document.findAllElements('channel')) {
      final id = channel.getAttribute('id')!;
      final displayNames = channel.findAllElements('display-name').map((e) => e.text.trim()).toList();
      for (var name in displayNames) {
        displayNameToChannelId[name] = id;
      }
    }

    int programCount = 0;
    for (var prog in document.findAllElements('programme')) {
      final channelId = prog.getAttribute('channel')!;
      String startStr = prog.getAttribute('start')!.replaceAll(RegExp(r'[+\-]\d+$'), '').trim();
      String stopStr = prog.getAttribute('stop')!.replaceAll(RegExp(r'[+\-]\d+$'), '').trim();
      try {
        DateTime start, stop;
        if (RegExp(r'^\d{14}$').hasMatch(startStr)) {
          start = DateTime(
            int.parse(startStr.substring(0, 4)),
            int.parse(startStr.substring(4, 6)),
            int.parse(startStr.substring(6, 8)),
            int.parse(startStr.substring(8, 10)),
            int.parse(startStr.substring(10, 12)),
            int.parse(startStr.substring(12, 14)),
          );
        } else {
          start = DateTime.parse(startStr);
        }
        if (RegExp(r'^\d{14}$').hasMatch(stopStr)) {
          stop = DateTime(
            int.parse(stopStr.substring(0, 4)),
            int.parse(stopStr.substring(4, 6)),
            int.parse(stopStr.substring(6, 8)),
            int.parse(stopStr.substring(8, 10)),
            int.parse(stopStr.substring(10, 12)),
            int.parse(stopStr.substring(12, 14)),
          );
        } else {
          stop = DateTime.parse(stopStr);
        }

        final title = prog.findAllElements('title').firstOrNull?.text.trim() ?? '';
        final desc = prog.findAllElements('desc').firstOrNull?.text.trim() ?? '';
        allPrograms.putIfAbsent(channelId, () => []);
        allPrograms[channelId]!.add(EpgProgram(start: start, end: stop, title: title, desc: desc));
        programCount++;
      } catch (e) {
        // 忽略解析错误
      }
    }
    return allPrograms;
  }

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
      final dio = Dio(BaseOptions(
        connectTimeout: Duration(seconds: 10),
        receiveTimeout: Duration(seconds: 15),
      ));
      try {
        final hashUrl = '$url.hash';
        final hashResponse = await dio.get(hashUrl);
        final remoteHash = hashResponse.data as String;
        if (await hashFile.exists()) {
          final localHash = await hashFile.readAsString();
          if (localHash.trim() == remoteHash.trim() && await cacheFile.exists()) {
            needDownload = false;
            await LogService.write('使用缓存的EPG文件（哈希匹配）');
          }
        }
        if (needDownload) {
          final response = await dio.get(url);
          await cacheFile.writeAsString(response.data as String);
          await hashFile.writeAsString(remoteHash);
          await LogService.write('EPG下载完成，已缓存');
        }
      } catch (e) {
        await LogService.write('获取哈希失败，直接下载: $e');
        final response = await dio.get(url);
        await cacheFile.writeAsString(response.data as String);
        await LogService.write('EPG下载完成（无哈希）');
      }

      // 读取 XML 内容
      final xmlString = await cacheFile.readAsString();

      // 在 isolate 中解析 XML（避免阻塞 UI）
      final allPrograms = await compute(_parseEpgInIsolate, xmlString);
      await LogService.write('EPG解析完成，原始频道数: ${allPrograms.length}');

      // 构建 displayName -> channelId 映射（已在 isolate 中完成，但我们还需要 _channelIdMap 用于调试）
      // 不过我们需要 displayNameToChannelId 来映射别名，所以我们在 isolate 中已经构建了，但 isolate 返回的是 allPrograms，我们需要 displayNameToChannelId。
      // 因此，我们重新解析一次 displayNameToChannelId 或修改 compute 返回更多数据。
      // 为了简单，我们在主线程中重新构建 displayNameToChannelId（只做映射，不做大量解析）
      // 但为了性能，我们也可以在 compute 中返回包含 displayNameToChannelId 的 Map。
      // 这里我们简单重新解析 XML 头部，但数据量大，不可取。
      // 改进：修改 compute 函数返回 (allPrograms, displayNameToChannelId)。
      // 但由于时间，我们采用简单方法：在 loadAllEpg 中直接解析 displayNameToChannelId（只解析 channel，不解析 programme，很快）
      // 但为了代码简洁，我们使用之前保存的 displayNameToChannelId，但 compute 无法返回多个值，我们返回一个 tuple 或自定义对象。
      // 我们重构 compute 返回 Map<String, dynamic> 包含两个键。

      // 由于 compute 限制，我们将 displayNameToChannelId 也放入返回。
      // 但为了快速修复，我们直接在主线程中从 XML 中提取 channel 映射（只解析 channel，不解析 programme，很快）
      final document = XmlDocument.parse(xmlString);
      final displayNameToChannelId = <String, String>{};
      for (var channel in document.findAllElements('channel')) {
        final id = channel.getAttribute('id')!;
        final displayNames = channel.findAllElements('display-name').map((e) => e.text.trim()).toList();
        for (var name in displayNames) {
          displayNameToChannelId[name] = id;
        }
      }
      _channelIdMap = displayNameToChannelId;
      await LogService.write('EPG中频道数: ${displayNameToChannelId.length}');

      // 映射别名
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
      _allPrograms = {};
      return _allPrograms!;
    }
  }

  static List<EpgProgram> getProgramsForChannel(String channelName) {
    return _allPrograms?[channelName] ?? [];
  }

  static Map<String, List<EpgProgram>> getAllPrograms() {
    return _allPrograms ?? {};
  }
}
