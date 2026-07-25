import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:io' show exit;
import '../services/settings_service.dart';
import '../services/config_service.dart';
import '../services/playlist_parser.dart';
import '../services/epg_parser.dart';
import '../services/log_service.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/subscription.dart';
import '../widgets/player_widget.dart';
import '../widgets/channel_list.dart';
import '../widgets/group_list.dart';
import '../widgets/schedule_view.dart';
import '../widgets/info_popup.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Channel> channels = [];
  List<String> groups = [];
  Channel? currentChannel;
  String? currentGroup;
  bool showOverlay = true;
  bool isScheduleMode = false;
  bool isEditMode = false;
  bool _showRightMenu = false;

  // 主界面三个窗口权重
  double subWeight = 0.15;
  double groupWeight = 0.20;
  double channelWeight = 0.65;

  // 节目单左右窗口权重
  double scheduleLeftWeight = 0.35;
  double scheduleRightWeight = 0.65;

  Map<String, List<EpgProgram>> epgMap = {};
  double currentSpeed = 0;
  bool isLoading = true;
  bool _hasSubscriptions = false;

  @override
  void initState() {
    super.initState();
    LogService.write('主页初始化');
    _init();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        // 按返回键：切换右侧菜单显示状态，不退出
        setState(() {
          _showRightMenu = !_showRightMenu;
          // 如果显示菜单，隐藏覆盖层（可选）
          if (_showRightMenu) showOverlay = false;
        });
        return false; // 阻止退出
      },
      child: Scaffold(
        body: Stack(
          children: [
            // 播放器
            if (currentChannel != null)
              PlayerWidget(
                url: currentChannel!.url,
                onError: () => LogService.write('播放器错误回调'),
                onSpeedUpdate: (speed) => setState(() => currentSpeed = speed),
              ),

            // 主覆盖层（透明背景）
            if (showOverlay && !isScheduleMode)
              Positioned.fill(
                child: Container(
                  color: Colors.transparent, // 完全透明
                  child: Row(
                    children: [
                      // 订阅列表
                      Expanded(
                        flex: (subWeight * 100).toInt(),
                        child: _buildSubscriptionList(),
                      ),
                      _buildDragBar(
                        onDrag: (delta) {
                          setState(() {
                            double newSub = subWeight + delta;
                            double newGroup = groupWeight - delta;
                            if (newSub < 0.05) newSub = 0.05;
                            if (newGroup < 0.05) newGroup = 0.05;
                            subWeight = newSub;
                            groupWeight = newGroup;
                            channelWeight = 1 - subWeight - groupWeight;
                            if (channelWeight < 0.05) {
                              channelWeight = 0.05;
                              double total = subWeight + groupWeight;
                              subWeight = subWeight / total * 0.95;
                              groupWeight = groupWeight / total * 0.95;
                            }
                          });
                        },
                        isEditMode: isEditMode,
                      ),
                      Expanded(
                        flex: (groupWeight * 100).toInt(),
                        child: GroupList(
                          groups: groups,
                          selectedGroup: currentGroup,
                          onSelect: (group) {
                            setState(() {
                              currentGroup = group;
                              _loadGroup(group);
                            });
                          },
                        ),
                      ),
                      _buildDragBar(
                        onDrag: (delta) {
                          setState(() {
                            double newGroup = groupWeight + delta;
                            double newChannel = channelWeight - delta;
                            if (newGroup < 0.05) newGroup = 0.05;
                            if (newChannel < 0.05) newChannel = 0.05;
                            groupWeight = newGroup;
                            channelWeight = newChannel;
                            subWeight = 1 - groupWeight - channelWeight;
                            if (subWeight < 0.05) {
                              subWeight = 0.05;
                              double total = groupWeight + channelWeight;
                              groupWeight = groupWeight / total * 0.95;
                              channelWeight = channelWeight / total * 0.95;
                            }
                          });
                        },
                        isEditMode: isEditMode,
                      ),
                      Expanded(
                        flex: (channelWeight * 100).toInt(),
                        child: ChannelList(
                          channels: channels,
                          selectedChannel: currentChannel,
                          onSelect: (ch) {
                            LogService.write('选择频道: ${ch.name}');
                            setState(() {
                              currentChannel = ch;
                            });
                          },
                          epgMap: epgMap,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // 节目单模式（透明背景，可编辑宽度）
            if (isScheduleMode)
              Positioned.fill(
                child: Container(
                  color: Colors.transparent,
                  child: ScheduleView(
                    channels: channels,
                    selectedChannel: currentChannel,
                    epgMap: epgMap,
                    onSelectChannel: (ch) => setState(() => currentChannel = ch),
                    leftWeight: scheduleLeftWeight,
                    rightWeight: scheduleRightWeight,
                    onLeftWeightChanged: (newLeft) {
                      setState(() {
                        scheduleLeftWeight = newLeft.clamp(0.1, 0.9);
                        scheduleRightWeight = 1 - scheduleLeftWeight;
                      });
                    },
                    isEditMode: isEditMode,
                  ),
                ),
              ),

            // 右侧菜单（返回键弹出）
            if (_showRightMenu)
              Positioned(
                top: 0,
                right: 0,
                bottom: 0,
                width: MediaQuery.of(context).size.width * 0.12,
                child: Container(
                  color: Colors.black.withOpacity(0.7),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildMenuItem(Icons.settings, '设置', () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => SettingsScreen()),
                        ).then((_) => setState(() {}));
                        setState(() => _showRightMenu = false);
                      }),
                      _buildMenuItem(Icons.edit, '编辑', () {
                        setState(() {
                          isEditMode = !isEditMode;
                          _showRightMenu = false;
                        });
                      }),
                      _buildMenuItem(Icons.schedule, '节目单', () {
                        setState(() {
                          isScheduleMode = !isScheduleMode;
                          _showRightMenu = false;
                        });
                      }),
                      _buildMenuItem(Icons.list, '列表订阅', () {
                        _showAddSubscriptionDialog();
                        setState(() => _showRightMenu = false);
                      }),
                      _buildMenuItem(Icons.tv, 'EPG订阅', () {
                        _showAddEpgDialog();
                        setState(() => _showRightMenu = false);
                      }),
                      _buildMenuItem(Icons.close, '关闭', () {
                        setState(() => _showRightMenu = false);
                      }),
                    ],
                  ),
                ),
              ),

            // 顶部工具栏（快捷按钮）
            Positioned(
              top: 0,
              right: 0,
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.schedule, color: Colors.white),
                    onPressed: () {
                      setState(() {
                        isScheduleMode = !isScheduleMode;
                        if (isScheduleMode) showOverlay = false;
                      });
                    },
                  ),
                  IconButton(
                    icon: Icon(Icons.edit, color: Colors.white),
                    onPressed: () => setState(() => isEditMode = !isEditMode),
                  ),
                  IconButton(
                    icon: Icon(Icons.settings, color: Colors.white),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => SettingsScreen()),
                    ),
                  ),
                ],
              ),
            ),

            // 编辑模式信息
            if (isEditMode)
              Positioned(
                top: 50,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black.withOpacity(0.6),
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('订阅 ${(subWeight*100).toInt()}%', style: TextStyle(color: Colors.white, fontSize: 12)),
                      SizedBox(width: 16),
                      Text('分组 ${(groupWeight*100).toInt()}%', style: TextStyle(color: Colors.white, fontSize: 12)),
                      SizedBox(width: 16),
                      Text('频道 ${(channelWeight*100).toInt()}%', style: TextStyle(color: Colors.white, fontSize: 12)),
                      if (isScheduleMode) ...[
                        SizedBox(width: 16),
                        Text('节目单左 ${(scheduleLeftWeight*100).toInt()}%', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                      SizedBox(width: 16),
                      ElevatedButton(
                        onPressed: () => setState(() => isEditMode = false),
                        child: Text('退出编辑', style: TextStyle(fontSize: 12)),
                        style: ElevatedButton.styleFrom(padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2)),
                      ),
                    ],
                  ),
                ),
              ),

            // 网速显示
            if (currentSpeed > 0)
              Positioned(
                top: 95,
                left: 10,
                child: Container(
                  color: Colors.black54,
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Text(
                    '${currentSpeed.toStringAsFixed(1)} KB/s',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // 订阅列表
  Widget _buildSubscriptionList() {
    final settings = Provider.of<SettingsService>(context);
    final subs = settings.subscriptions;
    if (subs.isEmpty) {
      return Center(
        child: Text('无订阅', style: TextStyle(color: Colors.white70, fontSize: 12)),
      );
    }
    return Container(
      color: Colors.transparent,
      child: ListView.builder(
        itemCount: subs.length,
        itemBuilder: (context, index) {
          final sub = subs[index];
          final isSelected = sub.selected;
          return ListTile(
            title: Text(
              sub.name,
              style: TextStyle(color: isSelected ? Colors.yellow : Colors.white, fontSize: 12),
            ),
            onTap: () {
              settings.toggleSelected(sub);
              _reloadData();
            },
          );
        },
      ),
    );
  }

  // 拖拽条
  Widget _buildDragBar({required Function(double delta) onDrag, required bool isEditMode}) {
    return GestureDetector(
      onHorizontalDragUpdate: (details) {
        if (!isEditMode) return;
        final delta = details.delta.dx / MediaQuery.of(context).size.width;
        onDrag(delta);
      },
      child: Container(
        width: isEditMode ? 6 : 2,
        color: isEditMode ? Colors.yellow : Colors.transparent,
      ),
    );
  }

  // 菜单项
  Widget _buildMenuItem(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 24),
            SizedBox(height: 4),
            Text(label, style: TextStyle(color: Colors.white, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  // 列表订阅对话框
  void _showAddSubscriptionDialog() {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('添加列表订阅'),
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
                settings.addSubscription(Subscription(name: name, url: url, selected: true));
                _reloadData();
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已添加订阅: $name')));
              }
            },
            child: Text('添加'),
          ),
        ],
      ),
    );
  }

  // EPG订阅对话框
  void _showAddEpgDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('添加EPG订阅'),
        content: TextField(controller: ctrl, decoration: InputDecoration(labelText: 'EPG URL (XMLTV)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('取消')),
          TextButton(
            onPressed: () async {
              final url = ctrl.text.trim();
              if (url.isNotEmpty) {
                final config = await ConfigService.getConfig();
                final inner = config['Configuration'] as Map<String, dynamic>?;
                if (inner != null) {
                  inner['EPG_URLS'] = url;
                  await ConfigService.saveConfig({'Configuration': inner});
                  _loadEpgInBackground();
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('EPG已更新')));
                }
              }
            },
            child: Text('添加'),
          ),
        ],
      ),
    );
  }

  // ===== 数据加载（与之前相同） =====
  Future<void> _init() async {
    await _loadSavedSubscriptions();
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (settings.subscriptions.isEmpty) {
      await _addDefaultSubscription();
    }
    await _loadInitialSource();
    _checkSubscriptions();
    setState(() {
      isLoading = false;
    });
    LogService.write('初始化完成');
    _loadEpgInBackground();
  }

  Future<void> _loadSavedSubscriptions() async => Future.delayed(Duration.zero);

  Future<void> _addDefaultSubscription() async {
    try {
      LogService.write('尝试从配置添加默认订阅源');
      final config = await ConfigService.getConfig();
      final inner = config['Configuration'] as Map<String, dynamic>?;
      final liveUrl = inner?['LIVE_URLS'] as String?;
      if (liveUrl != null && liveUrl.isNotEmpty) {
        String name = '默认源';
        String url = liveUrl;
        if (liveUrl.contains(r'$')) {
          final parts = liveUrl.split(r'$');
          if (parts.length == 2) {
            url = parts[0].trim();
            name = parts[1].trim();
          }
        }
        final settings = Provider.of<SettingsService>(context, listen: false);
        settings.addSubscription(Subscription(name: name, url: url, selected: true));
        LogService.write('自动添加默认订阅源: $name -> $url');
      }
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  }

  Future<void> _loadEpgInBackground() async {
    try {
      LogService.write('后台加载 EPG 开始');
      final config = await ConfigService.getConfig();
      final inner = config['Configuration'] as Map<String, dynamic>?;
      final epgUrlRaw = inner?['EPG_URLS'] as String?;
      if (epgUrlRaw != null && epgUrlRaw.isNotEmpty) {
        String epgUrl = epgUrlRaw;
        if (epgUrlRaw.contains(r'$')) {
          epgUrl = epgUrlRaw.split(r'$')[0].trim();
        }
        LogService.write('EPG URL: $epgUrl');
        final map = await EpgParser.loadAllEpg(epgUrl).timeout(
          Duration(seconds: 30),
          onTimeout: () {
            LogService.write('EPG 加载超时');
            return {};
          },
        );
        setState(() {
          epgMap = map;
        });
        LogService.write('EPG加载成功，频道数: ${map.length}');
      }
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  }

  Future<void> _reloadData() async {
    LogService.write('刷新数据');
    setState(() {
      isLoading = true;
    });
    await _loadInitialSource();
    _checkSubscriptions();
    setState(() {
      isLoading = false;
    });
  }

  void _checkSubscriptions() {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final hasSelected = settings.subscriptions.any((s) => s.selected);
    setState(() {
      _hasSubscriptions = hasSelected || channels.isNotEmpty;
    });
    if (!_hasSubscriptions) {
      _showNoSourceDialog();
    }
  }

  void _showNoSourceDialog() {
    LogService.write('无订阅源，显示提示对话框');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: Text('提示'),
          content: Text('当前没有可用的订阅源，请先添加订阅源。'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => SettingsScreen()),
                );
              },
              child: Text('去设置'),
            ),
            TextButton(
              onPressed: () => exit(0),
              child: Text('退出'),
            ),
          ],
        ),
      );
    });
  }

  Future<void> _loadInitialSource() async {
    try {
      LogService.write('开始加载订阅源');
      final settings = Provider.of<SettingsService>(context, listen: false);
      final selected = settings.subscriptions.where((s) => s.selected).toList();
      if (selected.isEmpty) {
        LogService.write('没有选中的订阅源');
        return;
      }
      final url = selected.first.url;
      LogService.write('订阅源 URL: $url');
      final groupMap = await PlaylistParser.parseFromUrl(url);
      setState(() {
        groups = groupMap.keys.toList();
        if (groups.isNotEmpty) {
          currentGroup = groups.first;
          channels = groupMap[currentGroup]!;
          if (channels.isNotEmpty) currentChannel = channels.first;
        }
      });
      LogService.write('订阅源加载成功，分组数: ${groups.length}，频道数: ${channels.length}');
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  }

  Future<void> _loadGroup(String group) async {
    try {
      LogService.write('切换到分组: $group');
      final settings = Provider.of<SettingsService>(context, listen: false);
      final selected = settings.subscriptions.where((s) => s.selected).toList();
      if (selected.isNotEmpty) {
        final url = selected.first.url;
        final groupMap = await PlaylistParser.parseFromUrl(url);
        setState(() {
          groups = groupMap.keys.toList();
          if (groups.isNotEmpty) {
            currentGroup = group;
            channels = groupMap[group] ?? [];
            if (channels.isNotEmpty && currentChannel == null) {
              currentChannel = channels.first;
            }
          }
        });
        LogService.write('分组加载成功，频道数: ${channels.length}');
      }
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  }
}
