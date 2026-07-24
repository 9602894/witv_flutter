import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';

void showInfoPopup(BuildContext context, Channel channel, List<EpgProgram> programs, double speed) {
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: Colors.black.withOpacity(0.9),
      title: Text(channel.name, style: TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('网速: ${speed.toStringAsFixed(1)} KB/s', style: TextStyle(color: Colors.white70)),
          SizedBox(height: 8),
          if (programs.isNotEmpty) ...[
            Text('当前节目:', style: TextStyle(color: Colors.yellow)),
            Text('${programs.first.start.hour}:${programs.first.start.minute} - ${programs.first.title}',
                style: TextStyle(color: Colors.white)),
            if (programs.first.desc != null) Text(programs.first.desc!, style: TextStyle(color: Colors.white70)),
            SizedBox(height: 8),
            if (programs.length > 1) ...[
              Text('下一节目:', style: TextStyle(color: Colors.yellow)),
              Text('${programs[1].start.hour}:${programs[1].start.minute} - ${programs[1].title}',
                  style: TextStyle(color: Colors.white)),
            ],
          ] else
            Text('暂无EPG信息', style: TextStyle(color: Colors.grey)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('关闭', style: TextStyle(color: Colors.white))),
      ],
    ),
  );
}
