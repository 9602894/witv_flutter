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
  VideoPlayerController? _nextController; // 预加载控制器
  bool _isInitialized = false;
  bool _isLoading = true;
  bool _isFailed = false;
  bool _isDisposed = false;
  String _currentUrl = '';
  Timer? _speedTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int maxReconnectAttempts = 3;
  double _speed = 0;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
    _initPlayer();
  }

  @override
  void didUpdateWidget(PlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url && !_isDisposed) {
      _currentUrl = widget.url;
      _reconnectAttempts = 0;
      _isFailed = false;
      _preloadPlayer(); // 预加载新URL
    }
  }

  // 预加载新播放器（不切换，仅准备）
  Future<void> _preloadPlayer() async {
    if (_isDisposed) return;
    _isLoading = true;
    setState(() {});

    // 如果已有预加载控制器，先清理
    await _nextController?.dispose();
    _nextController = null;

    LogService.write('预加载频道: ${_extractChannelName(_currentUrl)}');

    try {
      _nextController = VideoPlayerController.network(_currentUrl);
      await _nextController!.initialize().timeout(Duration(seconds: 2));
      if (_isDisposed) return;
      LogService.write('预加载成功: $_currentUrl');
      // 预加载成功，立即切换
      _swapController();
    } catch (e) {
      LogService.write('预加载失败: $e，尝试直接加载');
      // 预加载失败，回退到直接加载
      _initPlayer();
    }
  }

  // 交换控制器（无缝切换）
  void _swapController() {
    if (_nextController == null || _isDisposed) return;
    // 移除旧监听
    _controller?.removeListener(_onControllerListener);
    // 停止并释放旧控制器（但保留最后画面）
    _controller?.pause();
    // 交换
    _controller = _nextController;
    _nextController = null;
    _isInitialized = true;
    _isLoading = false;
    _isFailed = false;
    _controller!.addListener(_onControllerListener);
    _controller!.play();
    setState(() {});
    _startSpeedMonitor();
    _reconnectAttempts = 0;
    LogService.write('切换完成: $_currentUrl');
  }

  // 直接加载（无预加载时使用）
  Future<void> _initPlayer() async {
    if (_isDisposed) return;
    await _controller?.dispose();
    _controller = null;
    _isInitialized = false;
    _isLoading = true;
    _isFailed = false;
    setState(() {});

    LogService.write('直接加载频道: ${_extractChannelName(_currentUrl)}');

    try {
      _controller = VideoPlayerController.network(_currentUrl);
      await _controller!.initialize().timeout(Duration(seconds: 3));
      if (_isDisposed) return;
      setState(() {
        _isInitialized = true;
        _isLoading = false;
      });
      _controller!.play();
      LogService.write('直接加载成功: $_currentUrl');
      _startSpeedMonitor();
      _reconnectAttempts = 0;
    } catch (e) {
      if (_isDisposed) return;
      LogService.write('直接加载失败: $e');
      setState(() {
        _isLoading = false;
        _isFailed = true;
      });
      widget.onError();
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= maxReconnectAttempts) {
      setState(() => _isFailed = true);
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: 500), () {
      if (_isDisposed) return;
      _reconnectAttempts++;
      _initPlayer();
    });
  }

  void _onControllerListener() {
    if (_controller == null || _isDisposed) return;
    if (_controller!.value.hasError) {
      LogService.write('播放错误: ${_controller!.value.errorDescription}');
      if (_reconnectAttempts < maxReconnectAttempts) {
        _scheduleReconnect();
      } else {
        setState(() => _isFailed = true);
      }
    }
  }

  void _retry() {
    _reconnectAttempts = 0;
    _isFailed = false;
    _initPlayer();
  }

  void _startSpeedMonitor() {
    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(Duration(seconds: 3), (timer) {
      if (_controller != null && _controller!.value.isInitialized) {
        double simulatedSpeed = 0.5 + (DateTime.now().millisecond % 10) / 2;
        setState(() => _speed = simulatedSpeed);
        widget.onSpeedUpdate(simulatedSpeed);
      }
    });
  }

  String _extractChannelName(String url) {
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;
      if (segments.isNotEmpty) return segments.last.split('.').first;
      return url;
    } catch (_) => url;
  }

  @override
  Widget build(BuildContext context) {
    if (_isFailed) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, color: Colors.white70, size: 48),
              SizedBox(height: 16),
              Text('加载失败', style: TextStyle(color: Colors.white70)),
              SizedBox(height: 16),
              ElevatedButton(onPressed: _retry, child: Text('重试')),
            ],
          ),
        ),
      );
    }

    if (_isLoading || !_isInitialized || _controller == null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 10),
              Text('加载中...', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        VideoPlayer(_controller!),
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
    _isDisposed = true;
    _controller?.removeListener(_onControllerListener);
    _controller?.dispose();
    _nextController?.dispose();
    _speedTimer?.cancel();
    _reconnectTimer?.cancel();
    super.dispose();
  }
}
