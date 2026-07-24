import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import 'channel_list.dart';

class ScheduleView extends StatefulWidget {
  final List<Channel> channels;
  final Channel? selectedChannel;
  final Map<String, List<EpgProgram>> epgMap;
  final ValueChanged<Channel> onSelectChannel;

  const ScheduleView({
    Key? key,
    required this.channels,
    this.selectedChannel,
    required this.epgMap,
    required this.onSelectChannel,
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
    // 仅保留今天及之后最多7天
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
          '${p.start.year}-${p.start.month}-${p.start.day}' == targetDay).toList();
    }

    return Row(
      children: [
        Expanded(
          flex: 2,
          child: ChannelList(
            channels: widget.channels,
            selectedChannel: widget.selectedChannel,
            onSelect: widget.onSelectChannel,
            epgMap: widget.epgMap,
          ),
        ),
        VerticalDivider(width: 1),
        Expanded(
          flex: 3,
          child: Column(
            children: [
              // 日期标签
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
                    final isCurrent = prog.start.isBefore(DateTime.now()) && prog.end.isAfter(DateTime.now());
                    return ListTile(
                      tileColor: isCurrent ? Colors.blue.withOpacity(0.3) : null,
                      leading: Text('${prog.start.hour}:${prog.start.minute}'),
                      title: Text(prog.title),
                      subtitle: prog.desc != null ? Text(prog.desc!) : null,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
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
