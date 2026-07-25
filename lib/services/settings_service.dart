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
        await LogService.write('SettingsService: 从 SharedPreferences 加载订阅源 ${_subscriptions.length} 条');
      } else {
        await LogService.write('SettingsService: SharedPreferences 中无订阅源数据');
      }

      // 如果没有任何订阅源，从 configuration.json 中读取默认订阅源并添加
      if (_subscriptions.isEmpty) {
        await LogService.write('SettingsService: 无订阅源，尝试从配置加载默认源');
        final config = await ConfigService.getConfig();
        await LogService.write('SettingsService: 配置对象键数: ${config.length}');
        final inner = config['Configuration'] as Map<String, dynamic>?;
        if (inner == null) {
          await LogService.write('SettingsService: 配置中没有 Configuration 键');
        } else {
          final liveUrl = inner['LIVE_URLS'] as String?;
          await LogService.write('SettingsService: LIVE_URLS = $liveUrl');
          if (liveUrl != null && liveUrl.isNotEmpty) {
            String name = '默认源';
            String url = liveUrl;
            // 使用 r'$' 原始字符串避免转义
            if (liveUrl.contains(r'$')) {
              final parts = liveUrl.split(r'$');
              if (parts.length == 2) {
                url = parts[0].trim();
                name = parts[1].trim();
              }
            }
            _subscriptions.add(Subscription(name: name, url: url, selected: true));
            await saveSubscriptions();
            await LogService.write('SettingsService: 自动添加默认订阅源: $name -> $url');
          } else {
            await LogService.write('SettingsService: LIVE_URLS 为空或 null');
          }
        }
      }
      await LogService.write('SettingsService: 最终订阅源数量: ${_subscriptions.length}');
    } catch (e, stack) {
      await LogService.writeCrashLog(e, stack);
    }
    notifyListeners();
  }

  Future<void> saveSubscriptions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(_subscriptions.map((e) => e.toJson()).toList());
      await prefs.setString('subscriptions', json);
      await LogService.write('SettingsService: 订阅源已保存 ${_subscriptions.length} 条');
    } catch (e) {
      await LogService.write('SettingsService: 保存订阅源失败: $e');
    }
  }

  void addSubscription(Subscription sub) {
    _subscriptions.add(sub);
    saveSubscriptions();
    _needsRefresh = true;
    notifyListeners();
  }

  void removeSubscription(Subscription sub) {
    _subscriptions.remove(sub);
    saveSubscriptions();
    _needsRefresh = true;
    notifyListeners();
  }

  void toggleSelected(Subscription sub) {
    sub.selected = !sub.selected;
    saveSubscriptions();
    _needsRefresh = true;
    notifyListeners();
  }

  void markNeedsRefresh() {
    _needsRefresh = true;
    notifyListeners();
  }

  void clearRefreshFlag() {
    _needsRefresh = false;
  }
}
