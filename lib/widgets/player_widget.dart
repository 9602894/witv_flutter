import 'dart:async';
import 'dart:math';
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
  VideoPlayerController? _nextController;
  bool _isInitialized = false;
  bool _isLoading = true;
  bool _isFailed = false;
  bool _isDisposed = false;
  bool _isSwitching = false;
  String _currentUrl = '';
  Timer? _speedTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;

  static const int maxReconnectAttempts = 5;
  static const int initTimeoutMs = 8000;
  static const int retryBaseDelayMs = 1000;
  static const int retryMaxDelayMs = 10000;

  double _speed = 0;
  int _lastUpdateTime = 0;
  int _lastPosition = 0;

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
      setState(() => _isSwitching = true);
      _preloadPlayer();
    }
  }

  // 视频格式检测（仅用于 formatHint，加速初始化）
  VideoFormat _detectFormat(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8') || lower.contains('hls')) return VideoFormat.hls;
    if (lower.contains('.mpd') || lower.contains('dash')) return VideoFormat.dash;
    // mp4/mov 等使用 VideoFormat.other（原 VideoFormat.mp4 不存在）
    return VideoFormat.other;
  }

  Future<void> _preloadPlayer() async {
    if (_isDisposed) return;

    LogService.write('预加载频道: ${_extractChannelName(_currentUrl)}');

    final oldPreload = _nextController;
    _nextController = null;

    try {
      _nextController = VideoPlayerController.network(
        _currentUrl,
        formatHint: _detectFormat(_currentUrl),
      );

      await _nextController!.initialize().timeout(
        const Duration(milliseconds: initTimeoutMs),
      );

      if (_isDisposed) {
        await _nextController?.dispose();
        return;
      }

      LogService.write('预加载成功: $_currentUrl');
      _swapController();
    } catch (e) {
      LogService.write('预加载失败: $e，回退直接加载');
      await _nextController?.dispose();
      _nextController = null;
      _initPlayer();
    } finally {
      await oldPreload?.dispose();
    }
  }

  void _swapController() {
    if (_nextController == null || _isDisposed) return;

    final oldController = _controller;
    oldController?.removeListener(_onControllerListener);

    _controller = _nextController;
    _nextController = null;
    _isInitialized = true;
    _isLoading = false;
    _isFailed = false;
    _isSwitching = false;
    _reconnectAttempts = 0;

    _controller!.addListener(_onControllerListener);
    _controller!.play();

    if (oldController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await oldController.dispose();
      });
    }

    if (mounted) setState(() {});
    _startSpeedMonitor();
    LogService.write('切换完成: $_currentUrl');
  }

  Future<void> _initPlayer() async {
    if (_isDisposed) return;

    final oldController = _controller;
    _controller = null;
    _isInitialized = false;
    _isLoading = true;
    _isFailed = false;
    _isSwitching = false;

    if (mounted) setState(() {});

    if (oldController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await oldController.dispose();
      });
    }

    LogService.write('直接加载频道: ${_extractChannelName(_currentUrl)}');

    try {
      _controller = VideoPlayerController.network(
        _currentUrl,
        formatHint: _detectFormat(_currentUrl),
      );

      await _controller!.initialize().timeout(
        const Duration(milliseconds: initTimeoutMs),
      );

      if (_isDisposed) {
        await _controller?.dispose();
        return;
      }

      _isInitialized = true;
      _isLoading = false;
      if (mounted) setState(() {});
      _controller!.play();
      LogService.write('直接加载成功: $_currentUrl');
      _startSpeedMonitor();
      _reconnectAttempts = 0;
    } catch (e) {
      if (_isDisposed) return;
      LogService.write('直接加载失败: $e');
      _isLoading = false;
      _isFailed = true;
      if (mounted) setState(() {});
      widget.onError();
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= maxReconnectAttempts) {
      if (mounted) setState(() => _isFailed = true);
      LogService.write('重试次数已达上限');
      return;
    }

    _reconnectTimer?.cancel();
    final delay = min(
      retryBaseDelayMs * pow(2, _reconnectAttempts).toInt(),
      retryMaxDelayMs,
    );

    LogService.write('计划 ${delay}ms 后第 ${_reconnectAttempts + 1} 次重试');

    _reconnectTimer = Timer(Duration(milliseconds: delay), () {
      if (_isDisposed) return;
      _reconnectAttempts++;
      _initPlayer();
    });
  }

  void _onControllerListener() {
    if (_controller == null || _isDisposed) return;

    final value = _controller!.value;

    if (value.hasError) {
      LogService.write('播放错误: ${value.errorDescription}');
      _controller!.removeListener(_onControllerListener);
      _controller!.pause();

      if (_reconnectAttempts < maxReconnectAttempts) {
        _scheduleReconnect();
      } else {
        if (mounted) setState(() => _isFailed = true);
      }
      return;
    }

    if (value.isBuffering && value.isPlaying) {
      // 可每 10 次打印一次，暂保持原样
      LogService.write('检测到缓冲...');
    }
  }

  void _retry() {
    _reconnectAttempts = 0;
    _isFailed = false;
    _initPlayer();
  }

  void _startSpeedMonitor() {
    _speedTimer?.cancel();
    _lastUpdateTime = DateTime.now().millisecondsSinceEpoch;
    _lastPosition = _controller?.value.position.inMilliseconds ?? 0;

    _speedTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (_controller == null || !_controller!.value.isInitialized || _isDisposed) {
        return;
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final currentPos = _controller!.value.position.inMilliseconds;
      final timeDiff = (now - _lastUpdateTime) / 1000.0;

      if (timeDiff > 0) {
        final posDiff = (currentPos - _lastPosition) / 1000.0;
        final actualSpeed = posDiff / timeDiff;
        final displaySpeed = (actualSpeed * 0.8).clamp(0.1, 50.0);

        _speed = displaySpeed;
        _lastUpdateTime = now;
        _lastPosition = currentPos;

        widget.onSpeedUpdate(displaySpeed);

        if (mounted && !_isLoading && !_isFailed) {
          setState(() {});
        }
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

    if (_isLoading && !_isSwitching) {
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

    if (_controller != null && _isInitialized) {
      return Stack(
        children: [
          VideoPlayer(_controller!),
          if (_isSwitching)
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

    return Container(color: Colors.black);
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
