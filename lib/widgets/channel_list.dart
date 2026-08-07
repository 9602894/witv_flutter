import 'dart:io';
import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../services/logo_service.dart';

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

  DateTime _getNow() => DateTime.now();
  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: channels.length,
      itemBuilder: (context, index) {
        final ch = channels[index];
        final isSelected = ch == selectedChannel;
        final epgList = epgMap[ch.name] ?? <EpgProgram>[];
        String? currentTitle;
        if (epgList.isNotEmpty) {
          final now = _getNow();
          for (var prog in epgList) {
            if (prog.start.isBefore(now) && prog.end.isAfter(now)) {
              currentTitle = '${_formatTime(prog.start)}-${_formatTime(prog.end)} ${prog.title}';
              break;
            }
          }
        }

        Widget leadingWidget;
        if (showLogo) {
          leadingWidget = FutureBuilder<File?>(
            future: LogoService().getLogo(ch.name),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return SizedBox(
                  width: 80,
                  height: 80,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                );
              } else if (snapshot.hasData && snapshot.data != null) {
                return Container(
                  color: Colors.transparent,
                  child: Image.file(
                    snapshot.data!,
                    width: 80,
                    height: 80,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => _defaultLogo(ch.name, size: 80),
                  ),
                );
              } else {
                return _defaultLogo(ch.name, size: 80);
              }
            },
          );
        } else {
          leadingWidget = _defaultLogo(ch.name, size: 80);
        }

        return ListTile(
          selected: isSelected,
          selectedTileColor: Colors.blue.withOpacity(0.3),
          leading: showChannelNumber
              ? Text(
                  (index + 1).toString().padLeft(4, '0'),
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                )
              : leadingWidget,
          title: Row(
            children: [
              if (ch.number != null)
                Text(
                  '${ch.number}  ',
                  style: TextStyle(
                    color: isSelected ? Colors.yellow : Colors.white70,
                    fontSize: 12,
                  ),
                ),
              Expanded(
                child: Text(
                  ch.name,
                  style: TextStyle(
                    color: isSelected ? Colors.yellow : Colors.white,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
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

  Widget _defaultLogo(String channelName, {double size = 80}) {
    final firstChar = channelName.isNotEmpty ? channelName[0] : '?';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.transparent,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          firstChar,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.5,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
