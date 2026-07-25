import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';

class ChannelList extends StatelessWidget {
  final List<Channel> channels;
  final Channel? selectedChannel;
  final ValueChanged<Channel> onSelect;
  final Map<String, List<EpgProgram>> epgMap;
  final bool showChannelNumber;
  final bool showLogo; // 是否显示台标/首字

  const ChannelList({
    Key? key,
    required this.channels,
    this.selectedChannel,
    required this.onSelect,
    required this.epgMap,
    this.showChannelNumber = false,
    this.showLogo = true,
  }) : super(key: key);

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
          final now = DateTime.now();
          for (var prog in epgList) {
            if (prog.start.isBefore(now) && prog.end.isAfter(now)) {
              currentTitle = '${prog.start.hour}:${prog.start.minute}-${prog.end.hour}:${prog.end.minute} ${prog.title}';
              break;
            }
          }
        }
        final channelNumber = (index + 1).toString().padLeft(4, '0');
        
        // 获取台标（若有）或首字
        Widget logoWidget;
        if (showLogo) {
          // 这里简化，实际可从 channel.logoUrl 加载，若无则显示首字
          final firstChar = ch.name.isNotEmpty ? ch.name[0] : '?';
          logoWidget = CircleAvatar(
            radius: 14,
            backgroundColor: Colors.grey[800],
            child: Text(
              firstChar,
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
          );
        } else {
          logoWidget = SizedBox.shrink();
        }

        return ListTile(
          selected: isSelected,
          selectedTileColor: Colors.blue.withOpacity(0.3),
          leading: showChannelNumber
              ? Text(
                  channelNumber,
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
