import 'dart:async';
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
  static Player? _player; // 全局单例播放器
  VideoController? _videoController;
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

  // 缓冲状态
  bool _isBuffering = false;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
    _initPlayer();
  }

  // 初始化全局播放器（仅一次）
  Future<void> _initGlobalPlayer() async {
    if (_player != null) return;
    _player = Player(
      configuration: const PlayerConfiguration(
        // 核心优化：极低缓存，类似酷9的 analyzeduration = 1
        // libmpv 参数：cache-secs=0.5, demuxer-max-bytes=10M
        // 这里通过 extra 传递 mpv 参数
        extra: {
          'cache-secs': '0.5',
          'demuxer-max-bytes': '10M',
          'demuxer-readahead-secs': '1',
          'network-timeout': '5',
        },
      ),
    );
    // 监听缓冲状态
    _player!.stream.buffering.listen((buffering) {
      if (mounted) {
        setState(() => _isBuffering = buffering);
      }
    });
    // 监听播放状态
    _player!.stream.position.listen((position) {
      // 可更新进度
    });
  }

  Future<void> _initPlayer() async {
    if (_isDisposed) return;
    await _initGlobalPlayer();

    _isLoading = true;
    _isFailed = false;
    _isInitialized = false;
    setState(() {});

    LogService.write('media_kit 播放频道: ${_extractChannelName(_currentUrl)}');

    try {
      // 如果已有视频控制器，先断开
      _videoController?.dispose();
      _videoController = VideoController(_player!);

      // 打开新媒体（超时控制）
      await _player!.open(
        Media(_currentUrl),
        play: true,
      ).timeout(const Duration(seconds: 5));

      if (_isDisposed) return;

      setState(() {
        _isInitialized = true;
        _isLoading = false;
        _isFailed = false;
      });

      LogService.write('media_kit 初始化成功: $_currentUrl');
      _startSpeedMonitor();
      _reconnectAttempts = 0;
    } catch (e) {
      if (_isDisposed) return;
      LogService.write('media_kit 初始化失败: $e');
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

  void _retry() {
    _reconnectAttempts = 0;
    _isFailed = false;
    _initPlayer();
  }

  @override
  void didUpdateWidget(PlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url && !_isDisposed) {
      _currentUrl = widget.url;
      _reconnectAttempts = 0;
      _isFailed = false;
      // 直接切换，无需重建播放器
      _initPlayer();
    }
  }

  void _startSpeedMonitor() {
    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (_player == null || !_player!.state.playing) {
        return;
      }
      // 模拟速度显示
      double simulatedSpeed = 0.5 + (DateTime.now().millisecond % 10) / 2;
      setState(() => _speed = simulatedSpeed);
      widget.onSpeedUpdate(simulatedSpeed);
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

    if (_isLoading || !_isInitialized || _videoController == null) {
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

    // 实际播放
    return Stack(
      children: [
        Video(
          controller: _videoController!,
          controls: NoVideoControls, // 无原生控件
        ),
        // 缓冲指示器
        if (_isBuffering)
          Container(
            color: Colors.black26,
            child: const Center(
              child: SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              ),
            ),
          ),
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
    _videoController?.dispose();
    // 不 dispose _player，保持复用
    _speedTimer?.cancel();
    _reconnectTimer?.cancel();
    super.dispose();
  }
}
