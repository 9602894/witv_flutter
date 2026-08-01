import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
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
  double subWeight = 0.2;
  double groupWeight = 0.2;
  double channelWeight = 0.6;

  double scheduleGroupWeight = 0.25;
  double scheduleChannelWeight = 0.35;
  double scheduleWeight = 0.4;

  // ---------- 按钮偏移 ----------
  Offset scheduleModeButtonOffset = Offset(714.8865763346365, 7.9911295572917425);
  Offset channelListButtonOffset = Offset(-133.9163004557305, -4.6614786783854925);

  double _scheduleButtonInitTop = 0;
  double _channelButtonInitTop = 0;

  Map<String, List<EpgProgram>> epgMap = {};
  double currentSpeed = 0;
  bool isLoading = true;
  bool _hasSubscriptions = false;

  Map<String, List<Channel>>? _fullGroupMap;
  Timer? _epgUpdateTimer;

  late File _layoutConfigFile;

  // ========== 工具函数：直接使用当前北京时间（设备时间） ==========
  /// 获取当前时间（设备时区即为北京时间）
  DateTime _getNow() => DateTime.now();

  /// 格式化时间为 HH:mm
  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  /// 获取当前正在播放的节目
  EpgProgram? _getCurrentProgram(List<EpgProgram> programs) {
    final now = _getNow();
    for (var p in programs) {
      if (p.start.isBefore(now) && p.end.isAfter(now)) {
        return p;
      }
    }
    return null;
  }

  /// 获取下一个节目
  EpgProgram? _getNextProgram(List<EpgProgram> programs) {
    final now = _getNow();
    EpgProgram? current = _getCurrentProgram(programs);
    if (current == null) {
      for (var p in programs) {
        if (p.start.isAfter(now)) return p;
      }
      return null;
    }
    int index = programs.indexOf(current);
    if (index >= 0 && index < programs.length - 1) {
      return programs[index + 1];
    }
    return null;
  }

  // ========== 生命周期 ==========
  @override
  void initState() {
    super.initState();
    LogService.write('主页初始化');
    _initLayoutConfigFile();
    _loadLayoutConfig();
    _init();
    _initEpgScheduler();
  }

  // ========== 布局配置 ==========
  Future<void> _initLayoutConfigFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _layoutConfigFile = File('${dir.path}/layout_config.json');
      LogService.write('配置文件路径: ${_layoutConfigFile.path}');
      if (!await _layoutConfigFile.exists()) {
        await _saveLayoutConfig();
        LogService.write('创建默认配置文件');
      }
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  }

  Future<void> _loadLayoutConfig() async {
    try {
      if (await _layoutConfigFile.exists()) {
        final content = await _layoutConfigFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        subWeight = json['subWeight']?.toDouble() ?? subWeight;
        groupWeight = json['groupWeight']?.toDouble() ?? groupWeight;
        channelWeight = json['channelWeight']?.toDouble() ?? channelWeight;
        scheduleGroupWeight = json['scheduleGroupWeight']?.toDouble() ?? scheduleGroupWeight;
        scheduleChannelWeight = json['scheduleChannelWeight']?.toDouble() ?? scheduleChannelWeight;
        scheduleWeight = json['scheduleWeight']?.toDouble() ?? scheduleWeight;
        scheduleModeButtonOffset = Offset(
          json['scheduleModeButtonDx']?.toDouble() ?? scheduleModeButtonOffset.dx,
          json['scheduleModeButtonDy']?.toDouble() ?? scheduleModeButtonOffset.dy,
        );
        channelListButtonOffset = Offset(
          json['channelListButtonDx']?.toDouble() ?? channelListButtonOffset.dx,
          json['channelListButtonDy']?.toDouble() ?? channelListButtonOffset.dy,
        );
        LogService.write('布局配置加载成功');
      }
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  }

  Future<void> _saveLayoutConfig() async {
    try {
      final json = {
        'subWeight': subWeight,
        'groupWeight': groupWeight,
        'channelWeight': channelWeight,
        'scheduleGroupWeight': scheduleGroupWeight,
        'scheduleChannelWeight': scheduleChannelWeight,
        'scheduleWeight': scheduleWeight,
        'scheduleModeButtonDx': scheduleModeButtonOffset.dx,
        'scheduleModeButtonDy': scheduleModeButtonOffset.dy,
        'channelListButtonDx': channelListButtonOffset.dx,
        'channelListButtonDy': channelListButtonOffset.dy,
      };
      await _layoutConfigFile.writeAsString(jsonEncode(json));
      LogService.write('布局配置已保存');
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  }

  void _exitEditMode() {
    setState(() {
      isEditMode = false;
    });
    _saveLayoutConfig();
  }

  @override
  void dispose() {
    _epgUpdateTimer?.cancel();
    _saveLayoutConfig();
    super.dispose();
  }

  // ========== EPG 更新调度 ==========
  void _initEpgScheduler() {
    _checkEpgUpdate();
    _epgUpdateTimer = Timer.periodic(Duration(hours: 6), (timer) {
      _checkEpgUpdate();
    });
  }

  Future<void> _checkEpgUpdate() async {
    try {
      final updated = await EpgParser.checkForUpdate();
      if (updated) {
        LogService.write('EPG 已更新，重新加载');
        await _loadAllEpg();
      }
    } catch (e) {
      LogService.write('EPG 更新检查失败: $e');
    }
  }

  Future<void> _loadAllEpg() async {
    try {
      final all = await EpgParser.getAllPrograms();
      setState(() {
        epgMap = all;
      });
      LogService.write('全量 EPG 加载完成，频道数: ${all.length}');
    } catch (e) {
      LogService.write('加载全量 EPG 失败: $e');
    }
  }

  Future<void> _loadEpgForChannel(Channel channel) async {
    try {
      final programs = await EpgParser.getProgramsForChannel(channel.name);
      setState(() {
        epgMap[channel.name] = programs;
      });
    } catch (e) {
      LogService.write('加载频道 EPG 失败: $e');
    }
  }

  // ========== 分组切换 ==========
  void _switchToGroup(String groupName) {
    if (_fullGroupMap == null) {
      LogService.write('错误：_fullGroupMap 为空，无法切换分组');
      return;
    }
    final groupChannels = _fullGroupMap![groupName];
    if (groupChannels == null) {
      LogService.write('分组 $groupName 不存在');
      return;
    }
    setState(() {
      currentGroup = groupName;
      channels = groupChannels;
    });
    LogService.write('切换到分组: $groupName，频道数: ${channels.length}');
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
        LogService.write('从缓存加载订阅源成功');
        _applyGroupMap(groupMap, sub.name);
        _updateSubscriptionInBackground(url, sub.name, groupMap);
      } else {
        groupMap = await PlaylistParser.parseFromUrl(url);
        await PlaylistParser.saveCache(groupMap, url, sub.name);
        _applyGroupMap(groupMap, sub.name);
      }
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  }

  Future<void> _updateSubscriptionInBackground(String url, String name, Map<String, List<Channel>> currentMap) async {
    try {
      LogService.write('后台静默更新订阅源: $name');
      final newMap = await PlaylistParser.parseFromUrl(url);
      if (newMap.keys.length != currentMap.keys.length ||
          newMap.values.expand((list) => list).length != currentMap.values.expand((list) => list).length) {
        await PlaylistParser.saveCache(newMap, url, name);
        _applyGroupMap(newMap, name);
        LogService.write('订阅源已更新');
      } else {
        LogService.write('订阅源无变化');
      }
    } catch (e) {
      LogService.write('后台更新订阅源失败: $e');
    }
  }

  void _applyGroupMap(Map<String, List<Channel>> groupMap, String subName) {
    _fullGroupMap = groupMap;
    setState(() {
      groups = groupMap.keys.toList();
      if (groups.isNotEmpty) {
        if (currentGroup == null || !groups.contains(currentGroup)) {
          currentGroup = groups.first;
        }
        final groupChannels = groupMap[currentGroup]!;
        channels = groupChannels;
        if (currentChannel == null && channels.isNotEmpty) {
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
      currentSubName = subName;
    });
    _loadAllEpg();
    LogService.write('分组数据应用完成，分组数: ${groups.length}，频道数: ${channels.length}');
  }

  // ========== 构建 UI ==========
  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    _scheduleButtonInitTop = (screenHeight - 80) / 2;
    _channelButtonInitTop = (screenHeight - 80) / 2;

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
              Positioned.fill(
                child: PlayerWidget(
                  url: currentChannel!.url,
                  onError: () => LogService.write('播放器错误回调'),
                  onSpeedUpdate: (speed) => setState(() => currentSpeed = speed),
                ),
              ),

            // ---------- 左侧点击区域 ----------
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

            // ---------- 频道列表模式 ----------
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
                                  _loadEpgForChannel(ch);
                                  Provider.of<SettingsService>(context, listen: false)
                                      .saveLastChannel(ch.name);
                                },
                                epgMap: epgMap,
                                showChannelNumber: false,
                                showLogo: true,
                              ),
                            ),
                            // 竖排“节目单”按钮
                            Positioned(
                              right: 20 - channelListButtonOffset.dx,
                              top: _channelButtonInitTop + channelListButtonOffset.dy,
                              child: GestureDetector(
                                onPanUpdate: (details) {
                                  if (!isEditMode) return;
                                  setState(() {
                                    channelListButtonOffset += details.delta;
                                  });
                                },
                                onTap: () {
                                  setState(() {
                                    isScheduleMode = true;
                                    showChannelList = false;
                                  });
                                },
                                child: Container(
                                  width: 26,
                                  height: 80,
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

            // ---------- 节目单模式（三列） ----------
            if (isScheduleMode)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: MediaQuery.of(context).size.width * 0.7,
                child: Stack(
                  children: [
                    Row(
                      children: [
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
                              _loadEpgForChannel(ch);
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
                              });
                              _loadEpgForChannel(ch);
                              Provider.of<SettingsService>(context, listen: false)
                                  .saveLastChannel(ch.name);
                            },
                            leftWeight: 0.3,
                            rightWeight: 0.7,
                            onLeftWeightChanged: (_) {},
                            isEditMode: isEditMode,
                            showLeft: false,
                          ),
                        ),
                      ],
                    ),
                    // “频道组”按钮
                    Positioned(
                      left: 8 + scheduleModeButtonOffset.dx,
                      top: _scheduleButtonInitTop + scheduleModeButtonOffset.dy,
                      child: GestureDetector(
                        onPanUpdate: (details) {
                          if (!isEditMode) return;
                          setState(() {
                            scheduleModeButtonOffset += details.delta;
                          });
                        },
                        onTap: () {
                          setState(() {
                            isScheduleMode = false;
                            showChannelList = true;
                          });
                        },
                        child: Container(
                          width: 26,
                          height: 80,
                          color: Colors.transparent,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('频', style: TextStyle(color: Colors.white, fontSize: 13)),
                              Text('道', style: TextStyle(color: Colors.white, fontSize: 13)),
                              Text('组', style: TextStyle(color: Colors.white, fontSize: 13)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // ---------- EPG 信息浮窗（动态筛选） ----------
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
                        _buildEpgProgramInfo(epgMap[currentChannel!.name] ?? []),
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
                        if (isEditMode) {
                          _exitEditMode();
                        } else {
                          setState(() => isEditMode = true);
                        }
                        setState(() => _showRightMenu = false);
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
                    onPressed: () {
                      if (isEditMode) {
                        _exitEditMode();
                      } else {
                        setState(() => isEditMode = true);
                      }
                    },
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
                        onPressed: _exitEditMode,
                        child: Text('退出编辑', style: TextStyle(fontSize: 12)),
                        style: ElevatedButton.styleFrom(padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2)),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ========== 构建 EPG 信息（浮窗内容） ==========
  Widget _buildEpgProgramInfo(List<EpgProgram> programs) {
    final current = _getCurrentProgram(programs);
    final next = _getNextProgram(programs);
    List<Widget> children = [];
    if (current != null) {
      children.add(_buildEpgItem(current, '当前节目'));
      children.add(SizedBox(height: 4));
    }
    if (next != null) {
      children.add(_buildEpgItem(next, '下一节目'));
    }
    if (children.isEmpty) {
      return Text('暂无节目信息', style: TextStyle(color: Colors.white70));
    }
    return Column(children: children);
  }

  // ========== EPG 信息项 ==========
  Widget _buildEpgItem(EpgProgram prog, String label) {
    final timeStr = '${_formatTime(prog.start)}-${_formatTime(prog.end)}';
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

  // ========== 订阅源列表 ==========
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
              onTap: () {},
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
              _switchToGroup(group);
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

  // ========== 添加订阅源对话框 ==========
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
                final exists = settings.subscriptions.any((s) => s.url == url || s.name == name);
                if (exists) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('订阅源已存在')));
                  return;
                }
                settings.addSubscription(Subscription(name: name, url: url, selected: true));
                _loadSubscriptionData(Subscription(name: name, url: url, selected: true));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已添加: $name')));
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
                  _checkEpgUpdate();
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
    } else {
      if (settings.subscriptions.isNotEmpty) {
        settings.toggleSelected(settings.subscriptions.first);
        await _loadSubscriptionData(settings.subscriptions.first);
      }
    }
    _checkSubscriptions();
    setState(() {
      isLoading = false;
    });
    LogService.write('初始化完成');
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
