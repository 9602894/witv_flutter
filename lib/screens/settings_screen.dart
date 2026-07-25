import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/config_service.dart';
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
    final cfg = await ConfigService.getConfig();
    setState(() {
      config = cfg;
      isLoading = false;
    });
  }

  Future<void> _saveConfig() async {
    if (config != null) {
      await ConfigService.saveConfig(config!);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('配置已保存')));
    }
  }

  Future<void> _backup() async {
    await ConfigService.backup();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('配置已备份')));
  }

  Future<void> _restore() async {
    final backups = await ConfigService.getBackupFiles();
    if (backups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('没有备份文件')));
      return;
    }
    // 简单选择第一个（或弹出列表）
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
        ],
      ),
      body: ListView(
        padding: EdgeInsets.all(16),
        children: [
          // 动态生成配置项
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
                  },
                ),
                onLongPress: () {
                  settings.removeSubscription(sub);
                },
              )).toList(),
          ElevatedButton(
            onPressed: () => _addSubscriptionDialog(context),
            child: Text('添加订阅'),
          ),
          Divider(),
          Text('EPG设置', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          // 这里依然保留单独的EPG地址设置（可放在配置中，也可独立）
          // 建议从配置读取，但为了用户方便，单独一个输入
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

  List<Widget> _buildConfigWidgets() {
    final widgets = <Widget>[];
    config!.forEach((key, value) {
      // 跳过一些内部键，或者全部展示
      if (key == 'EPG_URLS') return; // 单独处理
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
        // 整数或浮点数，用滑动条或数字输入
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
        if (key == 'LIVE_URLS' && value == null) {
          // 显示为空
        }
        widget = ListTile(
          title: Text(key),
          subtitle: Text(value ?? '未设置'),
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
                      onPressed: () => Navigator.pop(context, (context as dynamic).findAncestorStateOfType<TextField>()?.text),
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
                Provider.of<SettingsService>(context, listen: false)
                    .addSubscription(Subscription(name: name, url: url));
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
