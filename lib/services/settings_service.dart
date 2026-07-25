import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/subscription.dart';
import 'dart:convert';
import 'log_service.dart';

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
        await LogService.write('SettingsService: 加载订阅源 ${_subscriptions.length} 条');
      } else {
        await LogService.write('SettingsService: SharedPreferences 中无订阅源数据');
      }
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
