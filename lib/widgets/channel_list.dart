import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';

class ChannelList extends StatelessWidget {
  final List<Channel> channels;
  final Channel? selectedChannel;
  final ValueChanged<Channel> onSelect;
  final Map<String, List<EpgProgram>> epgMap;
  final bool showChannelNumber;
  final bool showLogo;

  const ChannelList({
    Key? key,
    required this.channels,
    this.selectedChannel,
    required this.onSelect,
    required this.epgMap,
    this.showChannelNumber = false,
    this.showLogo = true,
  }) : super(key: key);

  // 工具：获取当前 UTC 时间
  DateTime _getUtcNow() => DateTime.now().toUtc();

  // 工具：格式化 UTC 时间为北京时间（+8）的 HH:mm
  String _formatBeijingTime(DateTime utcTime) {
    final beijing = utcTime.add(Duration(hours: 8));
    return '${beijing.hour.toString().padLeft(2, '0')}:${beijing.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: channels.length,
      itemBuilder: (context, index) {
        final ch = channels[index];
        final isSelected = ch == selectedChannel;
        final epgList = epgMap[ch.name] ?? [];
        String? currentTitle;
        if (epgList.isNotEmpty) {
          final now = _getUtcNow();
          for (var prog in epgList) {
            if (prog.start.isBefore(now) && prog.end.isAfter(now)) {
              currentTitle = '${_formatBeijingTime(prog.start)}-${_formatBeijingTime(prog.end)} ${prog.title}';
              break;
            }
          }
        }

        Widget logoWidget = SizedBox.shrink();
        if (showLogo) {
          final firstChar = ch.name.isNotEmpty ? ch.name[0] : '?';
          logoWidget = Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                firstChar,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          );
        }

        return ListTile(
          selected: isSelected,
          selectedTileColor: Colors.blue.withOpacity(0.3),
          leading: showChannelNumber
              ? Text(
                  (index + 1).toString().padLeft(4, '0'),
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                )
              : (showLogo ? logoWidget : null),
          title: Text(
            ch.name,
            style: TextStyle(
              color: isSelected ? Colors.yellow : Colors.white,
              fontSize: 13,
            ),
          ),
          subtitle: currentTitle != null
              ? Text(
                  currentTitle,
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : null,
          onTap: () => onSelect(ch),
        );
      },
    );
  }
}
