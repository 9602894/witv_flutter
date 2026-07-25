import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/subscription.dart';
import 'dart:convert';
import 'log_service.dart';
import 'config_service.dart';

class SettingsService extends ChangeNotifier {
  List<Subscription> _subscriptions = [];
  bool _needsRefresh = false;

  List<Subscription> get subscriptions => _subscriptions;
  bool get needsRefresh => _needsRefresh;

  SettingsService() {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final subsJson = prefs.getString('subscriptions');
      if (subsJson != null) {
        final list = jsonDecode(subsJson) as List;
        _subscriptions = list.map((e) => Subscription.fromJson(e)).toList();
      }

      // 如果没有任何订阅源，从 configuration.json 中读取默认订阅源并添加
      if (_subscriptions.isEmpty) {
        final config = await ConfigService.getConfig();
        final inner = config['Configuration'] as Map<String, dynamic>?;
        final liveUrl = inner?['LIVE_URLS'] as String?;
        if (liveUrl != null && liveUrl.isNotEmpty) {
          String name = '默认源';
          String url = liveUrl;
          if (liveUrl.contains('$')) {
            final parts = liveUrl.split('\$');
            if (parts.length == 2) {
              url = parts[0].trim();
              name = parts[1].trim();
            }
          }
          _subscriptions.add(Subscription(name: name, url: url, selected: true));
          await saveSubscriptions();
          await LogService.write('自动添加默认订阅源: $name -> $url');
        }
      }
      await LogService.write('加载订阅源: ${_subscriptions.length} 条');
    } catch (e) {
      await LogService.write('加载订阅源失败: $e');
    }
    notifyListeners();
  }

  // 其他方法不变...
}
