import 'package:dio/dio.dart';
import 'package:xml/xml.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import '../models/epg_program.dart';

class EpgParser {
  static Map<String, String>? _aliasMap;
  static Map<String, List<EpgProgram>>? _allPrograms;

  static Future<Map<String, String>> loadAliasMap() async {
    if (_aliasMap != null) return _aliasMap!;
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
    return map;
  }

  static Future<Map<String, List<EpgProgram>>> loadAllEpg(String url) async {
    if (_allPrograms != null) return _allPrograms!;
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
      }
    } catch (e) {
      // 无hash，直接下载
      final response = await Dio().get(url);
      await cacheFile.writeAsString(response.data as String);
    }

    final xmlString = await cacheFile.readAsString();
    final document = XmlDocument.parse(xmlString);
    final allPrograms = <String, List<EpgProgram>>{};
    final channelIdToName = <String, String>{};
    final channelIdToIcon = <String, String>{};

    for (var channel in document.findAllElements('channel')) {
      final id = channel.getAttribute('id')!;
      final displayNames = channel.findAllElements('display-name').map((e) => e.text.trim()).toList();
      final icon = channel.findAllElements('icon').firstOrNull?.getAttribute('src');
      if (displayNames.isNotEmpty) {
        channelIdToName[id] = displayNames.first;
        if (icon != null) channelIdToIcon[id] = icon;
      }
    }

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

    // 应用别名映射
    final mapped = <String, List<EpgProgram>>{};
    for (var entry in _aliasMap!.entries) {
      final alias = entry.key;
      final epgid = entry.value;
      if (allPrograms.containsKey(epgid)) {
        mapped[alias] = allPrograms[epgid]!;
      }
    }
    for (var entry in channelIdToName.entries) {
      if (!mapped.containsKey(entry.value)) {
        mapped[entry.value] = allPrograms[entry.key] ?? [];
      }
    }
    _allPrograms = mapped;
    return _allPrograms!;
  }

  static List<EpgProgram> getProgramsForChannel(String channelName) {
    return _allPrograms?[channelName] ?? [];
  }
}
