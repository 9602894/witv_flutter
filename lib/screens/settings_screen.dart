import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/config_service.dart';
import '../services/log_service.dart';
import '../models/subscription.dart';

class SettingsScreen extends StatefulWidget {
  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? config;
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final cfg = await ConfigService.getConfig();
      // 注意：configuration.json 根对象有一个 Configuration 键
      final inner = cfg['Configuration'] as Map<String, dynamic>?;
      setState(() {
        config = inner ?? {};
        isLoading = false;
      });
      await LogService.write('加载配置成功，键数: ${config?.length}');
    } catch (e) {
      await LogService.write('加载配置失败: $e');
      setState(() {
        config = {};
        isLoading = false;
      });
    }
  }

  Future<void> _saveConfig() async {
    if (config != null) {
      // 需要将修改后的 config 放回 Configuration 键下
      final full = {'Configuration': config};
      await ConfigService.saveConfig(full);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('配置已保存')));
      await LogService.write('配置已保存');
    }
  }

  Future<void> _backup() async {
    await ConfigService.backup();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('配置已备份')));
    await LogService.write('配置已备份');
  }

  Future<void> _restore() async {
    final backups = await ConfigService.getBackupFiles();
    if (backups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('没有备份文件')));
      return;
    }
    final selected = await showDialog<File>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('选择备份'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: backups.map((f) => ListTile(
            title: Text(f.path.split('/').last),
            onTap: () => Navigator.pop(context, f),
          )).toList(),
        ),
      ),
    );
    if (selected != null) {
      await ConfigService.restoreFromBackup(selected);
      await _loadConfig();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('配置已恢复')));
      await LogService.write('配置已恢复');
    }
  }

  Future<void> _exportLog() async {
    try {
      final file = await LogService.export();
      // 使用 share_plus 分享，或直接显示对话框
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('日志已导出'),
          content: Text('日志文件已保存到:\n${file.path}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('确定'),
            ),
          ],
        ),
      );
      await LogService.write('日志导出成功');
    } catch (e) {
      await LogService.write('导出日志失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) return Scaffold(body: Center(child: CircularProgressIndicator()));
    final settings = Provider.of<SettingsService>(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('设置'),
        actions: [
          IconButton(icon: Icon(Icons.save), onPressed: _saveConfig),
          IconButton(icon: Icon(Icons.backup), onPressed: _backup),
          IconButton(icon: Icon(Icons.restore), onPressed: _restore),
          IconButton(icon: Icon(Icons.file_download), onPressed: _exportLog),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.all(16),
        children: [
          ..._buildConfigWidgets(),
          Divider(),
          Text('订阅源管理', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ...settings.subscriptions.map((sub) => ListTile(
                title: Text(sub.name),
                subtitle: Text(sub.url),
                trailing: Checkbox(
                  value: sub.selected,
                  onChanged: (_) {
                    settings.toggleSelected(sub);
                    // 标记需要刷新主页
                    _markNeedRefresh();
                  },
                ),
                onLongPress: () {
                  settings.removeSubscription(sub);
                  _markNeedRefresh();
                },
              )).toList(),
          ElevatedButton(
            onPressed: () => _addSubscriptionDialog(context),
            child: Text('添加订阅'),
          ),
          Divider(),
          Text('EPG设置', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ListTile(
            title: Text('EPG地址'),
            subtitle: Text(config!['EPG_URLS'] ?? '未设置'),
            trailing: IconButton(
              icon: Icon(Icons.edit),
              onPressed: () => _editEpgDialog(context),
            ),
          ),
        ],
      ),
    );
  }

  void _markNeedRefresh() {
    // 通过 SettingsService 设置一个标记
    Provider.of<SettingsService>(context, listen: false).markNeedsRefresh();
  }

  List<Widget> _buildConfigWidgets() {
    final widgets = <Widget>[];
    config!.forEach((key, value) {
      // 跳过 EPG_URLS，单独处理
      if (key == 'EPG_URLS') return;
      // 跳过 null 或列表等复杂类型
      if (value == null) return;
      if (value is! bool && value is! num && value is! String) {
        // 显示为不可编辑文本
        widgets.add(ListTile(
          title: Text(key),
          subtitle: Text('复杂类型 (${value.runtimeType})，不可编辑'),
        ));
        return;
      }
      Widget widget;
      if (value is bool) {
        widget = SwitchListTile(
          title: Text(key),
          value: value,
          onChanged: (newVal) {
            setState(() {
              config![key] = newVal;
            });
          },
        );
      } else if (value is num) {
        widget = ListTile(
          title: Text(key),
          subtitle: Text('$value'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(icon: Icon(Icons.remove), onPressed: () {
                setState(() {
                  if (value is int) config![key] = (value - 1).clamp(0, 100);
                  else config![key] = (value - 0.5).clamp(0.0, 100.0);
                });
              }),
              IconButton(icon: Icon(Icons.add), onPressed: () {
                setState(() {
                  if (value is int) config![key] = (value + 1).clamp(0, 100);
                  else config![key] = (value + 0.5).clamp(0.0, 100.0);
                });
              }),
            ],
          ),
        );
      } else if (value is String) {
        widget = ListTile(
          title: Text(key),
          subtitle: Text(value),
          trailing: IconButton(
            icon: Icon(Icons.edit),
            onPressed: () async {
              final newVal = await showDialog<String>(
                context: context,
                builder: (_) => AlertDialog(
                  title: Text('编辑 $key'),
                  content: TextField(
                    controller: TextEditingController(text: value),
                    decoration: InputDecoration(labelText: key),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: Text('取消')),
                    TextButton(
                      onPressed: () {
                        final text = (context as dynamic).findAncestorStateOfType<TextField>()?.controller?.text;
                        Navigator.pop(context, text);
                      },
                      child: Text('确定'),
                    ),
                  ],
                ),
              );
              if (newVal != null) {
                setState(() {
                  config![key] = newVal;
                });
              }
            },
          ),
        );
      } else {
        widget = ListTile(title: Text('$key: 不支持的类型'));
      }
      widgets.add(widget);
    });
    return widgets;
  }

  void _editEpgDialog(BuildContext context) {
    final current = config!['EPG_URLS'] ?? '';
    final ctrl = TextEditingController(text: current);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('EPG地址'),
        content: TextField(controller: ctrl, decoration: InputDecoration(labelText: 'XMLTV URL')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('取消')),
          TextButton(
            onPressed: () {
              final url = ctrl.text.trim();
              if (url.isNotEmpty) {
                setState(() {
                  config!['EPG_URLS'] = url;
                });
                Navigator.pop(context);
              }
            },
            child: Text('保存'),
          ),
        ],
      ),
    );
  }

  void _addSubscriptionDialog(BuildContext context) {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('添加订阅'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: InputDecoration(labelText: '名称')),
            TextField(controller: urlCtrl, decoration: InputDecoration(labelText: 'URL')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('取消')),
          TextButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              final url = urlCtrl.text.trim();
              if (name.isNotEmpty && url.isNotEmpty) {
                final settings = Provider.of<SettingsService>(context, listen: false);
                settings.addSubscription(Subscription(name: name, url: url));
                // 标记刷新
                _markNeedRefresh();
                Navigator.pop(context);
              }
            },
            child: Text('添加'),
          ),
        ],
      ),
    );
  }
}
