import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
import '../widgets/edit_toolbar.dart';
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
  double subWeight = 0.2;
  double groupWeight = 0.2;
  double channelWeight = 0.6;
  Map<String, List<EpgProgram>> epgMap = {};
  double currentSpeed = 0;
  bool isLoading = true;
  bool _hasSubscriptions = false;
  String errorMessage = '';

  @override
  void initState() {
    super.initState();
    LogService.write('HomeScreen 初始化');
    _init();
  }

  Future<void> _init() async {
    try {
      LogService.write('开始初始化');
      // 强制显示界面
      setState(() {
        isLoading = false;
      });

      // 后台加载数据
      await _loadData();

      LogService.write('初始化完成');
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
      setState(() {
        errorMessage = e.toString();
        isLoading = false;
      });
    }
  }

  Future<void> _loadData() async {
    // 添加一个简单的延迟，让界面先显示
    await Future.delayed(Duration(milliseconds: 100));
    LogService.write('开始加载数据');

    // 从 SettingsService 获取订阅源
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (settings.subscriptions.isEmpty) {
      LogService.write('订阅源为空，尝试添加默认源');
      await _addDefaultSubscription();
    }

    // 加载选中的订阅源
    await _loadInitialSource();
    LogService.write('数据加载完成');
  }

  Future<void> _addDefaultSubscription() async {
    try {
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
        LogService.write('添加默认订阅源成功: $name -> $url');
      }
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
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
        _hasSubscriptions = true;
      });
      LogService.write('订阅源加载成功，分组数: ${groups.length}，频道数: ${channels.length}');
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
      setState(() {
        errorMessage = '加载订阅源失败: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 20),
              Text('加载中...', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      );
    }

    if (errorMessage.isNotEmpty) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error, color: Colors.red, size: 64),
              SizedBox(height: 20),
              Text('错误: $errorMessage', style: TextStyle(color: Colors.white)),
              SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    errorMessage = '';
                    isLoading = true;
                  });
                  _init();
                },
                child: Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    // 正常界面（如果频道为空，显示提示）
    if (channels.isEmpty) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('没有频道数据', style: TextStyle(color: Colors.white, fontSize: 20)),
              SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => SettingsScreen()),
                  );
                },
                child: Text('去设置添加订阅源'),
              ),
            ],
          ),
        ),
      );
    }

    // 正常主界面（简化版，只显示频道列表和播放器）
    return Scaffold(
      body: Stack(
        children: [
          if (currentChannel != null)
            PlayerWidget(
              url: currentChannel!.url,
              onError: () => LogService.write('播放器错误'),
              onSpeedUpdate: (speed) => setState(() => currentSpeed = speed),
            ),
          if (showOverlay && !isScheduleMode)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                child: Row(
                  children: [
                    Expanded(
                      flex: (subWeight * 10).toInt(),
                      child: GroupList(
                        groups: groups,
                        selectedGroup: currentGroup,
                        onSelect: (group) {
                          setState(() {
                            currentGroup = group;
                            // 简单切换：从组中取频道
                            final settings = Provider.of<SettingsService>(context, listen: false);
                            final selected = settings.subscriptions.where((s) => s.selected).toList();
                            if (selected.isNotEmpty) {
                              PlaylistParser.parseFromUrl(selected.first.url).then((groupMap) {
                                setState(() {
                                  channels = groupMap[group] ?? [];
                                  if (channels.isNotEmpty) currentChannel = channels.first;
                                });
                              });
                            }
                          });
                        },
                      ),
                    ),
                    VerticalDivider(thickness: 2, color: Colors.yellow, width: 2),
                    Expanded(
                      flex: (channelWeight * 10).toInt(),
                      child: ChannelList(
                        channels: channels,
                        selectedChannel: currentChannel,
                        onSelect: (ch) {
                          LogService.write('选择频道: ${ch.name}');
                          setState(() => currentChannel = ch);
                        },
                        epgMap: epgMap,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Positioned(
            top: 0,
            right: 0,
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.schedule, color: Colors.white),
                  onPressed: () => setState(() => isScheduleMode = !isScheduleMode),
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
          // 显示网速
          if (currentSpeed > 0)
            Positioned(
              top: 50,
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
    );
  }
}
