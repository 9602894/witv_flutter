import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/subscription.dart';
import 'dart:convert';

class SettingsService extends ChangeNotifier {
  List<Subscription> _subscriptions = [];

  List<Subscription> get subscriptions => _subscriptions;

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
}
