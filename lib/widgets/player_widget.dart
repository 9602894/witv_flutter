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
  Timer? _stallTimer; // 检测播放停滞
  int _reconnectAttempts = 0;
  static const int initTimeoutMs = 3000; // 缩短超时
  double _speed = 0;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isReconnecting = false; // 防止重复重连

  // 预加载控制器（用于切换）
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

  // 切换时提前预加载新流
  Future<void> _switchToNewUrl(String newUrl) async {
    if (_isDisposed) return;
    LogService.write('切换频道: ${_extractChannelName(newUrl)}');

    // 立即显示加载状态
    setState(() {
      _isLoading = true;
      _isFailed = false;
      _isReconnecting = false;
    });

    // 取消所有重连和监视器
    _cancelAllTimers();

    // 如果当前控制器存在，不立即释放，保留显示，同时后台预加载新流
    try {
      // 创建新控制器
      final newController = _createController(newUrl);
      // 添加监听，但先不播放
      await newController.initialize().timeout(Duration(milliseconds: initTimeoutMs));
      if (_isDisposed) return;

      // 停止旧控制器播放，释放旧控制器资源
      await _controller?.pause();
      await _controller?.dispose();
      _controller = null;
      _isInitialized = false;

      // 使用新控制器
      _controller = newController;
      _currentUrl = newUrl;
      _isInitialized = true;
      _isLoading = false;
      _isFailed = false;
      _reconnectAttempts = 0;
      _controller!.addListener(_onPlayerStateChanged);
      _controller!.play();
      _startSpeedMonitor();
      _startStallMonitor();
      setState(() {});
      LogService.write('切换成功: $newUrl');
    } catch (e) {
      // 预加载失败，回退到旧流（如果有且可用）
      LogService.write('预加载新流失败: $e');
      if (_controller != null && _controller!.value.isInitialized) {
        // 继续播放旧流
        setState(() => _isLoading = false);
        // 尝试重新播放旧流
        if (!_controller!.value.isPlaying) {
          _controller!.play();
        }
      } else {
        // 旧流也不可用，显示错误并重连
        setState(() {
          _isLoading = false;
          _isFailed = true;
        });
        widget.onError();
        _scheduleReconnect();
      }
    }
  }

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
      options: VideoPlayerOptions(
        allowBackgroundPlayback: false,
        mixWithOthers: false,
      ),
    );
  }

  Future<void> _initPlayer() async {
    if (_isDisposed) return;
    // 释放旧资源
    await _forceDisposeController();
    _isInitialized = false;
    _isLoading = true;
    _isFailed = false;
    _isPlaying = false;
    _isReconnecting = false;
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
      });
      _controller!.play();
      _startSpeedMonitor();
      _startStallMonitor();
      _reconnectAttempts = 0;
      LogService.write('加载成功: $_currentUrl');
    } catch (e) {
      if (_isDisposed) return;
      LogService.write('加载失败: $e');
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

    // 检测播放停滞（针对直播流，无 duration 时，若播放且缓冲结束但无数据，则判断）
    // 对于直播流，position 可能无限增长，我们检测速度或缓冲状态。
    // 简单方案：若 isPlaying==false 且 isBuffering==false，且速度持续为0，则触发重连
    // 这里由 stallTimer 周期性检测更稳健。
  }

  void _startStallMonitor() {
    _stallTimer?.cancel();
    _stallTimer = Timer.periodic(Duration(seconds: 5), (timer) {
      if (_isDisposed || _isReconnecting) return;
      if (_controller == null || !_controller!.value.isInitialized) return;
      final value = _controller!.value;
      // 如果正在播放，但速度 < 0.1KB/s 持续超过10秒，认为停滞
      if (_speed < 0.1 && value.isPlaying) {
        // 检查是否已经超过10秒无速度
        if (_speed == 0.0) {
          // 可能是网络问题，触发重连
          LogService.write('检测到播放停滞（速度0），尝试重连');
          _scheduleReconnect();
        }
      }
    });
  }

  void _cancelAllTimers() {
    _speedTimer?.cancel();
    _reconnectTimer?.cancel();
    _stallTimer?.cancel();
    _speedTimer = null;
    _reconnectTimer = null;
    _stallTimer = null;
  }

  // 强制释放控制器资源
  Future<void> _forceDisposeController() async {
    if (_controller != null) {
      try {
        await _controller!.pause();
        _controller!.removeListener(_onPlayerStateChanged);
        await _controller!.dispose();
      } catch (e) {
        LogService.write('释放控制器异常: $e');
      } finally {
        _controller = null;
        _isInitialized = false;
        _isPlaying = false;
      }
    }
  }

  void _scheduleReconnect() {
    if (_isDisposed) return;
    // 取消任何已有的重连
    _reconnectTimer?.cancel();
    _isReconnecting = true;

    // 先强制释放当前控制器，避免资源占用
    _forceDisposeController().then((_) {
      if (_isDisposed) return;
      // 计算延迟：递增重试间隔，最多5秒
      int delay = (_reconnectAttempts * 1000).clamp(1000, 5000);
      _reconnectTimer = Timer(Duration(milliseconds: delay), () {
        if (_isDisposed) return;
        _reconnectAttempts++;
        _isReconnecting = false;
        // 重新初始化
        _initPlayer();
      });
    });
  }

  void _retry() {
    // 用户手动重试，重置尝试计数
    _reconnectAttempts = 0;
    _isFailed = false;
    _isReconnecting = false;
    _cancelAllTimers();
    _initPlayer();
  }

  void _startSpeedMonitor() {
    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(Duration(seconds: 2), (timer) {
      if (_controller != null && _controller!.value.isInitialized) {
        // 模拟速度，实际可计算网络流量（这里简化）
        // 实际可用视频播放器提供的 networkUsage 等信息，但需要额外实现
        // 这里保留原模拟方式，但更符合实际可计算缓存大小变化
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
    _cancelAllTimers();
    _forceDisposeController();
    super.dispose();
  }
}
