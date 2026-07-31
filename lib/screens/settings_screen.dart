import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/log_service.dart';
import '../models/subscription.dart';
import 'dart:io';

class SettingsScreen extends StatefulWidget {
  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();
  bool _isAdding = false;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('设置'),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: () {
              settings.markNeedsRefresh();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已标记刷新，返回后自动更新')),
              );
            },
          ),
        ],
      ),
      body: ListView(
        children: [
          // ---------- 订阅源管理 ----------
          Card(
            margin: EdgeInsets.all(8),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('订阅源管理', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  // 添加订阅源表单
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _nameController,
                          decoration: InputDecoration(
                            labelText: '名称',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _urlController,
                          decoration: InputDecoration(
                            labelText: 'URL',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _isAdding ? null : _addSubscription,
                        child: _isAdding ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text('添加'),
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  // 订阅源列表
                  ...settings.subscriptions.map((sub) => ListTile(
                    leading: Checkbox(
                      value: sub.selected,
                      onChanged: (_) {
                        settings.toggleSelected(sub);
                      },
                    ),
                    title: Text(sub.name),
                    subtitle: Text(sub.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: Icon(Icons.delete, color: Colors.red),
                      onPressed: () {
                        _confirmDelete(sub);
                      },
                    ),
                  )).toList(),
                  if (settings.subscriptions.isEmpty)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(child: Text('暂无订阅源，请添加')),
                    ),
                ],
              ),
            ),
          ),

          // ---------- 解码器选择 ----------
          Card(
            margin: EdgeInsets.all(8),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('解码器', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  DropdownButton<int>(
                    value: settings.decoderIndex,
                    items: [
                      DropdownMenuItem(value: 0, child: Text('硬件解码')),
                      DropdownMenuItem(value: 1, child: Text('软件解码')),
                    ],
                    onChanged: (value) {
                      if (value != null) settings.setDecoderIndex(value);
                    },
                    isExpanded: true,
                  ),
                  SizedBox(height: 8),
                  Text('当前解码器: ${settings.decoderIndex == 0 ? '硬件' : '软件'}'),
                ],
              ),
            ),
          ),

          // ---------- 自动重连 ----------
          Card(
            margin: EdgeInsets.all(8),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  Text('断线自动重连', style: TextStyle(fontSize: 18)),
                  Spacer(),
                  Switch(
                    value: settings.autoReconnect,
                    onChanged: (value) {
                      settings.setAutoReconnect(value);
                    },
                  ),
                ],
              ),
            ),
          ),

          // ---------- 日志操作 ----------
          Card(
            margin: EdgeInsets.all(8),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('日志', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: Icon(Icons.file_download),
                          label: Text('导出日志'),
                          onPressed: _exportLog,
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: Icon(Icons.delete_forever),
                          label: Text('清空日志'),
                          onPressed: _clearLogs,
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // ---------- 关于 ----------
          Card(
            margin: EdgeInsets.all(8),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('关于', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  ListTile(
                    leading: Icon(Icons.info),
                    title: Text('Witv 播放器'),
                    subtitle: Text('版本 1.0.0\n基于 Flutter 构建'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 添加订阅源
  Future<void> _addSubscription() async {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请填写完整信息')),
      );
      return;
    }
    setState(() => _isAdding = true);
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final exists = settings.subscriptions.any((s) => s.url == url || s.name == name);
      if (exists) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('订阅源已存在')),
        );
        return;
      }
      settings.addSubscription(Subscription(name: name, url: url, selected: true));
      _nameController.clear();
      _urlController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已添加订阅: $name')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('添加失败: $e')),
      );
    } finally {
      setState(() => _isAdding = false);
    }
  }

  // 确认删除
  Future<void> _confirmDelete(Subscription sub) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('确认删除'),
        content: Text('确定要删除订阅 "${sub.name}" 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text('删除'), style: TextButton.styleFrom(foregroundColor: Colors.red)),
        ],
      ),
    );
    if (confirm == true) {
      final settings = Provider.of<SettingsService>(context, listen: false);
      settings.removeSubscription(sub);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除: ${sub.name}')),
      );
    }
  }

  // 导出日志（已修复 null 安全）
  Future<void> _exportLog() async {
    try {
      final file = await LogService.export();
      if (file != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('日志文件: ${file.path}')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('暂无日志文件')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败: $e')),
      );
    }
  }

  // 清空日志
  Future<void> _clearLogs() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('确认清空'),
        content: Text('将删除所有日志文件，确认吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text('清空'), style: TextButton.styleFrom(foregroundColor: Colors.red)),
        ],
      ),
    );
    if (confirm == true) {
      try {
        final dir = await LogService.getLogDir();
        if (await dir.exists()) {
          await dir.delete(recursive: true);
          await dir.create(recursive: true);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('日志已清空')),
          );
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清空失败: $e')),
        );
      }
    }
  }
}
