import 'dart:math';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/log_service.dart';

class PlayerWidget extends StatefulWidget {
  final String url;
  final VoidCallback onError;
  final Function(double speed) onSpeedUpdate;

  const PlayerWidget({
    Key? key,
    required this.url,
    required this.onError,
    required this.onSpeedUpdate,
  }) : super(key: key);

  @override
  _PlayerWidgetState createState() => _PlayerWidgetState();
}

class _PlayerWidgetState extends State<PlayerWidget> {
  late Player player;
  late VideoController controller;
  int reconnectAttempts = 0;
  bool isReconnecting = false;
  bool _isInitialized = false;
  String _currentUrl = '';

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  void _initPlayer() {
    try {
      // 使用默认配置，自动硬件解码
      player = Player();
      controller = VideoController(player);
      _isInitialized = true;
      _currentUrl = widget.url;
      _play(widget.url);
      LogService.write('Player 初始化成功');
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
      Future.delayed(Duration(seconds: 2), () {
        if (mounted && !_isInitialized) {
          LogService.write('重试初始化 Player');
          _initPlayer();
        }
      });
    }
  }

  void _play(String url) {
    if (!_isInitialized) return;
    LogService.write('播放: $url');
    player.open(Media(url));
    // 速度监听
    player.stream.buffer.listen((buffer) {
      if (buffer.inMilliseconds > 0) {
        final speed = buffer.inMilliseconds / 1024;
        widget.onSpeedUpdate(speed);
      }
    });
    // 错误重连
    player.stream.error.listen((error) {
      LogService.write('播放错误: $error');
      if (!isReconnecting) {
        _attemptReconnect();
      }
    });
    // 播放完成自动续播
    player.stream.completed.listen((_) {
      LogService.write('播放完成，重新准备');
      if (player != null) {
        player.open(Media(url));
      }
    });
  }

  void _attemptReconnect() {
    if (isReconnecting || !_isInitialized) return;
    isReconnecting = true;
    reconnectAttempts++;
    final delay = Duration(milliseconds: (2000 * pow(2, reconnectAttempts - 1)).toInt().clamp(1000, 30000));
    LogService.write('尝试重连，第 $reconnectAttempts 次，延迟 ${delay.inMilliseconds}ms');
    Future.delayed(delay, () {
      if (mounted && _isInitialized) {
        player.open(Media(_currentUrl));
        isReconnecting = false;
        reconnectAttempts = 0;
        LogService.write('重连成功');
      }
    });
  }

  @override
  void didUpdateWidget(PlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url && _isInitialized) {
      _currentUrl = widget.url;
      LogService.write('切换频道: ${widget.url}');
      player.open(Media(widget.url));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return Container(color: Colors.black);
    }
    return Video(
      controller: controller,
      fit: BoxFit.contain,
    );
  }

  @override
  void dispose() {
    if (_isInitialized) {
      player.dispose();
    }
    super.dispose();
  }
}
