import 'package:dio/dio.dart';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/channel.dart';
import 'log_service.dart';
import 'settings_service.dart';

class PlaylistParser {
  static Future<Directory> _getCacheDir() async {
    final cacheDir = await SettingsService.getCacheDir();
    final playlistDir = Directory('${cacheDir.path}/playlists');
    if (!await playlistDir.exists()) {
      await playlistDir.create(recursive: true);
    }
    return playlistDir;
  }

  static String _getHashUrl(String url) {
    final uri = Uri.parse(url);
    final base = uri.toString();
    if (base.contains('?')) {
      return '$base.hash';
    }
    return '$base.hash';
  }

  static Future<String?> _fetchHash(String url) async {
    try {
      final hashUrl = _getHashUrl(url);
      LogService.write('获取哈希: $hashUrl');
      final response = await Dio().get(hashUrl);
      final hash = response.data as String?;
      if (hash != null) {
        return hash.trim();
      }
    } catch (e) {
      LogService.write('获取哈希失败: $e');
    }
    return null;
  }

  static Future<String?> _getLocalHash(String url) async {
    final dir = await _getCacheDir();
    final hashFile = File('${dir.path}/playlist_${url.hashCode}.hash');
    if (await hashFile.exists()) {
      return await hashFile.readAsString();
    }
    return null;
  }

  static Future<void> _saveLocalHash(String url, String hash) async {
    final dir = await _getCacheDir();
    final hashFile = File('${dir.path}/playlist_${url.hashCode}.hash');
    await hashFile.writeAsString(hash);
  }

  static Future<void> _deleteCache(String url, String hash) async {
    final dir = await _getCacheDir();
    final file = File('${dir.path}/playlist_${url.hashCode}_$hash.m3u');
    if (await file.exists()) {
      await file.delete();
      LogService.write('删除旧缓存: ${file.path}');
    }
  }

  static Future<String?> _downloadAndCache(String url, String hash) async {
    try {
      final response = await Dio().get(url);
      final content = response.data as String;
      final dir = await _getCacheDir();
      final file = File('${dir.path}/playlist_${url.hashCode}_$hash.m3u');
      await file.writeAsString(content);
      LogService.write('新缓存已保存: ${file.path}');
      return content;
    } catch (e) {
      LogService.write('下载播放列表失败: $e');
      return null;
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

  static Future<Map<String, List<Channel>>> loadPlaylist(String url) async {
    await LogService.write('加载订阅源: $url');
    final remoteHash = await _fetchHash(url);
    if (remoteHash == null || remoteHash.isEmpty) {
      LogService.write('无法获取哈希，直接下载');
      final content = await Dio().get(url).then((r) => r.data as String);
      return parseFromString(content);
    }
    LogService.write('远程哈希: $remoteHash');

    final localHash = await _getLocalHash(url);
    LogService.write('本地哈希: $localHash');

    if (localHash == remoteHash) {
      final dir = await _getCacheDir();
      final cacheFile = File('${dir.path}/playlist_${url.hashCode}_$remoteHash.m3u');
      if (await cacheFile.exists()) {
        final content = await cacheFile.readAsString();
        LogService.write('使用本地缓存');
        return parseFromString(content);
      }
      LogService.write('本地哈希匹配但缓存文件丢失，重新下载');
    }

    if (localHash != null && localHash.isNotEmpty) {
      await _deleteCache(url, localHash);
    }
    final content = await _downloadAndCache(url, remoteHash);
    if (content != null) {
      await _saveLocalHash(url, remoteHash);
      return parseFromString(content);
    } else {
      if (localHash != null && localHash.isNotEmpty) {
        final dir = await _getCacheDir();
        final cacheFile = File('${dir.path}/playlist_${url.hashCode}_$localHash.m3u');
        if (await cacheFile.exists()) {
          final contentOld = await cacheFile.readAsString();
          LogService.write('下载失败，使用旧缓存');
          return parseFromString(contentOld);
        }
      }
      throw Exception('无法加载订阅源');
    }
  }

  static Future<Map<String, List<Channel>>> refreshPlaylist(String url) async {
    final dir = await _getCacheDir();
    final hashFile = File('${dir.path}/playlist_${url.hashCode}.hash');
    if (await hashFile.exists()) await hashFile.delete();
    final files = await dir.list().where((f) => f is File && f.path.contains('playlist_${url.hashCode}_')).toList();
    for (var f in files) {
      await f.delete();
    }
    return await loadPlaylist(url);
  }

  // 兼容旧接口，但已不推荐使用
  static Future<File> getCacheFile(String url, String name) async {
    final dir = await _getCacheDir();
    return File('${dir.path}/temp_${url.hashCode}.m3u');
  }

  static Future<void> saveCache(Map<String, List<Channel>> groupMap, String url, String name) async {
    await LogService.write('saveCache 已废弃，使用 loadPlaylist');
  }
}
