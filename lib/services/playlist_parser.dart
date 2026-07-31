import 'package:dio/dio.dart';
import 'package:dio/io.dart'; // 引入 IOHttpClientAdapter
import 'dart:io';
import 'package:system_proxy/system_proxy.dart'; // 需添加依赖
import '../models/channel.dart';
import 'log_service.dart';
import 'settings_service.dart';

class PlaylistParser {
  static Future<Map<String, List<Channel>>> parseFromUrl(String url) async {
    await LogService.write('开始解析播放列表: $url');
    try {
      final dio = await _createDioWithProxy();
      final response = await dio.get(url);
      final content = response.data as String;
      await LogService.write('下载成功，内容长度: ${content.length}');
      return parseFromString(content);
    } catch (e, stack) {
      await LogService.writeCrashLog(e, stack);
      rethrow;
    }
  }

  // 创建支持代理的 Dio 实例
  static Future<Dio> _createDioWithProxy() async {
    final dio = Dio();
    try {
      // 获取系统代理（Android/iOS）
      final proxy = await SystemProxy.getProxy();
      if (proxy != null && proxy.isNotEmpty) {
        LogService.write('使用系统代理: $proxy');
        dio.httpClientAdapter = IOHttpClientAdapter(
          createHttpClient: () {
            final client = HttpClient();
            client.findProxy = (uri) => 'PROXY $proxy';
            // 忽略证书错误（可选，若代理为 MITM 时可避免问题）
            // client.badCertificateCallback = (cert, host, port) => true;
            return client;
          },
        );
      } else {
        LogService.write('未检测到系统代理，使用直连');
        // 使用默认适配器（直连）
        dio.httpClientAdapter = IOHttpClientAdapter();
      }
    } catch (e) {
      LogService.write('获取代理失败: $e，使用直连');
      dio.httpClientAdapter = IOHttpClientAdapter();
    }
    return dio;
  }

  // 以下方法保持不变
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

  static Future<void> saveCache(Map<String, List<Channel>> groupMap, String url, String name) async {
    final file = await getCacheFile(url, name);
    final content = _serializeToM3U(groupMap);
    await file.writeAsString(content);
    await LogService.write('缓存已保存: ${file.path}');
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
