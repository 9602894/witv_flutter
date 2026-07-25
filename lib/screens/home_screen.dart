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
import '../models/subscription.dart';   // 添加这一行
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

  @override
  void initState() {
    super.initState();
    LogService.write('主页初始化');
    _init();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (settings.needsRefresh) {
      settings.clearRefreshFlag();
      _reloadData();
    }
  }

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
    LogService.write('主页初始化完成');
    _loadEpgInBackground();
  }

  Future<void> _loadSavedSubscriptions() async {
    await Future.delayed(Duration.zero);
  }

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
        final sub = Subscription(name: name, url: url, selected: true);
        settings.addSubscription(sub);
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
        LogService.write('EPG URL (纯): $epgUrl');
        final map = await EpgParser.loadAllEpg(epgUrl).timeout(
          Duration(seconds: 30),
          onTimeout: () {
            LogService.write('EPG 加载超时，跳过');
            return {};
          },
        );
        setState(() {
          epgMap = map;
        });
        LogService.write('EPG加载成功，频道数: ${map.length}');
      } else {
        LogService.write('EPG URL为空，跳过');
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

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          if (currentChannel != null)
            PlayerWidget(
              url: currentChannel!.url,
              onError: () {
                LogService.write('播放器错误回调');
              },
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
                            _loadGroup(group);
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
          if (isScheduleMode)
            Positioned.fill(
              child: Container(
                color: Colors.black87,
                child: ScheduleView(
                  channels: channels,
                  selectedChannel: currentChannel,
                  epgMap: epgMap,
                  onSelectChannel: (ch) => setState(() => currentChannel = ch),
                ),
              ),
            ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 100,
            child: GestureDetector(
              onTap: () {
                if (currentChannel != null) {
                  final programs = EpgParser.getProgramsForChannel(currentChannel!.name);
                  showInfoPopup(context, currentChannel!, programs, currentSpeed);
                }
              },
              child: Container(color: Colors.transparent),
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
          EditToolbar(
            isEditMode: isEditMode,
            onExit: () => setState(() => isEditMode = false),
            subWeight: subWeight,
            onSubWeightChange: (v) => setState(() {
              subWeight = v;
              groupWeight = (1 - subWeight) * 0.5;
              channelWeight = 1 - subWeight - groupWeight;
            }),
            groupWeight: groupWeight,
            onGroupWeightChange: (v) => setState(() {
              groupWeight = v;
              subWeight = (1 - groupWeight) * 0.5;
              channelWeight = 1 - subWeight - groupWeight;
            }),
          ),
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
