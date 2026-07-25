import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/subscription.dart';
import 'dart:convert';
import 'log_service.dart';

class SettingsService extends ChangeNotifier {
  List<Subscription> _subscriptions = [];
  bool _needsRefresh = false;
  int _decoderIndex = 0; // 0=系统解码，1=IJK硬解，2=IJK软解，3=EXO硬解，4=EXO软解，5=MPV硬解，6=MPV软解

  List<Subscription> get subscriptions => _subscriptions;
  bool get needsRefresh => _needsRefresh;
  int get decoderIndex => _decoderIndex;

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
      _decoderIndex = prefs.getInt('decoder_index') ?? 0;
      await LogService.write('SettingsService: 加载订阅源 ${_subscriptions.length} 条，解码器索引 $_decoderIndex');
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

  void setDecoderIndex(int index) async {
    _decoderIndex = index;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('decoder_index', index);
    await LogService.write('解码器切换为: $index');
    notifyListeners();
  }
}
