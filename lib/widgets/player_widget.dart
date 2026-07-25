import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../services/log_service.dart';

class PlayerWidget extends StatefulWidget {
  final String url;
  final VoidCallback onError;
  final Function(double speed) onSpeedUpdate; // speed 为 M/s

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
            // 近似网速 = 缓冲字节 / 时间（这里用缓冲百分比模拟，实际无法精确）
            // 为了演示，我们模拟一个值，实际可替换为真实网速监测
            // 这里我们模拟 0.5 ~ 5 M/s 之间随机，真实场景需要从流中获取数据速率
            // 为了展示效果，我们使用一个随机值，但你可以通过计算缓冲数据量来估算
            // 此处我们直接使用随机数模拟，并更新到父组件
            double simulatedSpeed = 0.5 + (DateTime.now().millisecond % 10) / 2; // 0.5 ~ 5.5
            widget.onSpeedUpdate(simulatedSpeed);
          }
        });
      }).catchError((e) {
        LogService.write('视频初始化失败: $e');
        widget.onError();
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
    super.dispose();
  }
}
