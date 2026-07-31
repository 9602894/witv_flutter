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
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // ---------- 数据 ----------
  List<Channel> channels = [];
  List<String> groups = [];
  Channel? currentChannel;
  String? currentGroup;
  String? currentSubName;

  // ---------- 窗口状态 ----------
  bool showChannelList = false;
  bool isScheduleMode = false;
  bool _showEpgInfo = false;
  bool isEditMode = false;
  bool _showRightMenu = false;

  // ---------- 宽度控制 ----------
  // 频道列表模式（订阅源、分组、频道）
  double subWeight = 0.20;
  double groupWeight = 0.20;
  double channelWeight = 0.60;

  // 节目单模式（分组、频道、节目单）
  double scheduleGroupWeight = 0.25;
  double scheduleChannelWeight = 0.35;
  double scheduleWeight = 0.40;

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
        if (_showEpgInfo) {
          setState(() => _showEpgInfo = false);
          return false;
        }
        if (isScheduleMode) {
          setState(() => isScheduleMode = false);
          return false;
        }
        if (showChannelList) {
          setState(() => showChannelList = false);
          return false;
        }
        if (_showRightMenu) {
          setState(() => _showRightMenu = false);
          return false;
        }
        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text('提示'),
            content: Text('确定要退出应用吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('确定'),
              ),
            ],
          ),
        );
        if (shouldExit == true) exit(0);
        return false;
      },
      child: Scaffold(
        body: Stack(
          children: [
            // ---------- 播放器 ----------
            if (currentChannel != null)
              PlayerWidget(
                url: currentChannel!.url,
                onError: () => LogService.write('播放器错误回调'),
                onSpeedUpdate: (speed) => setState(() => currentSpeed = speed),
              ),

            // ---------- 左侧点击区域（显示/隐藏频道列表） ----------
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 40,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  LogService.write('左侧点击事件触发');
                  setState(() {
                    if (isScheduleMode) {
                      isScheduleMode = false;
                      showChannelList = true;
                    } else {
                      showChannelList = !showChannelList;
                    }
                    if (showChannelList) {
                      _showRightMenu = false;
                      _showEpgInfo = false;
                    }
                  });
                },
                child: Container(color: Colors.transparent),
              ),
            ),

            // ---------- 频道列表模式（showChannelList && !isScheduleMode） ----------
            if (showChannelList && !isScheduleMode)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: MediaQuery.of(context).size.width * 0.7,
                child: Container(
                  color: Colors.transparent,
                  child: Row(
                    children: [
                      // 第一列：订阅源
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
                      // 第二列：分组
                      Expanded(
                        flex: (groupWeight * 100).toInt(),
                        child: _buildGroupList(),
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
                      // 第三列：频道列表 + 节目单按钮（竖排）
                      Expanded(
                        flex: (channelWeight * 100).toInt(),
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: ChannelList(
                                channels: channels,
                                selectedChannel: currentChannel,
                                onSelect: (ch) {
                                  LogService.write('选择频道: ${ch.name}');
                                  setState(() {
                                    currentChannel = ch;
                                    _showEpgInfo = true;
                                  });
                                  Provider.of<SettingsService>(context, listen: false)
                                      .saveLastChannel(ch.name);
                                },
                                epgMap: epgMap,
                                showChannelNumber: false,
                                showLogo: true,
                              ),
                            ),
                            // 竖排“节目单”按钮（置于频道列表右侧，稍微靠左）
                            Positioned(
                              right: 4, // 靠右但留出间距
                              top: 0,
                              bottom: 0,
                              child: GestureDetector(
                                onTap: () {
                                  setState(() {
                                    isScheduleMode = true;
                                    showChannelList = false;
                                  });
                                },
                                child: Container(
                                  width: 26,
                                  color: Colors.transparent,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text('节', style: TextStyle(color: Colors.white, fontSize: 13)),
                                      Text('目', style: TextStyle(color: Colors.white, fontSize: 13)),
                                      Text('单', style: TextStyle(color: Colors.white, fontSize: 13)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // ---------- 节目单模式（三列：分组、频道、节目单） ----------
            if (isScheduleMode)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: MediaQuery.of(context).size.width * 0.7,
                child: Container(
                  color: Colors.transparent,
                  child: Row(
                    children: [
                      // 第一列：分组列表
                      Expanded(
                        flex: (scheduleGroupWeight * 100).toInt(),
                        child: _buildGroupList(),
                      ),
                      _buildDragBar(
                        onDrag: (delta) {
                          setState(() {
                            double newGroup = scheduleGroupWeight + delta;
                            double newChannel = scheduleChannelWeight - delta;
                            if (newGroup < 0.05) newGroup = 0.05;
                            if (newChannel < 0.05) newChannel = 0.05;
                            scheduleGroupWeight = newGroup;
                            scheduleChannelWeight = newChannel;
                            scheduleWeight = 1 - newGroup - newChannel;
                            if (scheduleWeight < 0.05) {
                              scheduleWeight = 0.05;
                              double total = newGroup + newChannel;
                              scheduleGroupWeight = scheduleGroupWeight / total * 0.95;
                              scheduleChannelWeight = scheduleChannelWeight / total * 0.95;
                            }
                          });
                        },
                        isEditMode: isEditMode,
                      ),
                      // 第二列：频道列表
                      Expanded(
                        flex: (scheduleChannelWeight * 100).toInt(),
                        child: ChannelList(
                          channels: channels,
                          selectedChannel: currentChannel,
                          onSelect: (ch) {
                            LogService.write('选择频道: ${ch.name}');
                            setState(() {
                              currentChannel = ch;
                              _showEpgInfo = true;
                            });
                            Provider.of<SettingsService>(context, listen: false)
                                .saveLastChannel(ch.name);
                          },
                          epgMap: epgMap,
                          showChannelNumber: false,
                          showLogo: true,
                        ),
                      ),
                      _buildDragBar(
                        onDrag: (delta) {
                          setState(() {
                            double newChannel = scheduleChannelWeight + delta;
                            double newSchedule = scheduleWeight - delta;
                            if (newChannel < 0.05) newChannel = 0.05;
                            if (newSchedule < 0.05) newSchedule = 0.05;
                            scheduleChannelWeight = newChannel;
                            scheduleWeight = newSchedule;
                            scheduleGroupWeight = 1 - newChannel - newSchedule;
                            if (scheduleGroupWeight < 0.05) {
                              scheduleGroupWeight = 0.05;
                              double total = newChannel + newSchedule;
                              scheduleChannelWeight = scheduleChannelWeight / total * 0.95;
                              scheduleWeight = scheduleWeight / total * 0.95;
                            }
                          });
                        },
                        isEditMode: isEditMode,
                      ),
                      // 第三列：节目单（隐藏自身的左侧频道列表）
                      Expanded(
                        flex: (scheduleWeight * 100).toInt(),
                        child: ScheduleView(
                          channels: channels,
                          selectedChannel: currentChannel,
                          epgMap: epgMap,
                          onSelectChannel: (ch) {
                            setState(() {
                              currentChannel = ch;
                              _showEpgInfo = true;
                              Provider.of<SettingsService>(context, listen: false)
                                  .saveLastChannel(ch.name);
                            });
                          },
                          leftWeight: 0.3,
                          rightWeight: 0.7,
                          onLeftWeightChanged: (_) {},
                          isEditMode: isEditMode,
                          showLeft: false, // 关键：隐藏内置频道列表
                        ),
                      ),
                      // 返回按钮（左上角）
                      Positioned(
                        top: 8,
                        left: 8,
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              isScheduleMode = false;
                              showChannelList = true;
                            });
                          },
                          child: Container(
                            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.arrow_back, color: Colors.white, size: 16),
                                SizedBox(width: 4),
                                Text('返回', style: TextStyle(color: Colors.white, fontSize: 12)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // ---------- EPG 信息浮窗 ----------
            if (_showEpgInfo && currentChannel != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: MediaQuery.of(context).size.height * 0.15,
                child: Center(
                  child: Container(
                    constraints: BoxConstraints(maxWidth: 500),
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          currentChannel!.name,
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, shadows: [
                            Shadow(offset: Offset(1,1), blurRadius: 4, color: Colors.black87)
                          ]),
                        ),
                        SizedBox(height: 8),
                        if (EpgParser.getProgramsForChannel(currentChannel!.name).isNotEmpty) ...[
                          _buildEpgItem(EpgParser.getProgramsForChannel(currentChannel!.name)[0], '当前节目'),
                          SizedBox(height: 4),
                          if (EpgParser.getProgramsForChannel(currentChannel!.name).length > 1)
                            _buildEpgItem(EpgParser.getProgramsForChannel(currentChannel!.name)[1], '下一节目'),
                        ] else
                          Text('暂无EPG信息', style: TextStyle(color: Colors.white70)),
                      ],
                    ),
                  ),
                ),
              ),

            // ---------- 右侧菜单 ----------
            if (_showRightMenu)
              Positioned(
                top: 0,
                right: 0,
                bottom: 0,
                width: MediaQuery.of(context).size.width * 0.12,
                child: Container(
                  color: Colors.transparent,
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

            // ---------- 顶部工具栏 ----------
            Positioned(
              top: 0,
              right: 0,
              child: Row(
                children: [
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

            // ---------- 编辑模式信息 ----------
            if (isEditMode)
              Positioned(
                top: 50,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black54,
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (!isScheduleMode) ...[
                        Text('订阅 ${(subWeight*100).toInt()}%', style: TextStyle(color: Colors.white, fontSize: 12)),
                        SizedBox(width: 16),
                        Text('分组 ${(groupWeight*100).toInt()}%', style: TextStyle(color: Colors.white, fontSize: 12)),
                        SizedBox(width: 16),
                        Text('频道 ${(channelWeight*100).toInt()}%', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ] else ...[
                        Text('分组 ${(scheduleGroupWeight*100).toInt()}%', style: TextStyle(color: Colors.white, fontSize: 12)),
                        SizedBox(width: 16),
                        Text('频道 ${(scheduleChannelWeight*100).toInt()}%', style: TextStyle(color: Colors.white, fontSize: 12)),
                        SizedBox(width: 16),
                        Text('节目单 ${(scheduleWeight*100).toInt()}%', style: TextStyle(color: Colors.white, fontSize: 12)),
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

            // ---------- 点击空白关闭 EPG ----------
            if (_showEpgInfo)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => setState(() => _showEpgInfo = false),
                  child: Container(color: Colors.transparent),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ========== 构建订阅源列表 ==========
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
        itemCount: subs.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return ListTile(
              leading: Icon(Icons.favorite, color: Colors.yellow, size: 16),
              title: Text(
                '我的收藏',
                style: TextStyle(
                  color: Colors.yellow,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              onTap: () {
                // 收藏功能待实现
              },
            );
          }
          final sub = subs[index - 1];
          final isSelected = sub.selected;
          return ListTile(
            title: Text(
              sub.name,
              style: TextStyle(
                color: isSelected ? Colors.yellow : Colors.white,
                fontSize: 13,
              ),
            ),
            onTap: () {
              LogService.write('切换订阅源: ${sub.name}');
              settings.toggleSelected(sub);
              _loadSubscriptionData(sub);
            },
          );
        },
      ),
    );
  }

  // ========== 加载订阅源数据 ==========
  Future<void> _loadSubscriptionData(Subscription sub) async {
    try {
      LogService.write('加载订阅源数据: ${sub.name}');
      final url = sub.url;
      final cacheFile = await PlaylistParser.getCacheFile(url, sub.name);
      Map<String, List<Channel>> groupMap;
      if (await cacheFile.exists()) {
        final content = await cacheFile.readAsString();
        groupMap = PlaylistParser.parseFromString(content);
      } else {
        groupMap = await PlaylistParser.parseFromUrl(url);
        await PlaylistParser.saveCache(groupMap, url, sub.name);
      }

      setState(() {
        groups = groupMap.keys.toList();
        if (groups.isNotEmpty) {
          if (currentGroup == null || !groups.contains(currentGroup)) {
            currentGroup = groups.first;
          }
          channels = groupMap[currentGroup]!;
          if (channels.isNotEmpty) {
            final lastChannel = Provider.of<SettingsService>(context, listen: false).getLastChannel();
            if (lastChannel != null) {
              final found = channels.firstWhere((ch) => ch.name == lastChannel, orElse: () => channels.first);
              currentChannel = found;
            } else {
              currentChannel = channels.first;
            }
            _showEpgInfo = true;
          }
        }
        currentSubName = sub.name;
      });
      LogService.write('订阅源加载完成，分组数: ${groups.length}，频道数: ${channels.length}');
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  }

  // ========== 分组列表 ==========
  Widget _buildGroupList() {
    return Container(
      color: Colors.transparent,
      child: ListView.builder(
        itemCount: groups.length,
        itemBuilder: (context, index) {
          final group = groups[index];
          final isSelected = group == currentGroup;
          final displayName = group.replaceAll(',', '');
          return ListTile(
            title: Text(
              displayName,
              style: TextStyle(
                color: isSelected ? Colors.yellow : Colors.white,
                fontSize: 13,
              ),
            ),
            onTap: () {
              LogService.write('切换到分组: $group');
              setState(() {
                currentGroup = group;
                // 更新频道列表
                final settings = Provider.of<SettingsService>(context, listen: false);
                final selected = settings.subscriptions.where((s) => s.selected).toList();
                if (selected.isNotEmpty) {
                  final sub = selected.first;
                  _loadSubscriptionData(sub);
                }
              });
            },
          );
        },
      ),
    );
  }

  // ========== 拖拽条 ==========
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

  // ========== 菜单项 ==========
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

  // ========== EPG 信息项 ==========
  Widget _buildEpgItem(EpgProgram prog, String label) {
    final timeStr = '${prog.start.hour.toString().padLeft(2, '0')}:${prog.start.minute.toString().padLeft(2, '0')}-${prog.end.hour.toString().padLeft(2, '0')}:${prog.end.minute.toString().padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: $timeStr ${prog.title}',
          style: TextStyle(color: Colors.white, fontSize: 14, shadows: [
            Shadow(offset: Offset(1,1), blurRadius: 4, color: Colors.black87)
          ]),
        ),
        if (prog.desc != null && prog.desc!.isNotEmpty)
          Text(
            prog.desc!,
            style: TextStyle(color: Colors.white70, fontSize: 12, shadows: [
              Shadow(offset: Offset(1,1), blurRadius: 4, color: Colors.black87)
            ]),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }

  // ========== 添加订阅源对话框（去重） ==========
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
                // 去重：检查是否已存在相同URL或名称
                final exists = settings.subscriptions.any((s) => s.url == url || s.name == name);
                if (exists) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('订阅源已存在，请勿重复添加')));
                  return;
                }
                settings.addSubscription(Subscription(name: name, url: url, selected: true));
                _loadSubscriptionData(Subscription(name: name, url: url, selected: true));
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

  // ===== 数据加载 =====
  Future<void> _init() async {
    await _loadSavedSubscriptions();
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (settings.subscriptions.isEmpty) {
      await _addDefaultSubscription();
    }
    final selected = settings.subscriptions.where((s) => s.selected).toList();
    if (selected.isNotEmpty) {
      await _loadSubscriptionData(selected.first);
    }
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
        // 去重：检查是否已存在相同URL
        final exists = settings.subscriptions.any((s) => s.url == url);
        if (!exists) {
          settings.addSubscription(Subscription(name: name, url: url, selected: true));
          LogService.write('自动添加默认订阅源: $name -> $url');
        } else {
          LogService.write('默认订阅源已存在，跳过添加');
        }
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
          Duration(seconds: 60),
          onTimeout: () {
            LogService.write('EPG 加载超时');
            return {};
          },
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              epgMap = map;
            });
            LogService.write('EPG加载成功，频道数: ${map.length}');
          }
        });
      }
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
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
}
