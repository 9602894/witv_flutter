import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/log_service.dart';
import '../services/settings_service.dart';

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
  int _currentDecoder = 0;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  void _initPlayer() {
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      _currentDecoder = settings.decoderIndex;

      // 解码映射：0=系统（auto），1=硬解（true），2=软解（false）
      // 其他值暂映射为硬解/软解组合
      bool? hardwareDecoding;
      if (_currentDecoder == 1 || _currentDecoder == 3 || _currentDecoder == 5) {
        hardwareDecoding = true; // 硬解
      } else if (_currentDecoder == 2 || _currentDecoder == 4 || _currentDecoder == 6) {
        hardwareDecoding = false; // 软解
      } else {
        hardwareDecoding = null; // 系统自动
      }

      final config = PlayerConfiguration(
        hardwareDecoding: hardwareDecoding,
        bufferDuration: Duration(milliseconds: 5000),
        bufferSize: 8192,
      );

      player = Player(configuration: config);
      controller = VideoController(player);
      _isInitialized = true;
      _currentUrl = widget.url;
      _play(widget.url);
      LogService.write('Player 初始化成功，解码模式: $_currentDecoder');
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
    player.stream.buffer.listen((buffer) {
      if (buffer.inMilliseconds > 0) {
        final speed = buffer.inMilliseconds / 1024;
        widget.onSpeedUpdate(speed);
      }
    });
    player.stream.error.listen((error) {
      LogService.write('播放错误: $error');
      if (!isReconnecting) {
        _attemptReconnect();
      }
    });
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
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (settings.decoderIndex != _currentDecoder) {
      _currentDecoder = settings.decoderIndex;
      LogService.write('解码方式切换为 $_currentDecoder，重启播放器');
      _recreatePlayer();
      return;
    }
    if (oldWidget.url != widget.url && _isInitialized) {
      _currentUrl = widget.url;
      LogService.write('切换频道: ${widget.url}');
      player.open(Media(widget.url));
    }
  }

  void _recreatePlayer() {
    if (_isInitialized) {
      player.dispose();
    }
    _isInitialized = false;
    _initPlayer();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return Container(color: Colors.transparent);
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
