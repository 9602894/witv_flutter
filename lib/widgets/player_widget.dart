import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
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
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  String _currentUrl = '';
  Timer? _speedTimer;
  double _speed = 0;

  @override
  void initState() {
    super.initState();
    _initPlayer(widget.url);
  }

  void _initPlayer(String url) {
    _currentUrl = url;
    _controller?.dispose();
    _controller = VideoPlayerController.network(url)
      ..initialize().then((_) {
        setState(() {
          _isInitialized = true;
        });
        _controller!.play();
        LogService.write('视频初始化成功: $url');
        // 5秒刷新一次网速
        _speedTimer?.cancel();
        _speedTimer = Timer.periodic(Duration(seconds: 5), (timer) {
          if (_controller != null && _controller!.value.buffered.isNotEmpty) {
            // 模拟网速，实际可用真实数据，这里我们用随机值展示效果
            double simulatedSpeed = 0.5 + (DateTime.now().millisecond % 10) / 2;
            widget.onSpeedUpdate(simulatedSpeed);
          }
        });
      }).catchError((e) {
        LogService.write('视频初始化失败: $e');
        widget.onError();
        // 无限重连：每3秒重试一次
        _attemptReconnect();
      });
  }

  void _attemptReconnect() {
    if (!mounted) return;
    Future.delayed(Duration(seconds: 3), () {
      if (!_isInitialized && mounted) {
        LogService.write('尝试重连: $_currentUrl');
        _initPlayer(_currentUrl);
      }
    });
  }

  @override
  void didUpdateWidget(PlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _initPlayer(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized || _controller == null) {
      return Container(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Stack(
      children: [
        AspectRatio(
          aspectRatio: _controller!.value.aspectRatio,
          child: VideoPlayer(_controller!),
        ),
        // 网速显示（右下角，5秒刷新）
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
    _speedTimer?.cancel();
    super.dispose();
  }
}
