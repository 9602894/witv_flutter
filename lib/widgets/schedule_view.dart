import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import 'channel_list.dart';

class ScheduleView extends StatefulWidget {
  final List<Channel> channels;
  final Channel? selectedChannel;
  final Map<String, List<EpgProgram>> epgMap;
  final ValueChanged<Channel> onSelectChannel;
  final double leftWeight;
  final double rightWeight;
  final ValueChanged<double> onLeftWeightChanged;
  final bool isEditMode;
  final bool showLeft; // 新增：是否显示左侧频道列表

  const ScheduleView({
    Key? key,
    required this.channels,
    this.selectedChannel,
    required this.epgMap,
    required this.onSelectChannel,
    this.leftWeight = 0.35,
    this.rightWeight = 0.65,
    required this.onLeftWeightChanged,
    this.isEditMode = false,
    this.showLeft = true,
  }) : super(key: key);

  @override
  _ScheduleViewState createState() => _ScheduleViewState();
}

class _ScheduleViewState extends State<ScheduleView> {
  int selectedDayIndex = 0;
  List<String> dayLabels = [];

  @override
  void didUpdateWidget(ScheduleView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChannel != oldWidget.selectedChannel) {
      _updateDays();
    }
  }

  @override
  void initState() {
    super.initState();
    _updateDays();
  }

  void _updateDays() {
    final programs = widget.selectedChannel != null ? widget.epgMap[widget.selectedChannel!.name] ?? [] : [];
    final days = <String>{};
    for (var prog in programs) {
      final date = '${prog.start.year}-${prog.start.month}-${prog.start.day}';
      days.add(date);
    }
    final sorted = days.toList()..sort();
    final today = DateTime.now();
    final todayStr = '${today.year}-${today.month}-${today.day}';
    final filtered = <String>[];
    bool found = false;
    for (var d in sorted) {
      if (d == todayStr) found = true;
      if (found && filtered.length < 7) filtered.add(d);
    }
    if (filtered.isEmpty && sorted.isNotEmpty) filtered.add(sorted.first);
    setState(() {
      dayLabels = filtered;
      selectedDayIndex = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final programs = widget.selectedChannel != null ? widget.epgMap[widget.selectedChannel!.name] ?? [] : [];
    List<EpgProgram> dayPrograms = [];
    if (selectedDayIndex < dayLabels.length) {
      final targetDay = dayLabels[selectedDayIndex];
      dayPrograms = programs.where((p) =>
          '${p.start.year}-${p.start.month}-${p.start.day}' == targetDay).cast<EpgProgram>().toList();
    }

    if (widget.showLeft) {
      // 两列布局（左侧频道列表 + 右侧节目单）
      return Row(
        children: [
          Expanded(
            flex: (widget.leftWeight * 100).toInt(),
            child: ChannelList(
              channels: widget.channels,
              selectedChannel: widget.selectedChannel,
              onSelect: widget.onSelectChannel,
              epgMap: widget.epgMap,
              showChannelNumber: false,
              showLogo: true,
            ),
          ),
          _buildDragBar(),
          Expanded(
            flex: (widget.rightWeight * 100).toInt(),
            child: _buildSchedule(dayPrograms),
          ),
        ],
      );
    } else {
      // 仅显示节目单（用于三列布局）
      return _buildSchedule(dayPrograms);
    }
  }

  Widget _buildSchedule(List<EpgProgram> dayPrograms) {
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: dayLabels.asMap().entries.map((entry) {
              final idx = entry.key;
              final label = entry.value;
              final isSelected = idx == selectedDayIndex;
              final display = _formatDayLabel(label);
              return GestureDetector(
                onTap: () => setState(() => selectedDayIndex = idx),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  margin: EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: isSelected ? Colors.blue : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(display, style: TextStyle(color: Colors.white)),
                ),
              );
            }).toList(),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: dayPrograms.length,
            itemBuilder: (context, index) {
              final prog = dayPrograms[index];
              final now = DateTime.now();
              final isCurrent = prog.start.isBefore(now) && prog.end.isAfter(now);
              final timeStr = '${_formatTime(prog.start)}-${_formatTime(prog.end)}';
              return Container(
                color: isCurrent ? Colors.blue.withOpacity(0.4) : Colors.transparent,
                child: ListTile(
                  leading: Text(
                    timeStr,
                    style: TextStyle(
                      color: isCurrent ? Colors.yellow : Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                  title: Text(
                    prog.title,
                    style: TextStyle(
                      color: isCurrent ? Colors.yellow : Colors.white,
                      fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: prog.desc != null && prog.desc!.isNotEmpty
                      ? Text(prog.desc!, style: TextStyle(fontSize: 11, color: Colors.white60))
                      : null,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDragBar() {
    return GestureDetector(
      onHorizontalDragUpdate: (details) {
        if (!widget.isEditMode) return;
        final delta = details.delta.dx / MediaQuery.of(context).size.width;
        final newLeft = (widget.leftWeight + delta).clamp(0.1, 0.9);
        widget.onLeftWeightChanged(newLeft);
      },
      child: Container(
        width: widget.isEditMode ? 6 : 2,
        color: widget.isEditMode ? Colors.yellow : Colors.transparent,
      ),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatDayLabel(String dateStr) {
    final parts = dateStr.split('-');
    final month = int.parse(parts[1]);
    final day = int.parse(parts[2]);
    final date = DateTime(int.parse(parts[0]), month, day);
    final now = DateTime.now();
    if (date.year == now.year && date.month == now.month && date.day == now.day) return '今天 $month/$day';
    final weekdays = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    return '${weekdays[date.weekday % 7]} $month/$day';
  }
}
