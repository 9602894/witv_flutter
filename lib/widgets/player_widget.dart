import 'dart:math';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/log_service.dart';

class PlayerWidget extends StatefulWidget {
  final String url;
  final VoidCallback onError;
  final Function(double speed) onSpeedUpdate;

  const PlayerWidget({Key? key, required this.url, required this.onError, required this.onSpeedUpdate}) : super(key: key);

  @override
  _PlayerWidgetState createState() => _PlayerWidgetState();
}

class _PlayerWidgetState extends State<PlayerWidget> {
  Player? player;
  VideoController? controller;
  int reconnectAttempts = 0;
  bool isReconnecting = false;
  bool _initialized = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  void _initPlayer() {
    try {
      // 尝试创建播放器（如果 MediaKit 未初始化会抛异常）
      player = Player();
      controller = VideoController(player!);
      _initialized = true;
      _play();
      LogService.write('Player 创建成功');
    } catch (e, stack) {
      _initialized = false;
      _errorMessage = '播放器初始化失败: ${e.toString()}\n请检查 media_kit 配置。';
      LogService.writeCrashLog(e, stack);
    }
  }

  void _play() {
    if (!_initialized || player == null) return;
    LogService.write('开始播放: ${widget.url}');
    player!.open(Media(widget.url));
    player!.stream.buffer.listen((buffer) {
      if (buffer.inMilliseconds > 0) {
        final speed = buffer.inMilliseconds / 1024;
        widget.onSpeedUpdate(speed);
      }
    });
    player!.stream.error.listen((error) {
      LogService.write('播放错误: $error');
      if (!isReconnecting) {
        _attemptReconnect();
      }
    });
    player!.stream.completed.listen((_) {
      LogService.write('播放完成，重新准备');
      if (player != null) {
        player!.open(Media(widget.url));
      }
    });
  }

  void _attemptReconnect() {
    if (isReconnecting || !_initialized) return;
    isReconnecting = true;
    reconnectAttempts++;
    final delay = Duration(milliseconds: (2000 * pow(2, reconnectAttempts - 1)).toInt().clamp(1000, 30000));
    LogService.write('尝试重连，第 $reconnectAttempts 次，延迟 ${delay.inMilliseconds}ms');
    Future.delayed(delay, () {
      if (mounted && _initialized) {
        player!.open(Media(widget.url));
        isReconnecting = false;
        reconnectAttempts = 0;
        LogService.write('重连成功');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      // 显示错误信息
      return Container(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Text(
              _errorMessage,
              style: TextStyle(color: Colors.white, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return Video(
      controller: controller!,
      fit: BoxFit.contain,
    );
  }

  @override
  void dispose() {
    player?.dispose();
    super.dispose();
  }
}
