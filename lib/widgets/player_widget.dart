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
  bool _isLoading = true;
  bool _isFailed = false;
  bool _isDisposed = false;
  String _currentUrl = '';
  
  Timer? _speedTimer;
  Timer? _reconnectTimer;
  Timer? _stallMonitorTimer;
  int _reconnectAttempts = 0;
  static const int initTimeoutMs = 3000;
  double _speed = 0;
  bool _isPlaying = false;
  bool _isBuffering = false;

  VideoPlayerController? _preloadController;
  String? _preloadUrl;

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
      _switchToNewUrl(widget.url);
    }
  }

  Future<void> _switchToNewUrl(String newUrl) async {
    if (_isDisposed) return;
    LogService.write('切换频道: ${_extractChannelName(newUrl)}');
    setState(() {
      _isLoading = true;
      _isFailed = false;
    });
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    try {
      final newController = _createController(newUrl);
      await newController.initialize().timeout(Duration(milliseconds: initTimeoutMs));
      if (_isDisposed) return;
      await _controller?.dispose();
      _controller = null;
      _controller = newController;
      _currentUrl = newUrl;
      _isInitialized = true;
      _isLoading = false;
      _isFailed = false;
      _reconnectAttempts = 0;
      _controller!.play();
      _startSpeedMonitor();
      _startStallMonitor();
      setState(() {});
      LogService.write('切换成功: $newUrl');
    } catch (e) {
      await _preloadController?.dispose();
      _preloadController = null;
      if (_controller != null && _controller!.value.isInitialized) {
        setState(() => _isLoading = false);
        LogService.write('预加载新流失败，回退到旧流');
      } else {
        setState(() {
          _isLoading = false;
          _isFailed = true;
        });
        widget.onError();
        _scheduleReconnect();
      }
    }
  }

  // 已移除 options 参数
  VideoPlayerController _createController(String url) {
    return VideoPlayerController.network(
      url,
      httpHeaders: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': 'http://io8.myartsonline.com',
        'Accept': '*/*',
        'Connection': 'keep-alive',
        'Cache-Control': 'no-cache',
      },
    );
  }

  Future<void> _initPlayer() async {
    if (_isDisposed) return;
    await _controller?.dispose();
    _controller = null;
    _isInitialized = false;
    _isLoading = true;
    _isFailed = false;
    _isPlaying = false;
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stallMonitorTimer?.cancel();
    _stallMonitorTimer = null;
    setState(() {});

    LogService.write('加载频道: ${_extractChannelName(_currentUrl)}');

    try {
      _controller = _createController(_currentUrl);
      _controller!.addListener(_onPlayerStateChanged);
      await _controller!.initialize().timeout(Duration(milliseconds: initTimeoutMs));
      if (_isDisposed) return;
      setState(() {
        _isInitialized = true;
        _isLoading = false;
        _isFailed = false;
      });
      _controller!.play();
      _startSpeedMonitor();
      _startStallMonitor();
      LogService.write('加载成功: $_currentUrl');
    } catch (e) {
      if (_isDisposed) return;
      LogService.write('加载失败: $e');
      await _controller?.dispose();
      _controller = null;
      setState(() {
        _isLoading = false;
        _isFailed = true;
      });
      widget.onError();
      _scheduleReconnect();
    }
  }

  void _onPlayerStateChanged() {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final value = _controller!.value;
    _isPlaying = value.isPlaying;
    _isBuffering = value.isBuffering;
    if (!value.isPlaying && !value.isBuffering && value.duration != null && value.duration!.inSeconds > 0) {
      LogService.write('播放器异常停止，触发重连');
      _scheduleReconnect();
    }
  }

  void _startStallMonitor() {
    _stallMonitorTimer?.cancel();
    _stallMonitorTimer = Timer.periodic(Duration(seconds: 5), (timer) {
      if (_controller == null || !_controller!.value.isInitialized) return;
      final value = _controller!.value;
      if (value.isBuffering && value.isPlaying == false && _isLoading == false) {
        LogService.write('检测到卡在缓冲，强制重连');
        _scheduleReconnect();
      }
    });
  }

  void _scheduleReconnect() {
    if (_isDisposed) return;
    _reconnectTimer?.cancel();
    _controller?.removeListener(_onPlayerStateChanged);
    _controller?.pause();
    _controller?.dispose();
    _controller = null;
    _isInitialized = false;
    _isPlaying = false;
    setState(() {
      _isLoading = true;
      _isFailed = false;
    });
    _reconnectAttempts++;
    LogService.write('重连尝试 #$_reconnectAttempts');
    int delayMs = 500 + (_reconnectAttempts * 200).clamp(0, 5000);
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (_isDisposed) return;
      _initPlayer();
    });
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
    } catch (_) {
      return url;
    }
  }

  void _retry() {
    _reconnectAttempts = 0;
    _initPlayer();
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
              const Icon(Icons.error_outline, color: Colors.white70, size: 48),
              const SizedBox(height: 16),
              const Text('加载失败', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _retry, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    if (_isLoading || !_isInitialized || _controller == null) {
      return Container(
        color: Colors.black,
        child: const Center(
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
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${_speed.toStringAsFixed(1)} M/s',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _speedTimer?.cancel();
    _stallMonitorTimer?.cancel();
    _controller?.removeListener(_onPlayerStateChanged);
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }
}
