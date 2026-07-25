import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';

class ChannelList extends StatelessWidget {
  final List<Channel> channels;
  final Channel? selectedChannel;
  final ValueChanged<Channel> onSelect;
  final Map<String, List<EpgProgram>> epgMap;
  final bool showChannelNumber; // 是否显示频道号

  const ChannelList({
    Key? key,
    required this.channels,
    this.selectedChannel,
    required this.onSelect,
    required this.epgMap,
    this.showChannelNumber = false,
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
        // 频道号从 0001 开始
        final channelNumber = (index + 1).toString().padLeft(4, '0');
        return ListTile(
          selected: isSelected,
          selectedTileColor: Colors.blue.withOpacity(0.3),
          leading: showChannelNumber
              ? Text(
                  channelNumber,
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                )
              : null,
          title: Text(
            ch.name,
            style: TextStyle(color: isSelected ? Colors.yellow : Colors.white),
          ),
          subtitle: currentTitle != null
              ? Text(currentTitle, style: TextStyle(fontSize: 11, color: Colors.grey))
              : null,
          onTap: () => onSelect(ch),
        );
      },
    );
  }
}
