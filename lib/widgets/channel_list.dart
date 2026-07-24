import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';

class ChannelList extends StatelessWidget {
  final List<Channel> channels;
  final Channel? selectedChannel;
  final ValueChanged<Channel> onSelect;
  final Map<String, List<EpgProgram>> epgMap;

  const ChannelList({
    Key? key,
    required this.channels,
    this.selectedChannel,
    required this.onSelect,
    required this.epgMap,
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

        return ListTile(
          selected: isSelected,
          selectedTileColor: Colors.blue.withOpacity(0.3),
          title: Text(ch.name),
          subtitle: currentTitle != null ? Text(currentTitle, style: TextStyle(fontSize: 11, color: Colors.grey)) : null,
          onTap: () => onSelect(ch),
        );
      },
    );
  }
}
