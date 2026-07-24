import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/subscription.dart';
import 'dart:convert';

class SettingsService extends ChangeNotifier {
  List<Subscription> _subscriptions = [];
  String? _epgUrl;
  bool _autoReconnect = true;
  bool _showSpeed = true;

  List<Subscription> get subscriptions => _subscriptions;
  String? get epgUrl => _epgUrl;
  bool get autoReconnect => _autoReconnect;
  bool get showSpeed => _showSpeed;

  SettingsService() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final subsJson = prefs.getString('subscriptions');
    if (subsJson != null) {
      final list = jsonDecode(subsJson) as List;
      _subscriptions = list.map((e) => Subscription.fromJson(e)).toList();
    }
    _epgUrl = prefs.getString('epg_url');
    _autoReconnect = prefs.getBool('auto_reconnect') ?? true;
    _showSpeed = prefs.getBool('show_speed') ?? true;
    notifyListeners();
  }

  Future<void> saveSubscriptions() async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(_subscriptions.map((e) => e.toJson()).toList());
    await prefs.setString('subscriptions', json);
  }

  void addSubscription(Subscription sub) {
    _subscriptions.add(sub);
    saveSubscriptions();
    notifyListeners();
  }

  void removeSubscription(Subscription sub) {
    _subscriptions.remove(sub);
    saveSubscriptions();
    notifyListeners();
  }

  void toggleSelected(Subscription sub) {
    sub.selected = !sub.selected;
    saveSubscriptions();
    notifyListeners();
  }

  void setEpgUrl(String url) async {
    _epgUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('epg_url', url);
    notifyListeners();
  }

  void toggleAutoReconnect() {
    _autoReconnect = !_autoReconnect;
    SharedPreferences.getInstance().then((prefs) => prefs.setBool('auto_reconnect', _autoReconnect));
    notifyListeners();
  }

  void toggleShowSpeed() {
    _showSpeed = !_showSpeed;
    SharedPreferences.getInstance().then((prefs) => prefs.setBool('show_speed', _showSpeed));
    notifyListeners();
  }
}
