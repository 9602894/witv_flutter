import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
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

  @override
  void initState() {
    super.initState();
    _loadInitialSource();
    _loadEpg();
  }

  Future<void> _loadInitialSource() async {
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
    }
  }

  Future<void> _loadEpg() async {
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (settings.epgUrl != null) {
      final map = await EpgParser.loadAllEpg(settings.epgUrl!);
      setState(() {
        epgMap = map;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 播放器
          if (currentChannel != null)
            PlayerWidget(
              url: currentChannel!.url,
              onError: (e) => print('播放错误: $e'),
              onSpeedUpdate: (speed) => setState(() => currentSpeed = speed),
            ),
          // 叠加层（频道列表等）
          if (showOverlay && !isScheduleMode)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                child: Row(
                  children: [
                    // 订阅源列表（简化为一个固定订阅源，此处省略订阅切换UI）
                    // 直接显示分组列表
                    Expanded(
                      flex: (subWeight * 10).toInt(),
                      child: GroupList(
                        groups: groups,
                        selectedGroup: currentGroup,
                        onSelect: (group) {
                          setState(() {
                            currentGroup = group;
                            final map = Provider.of<SettingsService>(context, listen: false);
                            // 重新加载该分组频道（简单处理：从已有数据中过滤）
                            // 实际应缓存所有频道数据，这里简化
                            // 我们重新解析整个源
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
          // 节目单模式
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
          // 信息弹窗触发（点击屏幕下半部分）
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
          // 工具栏
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
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen())),
                ),
              ],
            ),
          ),
          // 编辑工具栏
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
          // 左上角显示网速（可选）
          if (currentSpeed > 0)
            Positioned(
              top: 50,
              left: 10,
              child: Text(
                '${currentSpeed.toStringAsFixed(1)} KB/s',
                style: TextStyle(color: Colors.white, fontSize: 12, background: Paint()..color = Colors.black54),
              ),
            ),
        ],
      ),
    );
  }

  void _loadGroup(String group) {
    // 重新解析并加载该分组（简单实现：重新解析全部）
    // 实际可缓存完整数据
    _loadInitialSource();
  }
}
