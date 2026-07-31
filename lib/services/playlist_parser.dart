import 'package:dio/dio.dart';
import 'dart:io';
import '../models/channel.dart';
import 'log_service.dart';
import 'settings_service.dart';

class PlaylistParser {
  static Future<Map<String, List<Channel>>> parseFromUrl(String url) async {
    await LogService.write('开始解析播放列表: $url');
    try {
      final response = await Dio().get(url);
      final content = response.data as String;
      await LogService.write('下载成功，内容长度: ${content.length}');
      return parseFromString(content);
    } catch (e, stack) {
      await LogService.writeCrashLog(e, stack);
      rethrow;
    }
  }

  static Map<String, List<Channel>> parseFromString(String content) {
    final lines = content.split('\n');
    final Map<String, List<Channel>> groupMap = {};
    String currentGroup = '默认分组';

    for (var i = 0; i < lines.length; i++) {
      String line = lines[i].trim();
      if (line.startsWith('#EXTM3U')) continue;

      if (line.startsWith('#EXTINF:')) {
        final groupMatch = RegExp(r'group-title="([^"]*)"').firstMatch(line);
        final logoMatch = RegExp(r'tvg-logo="([^"]*)"').firstMatch(line);
        final name = line.split(',').last.trim();
        final group = groupMatch?.group(1) ?? '默认分组';
        final logo = logoMatch?.group(1);

        if (i + 1 < lines.length) {
          String urlLine = lines[i + 1].trim();
          if (!urlLine.startsWith('#') && urlLine.isNotEmpty) {
            groupMap.putIfAbsent(group, () => []);
            groupMap[group]!.add(Channel(name: name, url: urlLine, group: group, logoUrl: logo));
          }
        }
      } else if (line.endsWith('#genre#')) {
        currentGroup = line.replaceAll('#genre#', '').trim();
        groupMap.putIfAbsent(currentGroup, () => []);
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        final parts = line.split(',');
        if (parts.length >= 2) {
          final name = parts[0].trim();
          final url = parts[1].trim();
          groupMap.putIfAbsent(currentGroup, () => []);
          groupMap[currentGroup]!.add(Channel(name: name, url: url, group: currentGroup));
        }
      }
    }
    return groupMap;
  }

  // 使用 URL 的 hashCode 生成固定文件名（不添加时间戳，无额外依赖）
  static Future<File> getCacheFile(String url, String name) async {
    final cacheDir = await SettingsService.getCacheDir();
    final hash = url.hashCode.toRadixString(16).padLeft(8, '0');
    final extension = _getExtension(url);
    final fileName = 'playlist_$hash.$extension';
    return File('${cacheDir.path}/$fileName');
  }

  static String _getExtension(String url) {
    final parts = url.split('.');
    final ext = parts.last.split('?')[0];
    if (ext == 'm3u' || ext == 'm3u8' || ext == 'txt') {
      return ext;
    }
    return 'm3u';
  }

  // 直接覆盖写入同一个文件，每次更新内容
  static Future<void> saveCache(Map<String, List<Channel>> groupMap, String url, String name) async {
    final file = await getCacheFile(url, name);
    final content = _serializeToM3U(groupMap);
    await file.writeAsString(content);
    await LogService.write('缓存已保存: ${file.path}');
    // 无需清理旧缓存，因为只有一个文件
  }

  static String _serializeToM3U(Map<String, List<Channel>> groupMap) {
    StringBuffer sb = StringBuffer();
    sb.writeln('#EXTM3U');
    for (var entry in groupMap.entries) {
      final group = entry.key;
      for (var ch in entry.value) {
        sb.writeln('#EXTINF:-1 group-title="$group" tvg-logo="${ch.logoUrl ?? ''}",${ch.name}');
        sb.writeln(ch.url);
      }
    }
    return sb.toString();
  }
}
