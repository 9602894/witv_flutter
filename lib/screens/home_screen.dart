import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:io' show exit;
import '../services/settings_service.dart';
import '../services/config_service.dart';
import '../services/playlist_parser.dart';
import '../services/epg_parser.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
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
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    // 在 initState 中不加载，等到 didChangeDependencies
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      _init();
    }
    // 监听 SettingsService 变化，当订阅列表变化时重新加载
    Provider.of<SettingsService>(context, listen: true);
  }

  Future<void> _init() async {
    await _loadConfigAndEpg();
    await _loadInitialSource();
    final settings = Provider.of<SettingsService>(context, listen: false);
    final hasSelected = settings.subscriptions.any((s) => s.selected);
    setState(() {
      isLoading = false;
      _hasSubscriptions = hasSelected || channels.isNotEmpty;
    });
    if (!_hasSubscriptions) {
      _showNoSourceDialog();
    }
  }

  void _showNoSourceDialog() {
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

  Future<void> _loadConfigAndEpg() async {
    try {
      final config = await ConfigService.getConfig();
      final epgUrl = config['EPG_URLS'] as String?;
      if (epgUrl != null && epgUrl.isNotEmpty) {
        final map = await EpgParser.loadAllEpg(epgUrl);
        setState(() {
          epgMap = map;
        });
      }
    } catch (e) {
      print('加载EPG失败: $e');
    }
  }

  Future<void> _loadInitialSource() async {
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final selected = settings.subscriptions.where((s) => s.selected).toList();
      if (selected.isNotEmpty) {
        final url = selected.first.url;
        final groupMap = await PlaylistParser.parseFromUrl(url);
        setState(() {
          groups = groupMap.keys.toList();
          if (groups.isNotEmpty) {
            currentGroup = groups.first;
            channels = groupMap[currentGroup]!;
            if (channels.isNotEmpty) currentChannel = channels.first;
          }
        });
      } else {
        // 无选中订阅，清空频道列表
        setState(() {
          channels = [];
          groups = [];
          currentChannel = null;
          currentGroup = null;
        });
      }
    } catch (e) {
      print('加载源失败: $e');
    }
  }

  Future<void> _loadGroup(String group) async {
    try {
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
      }
    } catch (e) {
      print('加载分组失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 监听 SettingsService 变化，并在变化时重新加载源（如果当前没有频道且已加载完成）
    final settings = Provider.of<SettingsService>(context);
    // 当订阅列表变化且页面已加载完成时，重新加载
    // 但为了不频繁刷新，我们可以在订阅变化时设置一个标志，但简单起见，每次 build 时检查是否有选中订阅但频道为空
    if (!isLoading && settings.subscriptions.any((s) => s.selected) && channels.isEmpty) {
      // 延迟一帧执行，避免无限循环
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadInitialSource();
      });
    }

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
              onError: () => print('播放错误'),
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
