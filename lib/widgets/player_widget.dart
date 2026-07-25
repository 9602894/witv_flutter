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
  Timer? _bufferTimer;

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
        // 模拟网速（近似）
        _bufferTimer?.cancel();
        _bufferTimer = Timer.periodic(Duration(seconds: 1), (timer) {
          if (_controller != null && _controller!.value.buffered.isNotEmpty) {
            final buffered = _controller!.value.buffered.last.end.inMilliseconds;
            final duration = _controller!.value.duration.inMilliseconds;
            if (duration > 0) {
              // 计算缓冲百分比，当作"速度"展示（非精确网速）
              final speed = (buffered / duration) * 100;
              widget.onSpeedUpdate(speed);
            }
          }
        });
      }).catchError((e) {
        LogService.write('视频初始化失败: $e');
        widget.onError();
        // 自动重试
        Future.delayed(Duration(seconds: 3), () {
          if (mounted && _controller != null && !_controller!.value.isInitialized) {
            _initPlayer(url);
          }
        });
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
    return AspectRatio(
      aspectRatio: _controller!.value.aspectRatio,
      child: VideoPlayer(_controller!),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    _bufferTimer?.cancel();
    super.dispose();
  }
}
