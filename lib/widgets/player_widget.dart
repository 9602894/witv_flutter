import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
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
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  String _currentUrl = '';
  Timer? _bufferTimer;
  double _speed = 0;
  bool _isReconnecting = false;
  Timer? _reconnectTimer;

  @override
  void initState() {
    super.initState();
    _initPlayer(widget.url);
  }

  void _initPlayer(String url) {
    _currentUrl = url;
    _controller?.dispose();
    _isReconnecting = false;
    _reconnectTimer?.cancel();

    _controller = VideoPlayerController.network(url)
      ..initialize().then((_) {
        setState(() {
          _isInitialized = true;
          _isReconnecting = false;
        });
        _controller!.play();
        LogService.write('视频初始化成功: $url');
        // 模拟网速
        _bufferTimer?.cancel();
        _bufferTimer = Timer.periodic(Duration(seconds: 1), (timer) {
          if (_controller != null && _controller!.value.buffered.isNotEmpty) {
            // 模拟网速 0.5~5.5 M/s
            double simulatedSpeed = 0.5 + (DateTime.now().millisecond % 10) / 2;
            widget.onSpeedUpdate(simulatedSpeed);
          }
        });
      }).catchError((e) {
        LogService.write('视频初始化失败: $e');
        widget.onError();
        // 检查是否开启重连
        final settings = Provider.of<SettingsService>(context, listen: false);
        if (settings.autoReconnect && !_isReconnecting) {
          _attemptReconnect();
        }
      });
  }

  void _attemptReconnect() {
    if (_isReconnecting) return;
    _isReconnecting = true;
    LogService.write('尝试重连 (1秒后)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: 1), () {
      if (mounted && !_isInitialized) {
        LogService.write('重连中: $_currentUrl');
        _initPlayer(_currentUrl);
      } else {
        _isReconnecting = false;
      }
    });
  }

  @override
  void didUpdateWidget(PlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _isReconnecting = false;
      _reconnectTimer?.cancel();
      _initPlayer(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized || _controller == null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        ),
      );
    }
    return Stack(
      children: [
        AspectRatio(
          aspectRatio: _controller!.value.aspectRatio,
          child: VideoPlayer(_controller!),
        ),
        // 网速显示（右下角）
        Positioned(
          bottom: 20,
          right: 20,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${_speed.toStringAsFixed(1)} M/s',
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    _bufferTimer?.cancel();
    _reconnectTimer?.cancel();
    super.dispose();
  }
}
