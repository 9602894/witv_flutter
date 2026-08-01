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
  Timer? _stallMonitorTimer;

  // 重连相关
  Timer? _reconnectTimer;
  bool _isReconnecting = false;
  static const int reconnectIntervalMs = 3000;

  // 换台相关
  bool _isSwitching = false;
  bool _switchCanceled = false;
  static const int switchTimeoutMs = 1500; // 1.5秒超时

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
      _switchToNewUrl(widget.url);
    }
  }

  // ============================================================
  // 换台（无限重试，但快速超时，重试间隔短）
  // ============================================================
  Future<void> _switchToNewUrl(String newUrl) async {
    if (_isDisposed) return;
    // 取消之前的换台
    _switchCanceled = true; // 让旧循环退出
    // 等待旧循环结束（最多100ms）
    await Future.delayed(Duration(milliseconds: 100));
    _switchCanceled = false;
    if (_isDisposed) return;

    // 标记切换中，取消所有定时器
    _isSwitching = true;
    _isReconnecting = false;
    _cancelAllTimers();
    _controller?.removeListener(_onPlayerStateChanged);
    await _controller?.dispose();
    _controller = null;
    _isInitialized = false;
    _isLoading = true;
    _isFailed = false;
    setState(() {});

    LogService.write('开始换台: ${_extractChannelName(newUrl)}');

    // 无限循环，直到成功或被取消
    int attempt = 0;
    while (!_isDisposed && !_switchCanceled && _isSwitching) {
      attempt++;
      LogService.write('换台尝试 #$attempt (超时 ${switchTimeoutMs}ms)');
      try {
        final newController = _createController(newUrl);
        await newController.initialize().timeout(Duration(milliseconds: switchTimeoutMs));
        if (_isDisposed || _switchCanceled || !_isSwitching) {
          newController.dispose();
          break;
        }
        // 成功！
        _controller = newController;
        _currentUrl = newUrl;
        _isInitialized = true;
        _isLoading = false;
        _isFailed = false;
        _controller!.addListener(_onPlayerStateChanged);
        _controller!.play();
        _startSpeedMonitor();
        _startStallMonitor();
        setState(() {});
        LogService.write('换台成功: $newUrl');
        // 退出循环
        _isSwitching = false;
        return;
      } catch (e) {
        LogService.write('换台尝试 #$attempt 失败: $e');
        if (_isDisposed || _switchCanceled || !_isSwitching) break;
        // 等待 500ms 后重试
        await Future.delayed(Duration(milliseconds: 500));
      }
    }
    // 如果因为取消而退出，不做特殊处理
    _isSwitching = false;
    if (!_switchCanceled && !_isDisposed && _controller == null) {
      // 如果循环退出但没有成功且未被取消，说明彻底失败，触发重连
      setState(() {
        _isLoading = false;
        _isFailed = true;
      });
      widget.onError();
      _startReconnect();
    }
  }

  // ============================================================
  // 初始化播放器（首次加载）
  // ============================================================
  Future<void> _initPlayer() async {
    if (_isDisposed || _isSwitching) return;
    await _controller?.dispose();
    _controller = null;
    _isInitialized = false;
    _isLoading = true;
    _isFailed = false;
    _isReconnecting = false;
    _cancelAllTimers();
    setState(() {});

    LogService.write('加载频道: ${_extractChannelName(_currentUrl)}');

    try {
      _controller = _createController(_currentUrl);
      _controller!.addListener(_onPlayerStateChanged);
      await _controller!.initialize().timeout(Duration(milliseconds: switchTimeoutMs));
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
      _startReconnect();
    }
  }

  // ============================================================
  // 断线重连（3秒间隔，无限次）
  // ============================================================
  void _startReconnect() {
    if (_isDisposed || _isSwitching) return;
    if (_isReconnecting) return;
    _isReconnecting = true;
    _cancelAllTimers();

    LogService.write('启动断线重连（3秒间隔）');
    _reconnectTimer = Timer.periodic(Duration(milliseconds: reconnectIntervalMs), (timer) {
      if (_isDisposed || _isSwitching) {
        timer.cancel();
        return;
      }
      LogService.write('重连尝试...');
      _initPlayer();
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _isReconnecting = false;
  }

  // ============================================================
  // 辅助方法
  // ============================================================
  void _cancelAllTimers() {
    _speedTimer?.cancel();
    _stallMonitorTimer?.cancel();
    _cancelReconnect();
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
    );
  }

  void _onPlayerStateChanged() {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final value = _controller!.value;
    if (!value.isPlaying && !value.isBuffering && value.duration != null && value.duration!.inSeconds > 0) {
      LogService.write('播放器异常停止，触发重连');
      if (!_isSwitching && !_isReconnecting) {
        _startReconnect();
      }
    }
  }

  void _startStallMonitor() {
    _stallMonitorTimer?.cancel();
    _stallMonitorTimer = Timer.periodic(Duration(seconds: 5), (timer) {
      if (_controller == null || !_controller!.value.isInitialized) return;
      final value = _controller!.value;
      if (value.isBuffering && value.isPlaying == false && _isLoading == false) {
        LogService.write('检测到卡在缓冲，触发重连');
        if (!_isSwitching && !_isReconnecting) {
          _startReconnect();
        }
      }
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
    _cancelAllTimers();
    _switchCanceled = true;
    _isSwitching = false;
    _isReconnecting = false;
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
    _switchCanceled = true;
    _isSwitching = false;
    _cancelAllTimers();
    _controller?.removeListener(_onPlayerStateChanged);
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }
}
