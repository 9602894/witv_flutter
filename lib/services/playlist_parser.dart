import 'package:dio/dio.dart';
import '../models/channel.dart';
import 'log_service.dart';

class PlaylistParser {
  static Future<Map<String, List<Channel>>> parseFromUrl(String url) async {
    await LogService.write('开始解析播放列表: $url');
    try {
      final response = await Dio().get(url);
      final content = response.data as String;
      await LogService.write('下载成功，内容长度: ${content.length}');
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
      await LogService.write('解析完成，分组数: ${groupMap.length}');
      return groupMap;
    } catch (e, stack) {
      await LogService.writeCrashLog(e, stack);
      rethrow;
    }
  }
}
