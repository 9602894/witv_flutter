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
  Timer? _reconnectTimer;
  bool _isReconnecting = false;
  int _reconnectAttempts = 0;

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
        // 重置重连计数
        _reconnectAttempts = 0;
        _isReconnecting = false;
        _reconnectTimer?.cancel();
        // 模拟网速
        _bufferTimer?.cancel();
        _bufferTimer = Timer.periodic(Duration(seconds: 1), (timer) {
          if (_controller != null && _controller!.value.buffered.isNotEmpty) {
            // 近似网速模拟
            double simulatedSpeed = 0.5 + (DateTime.now().millisecond % 10) / 2;
            widget.onSpeedUpdate(simulatedSpeed);
          }
        });
      }).catchError((e) {
        LogService.write('视频初始化失败: $e');
        widget.onError();
        // 检查自动重连设置
        final settings = Provider.of<SettingsService>(context, listen: false);
        if (settings.autoReconnect) {
          _startReconnect();
        }
      });
  }

  void _startReconnect() {
    if (_isReconnecting) return;
    _isReconnecting = true;
    _reconnectAttempts++;
    LogService.write('开始重连，第 $_reconnectAttempts 次');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      // 尝试重新初始化
      _controller?.dispose();
      _controller = VideoPlayerController.network(_currentUrl)
        ..initialize().then((_) {
          timer.cancel();
          _isReconnecting = false;
          setState(() {
            _isInitialized = true;
          });
          _controller!.play();
          LogService.write('重连成功');
          _reconnectAttempts = 0;
        }).catchError((e) {
          LogService.write('重连失败: $e');
          // 继续等待下一次尝试
        });
    });
  }

  @override
  void didUpdateWidget(PlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _reconnectTimer?.cancel();
      _isReconnecting = false;
      _reconnectAttempts = 0;
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
    _reconnectTimer?.cancel();
    super.dispose();
  }
}
