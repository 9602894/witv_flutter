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
  bool _isReconnecting = false;      // 是否正在重连
  bool _isSwitching = false;         // 是否正在换台（无限重试中）

  static const int initTimeoutMs = 3000;
  static const int reconnectIntervalMs = 3000; // 断线重连间隔 3 秒
  double _speed = 0;
  bool _isPlaying = false;
  bool _isBuffering = false;

  // ============================================================
  // 生命周期
  // ============================================================
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
      // 触发换台（无限重试）
      _switchToNewUrl(widget.url);
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _cancelAllTimers();
    _controller?.removeListener(_onPlayerStateChanged);
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  // ============================================================
  // 换台（无限重试，取消所有其他任务）
  // ============================================================
  Future<void> _switchToNewUrl(String newUrl) async {
    if (_isDisposed) return;
    if (_isSwitching) {
      LogService.write('换台中，忽略重复请求');
      return;
    }

    // 标记切换中，取消所有定时器
    _isSwitching = true;
    _isReconnecting = false;
    _cancelAllTimers();

    // 释放旧控制器
    await _controller?.dispose();
    _controller = null;
    _isInitialized = false;
    _isLoading = true;
    _isFailed = false;
    setState(() {});

    LogService.write('开始换台: ${_extractChannelName(newUrl)}');

    // 无限循环尝试加载
    int attempt = 0;
    while (!_isDisposed && _isSwitching) {
      attempt++;
      LogService.write('换台尝试 #$attempt');
      try {
        final newController = _createController(newUrl);
        await newController.initialize().timeout(Duration(milliseconds: initTimeoutMs));
        if (_isDisposed || !_isSwitching) {
          // 如果已被取消，释放新控制器
          newController.dispose();
          return;
        }
        // 成功！
        _controller = newController;
        _currentUrl = newUrl;
        _isInitialized = true;
        _isLoading = false;
        _isFailed = false;
        _controller!.addListener(_onPlayerStateChanged);
        _controller!.play();
        // 恢复监测
        _startSpeedMonitor();
        _startStallMonitor();
        setState(() {});
        LogService.write('换台成功: $newUrl');
        // 退出循环
        _isSwitching = false;
        return;
      } catch (e) {
        LogService.write('换台尝试 #$attempt 失败: $e');
        if (_isDisposed || !_isSwitching) return;
        // 等待 1 秒后继续重试
        await Future.delayed(Duration(seconds: 1));
      }
    }
    // 如果因为 _isSwitching 被置 false 而退出（外部取消），不做特殊处理
    LogService.write('换台循环结束');
  }

  // 外部可调用此方法取消换台（例如在 dispose 中）
  void _cancelSwitching() {
    _isSwitching = false;
  }

  // ============================================================
  // 初始化播放器（首次加载）
  // ============================================================
  Future<void> _initPlayer() async {
    if (_isDisposed) return;
    // 若已在换台，则忽略
    if (_isSwitching) return;

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
      // 启动断线重连（3秒间隔，无限次）
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
    _cancelAllTimers(); // 取消其他定时器，避免干扰

    LogService.write('启动断线重连（3秒间隔）');
    _reconnectTimer = Timer.periodic(Duration(milliseconds: reconnectIntervalMs), (timer) {
      if (_isDisposed) {
        timer.cancel();
        return;
      }
      // 如果换台正在进行，暂停重连
      if (_isSwitching) return;
      LogService.write('重连尝试...');
      _initPlayer(); // 重新加载
    });
  }

  // 取消重连
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

  // -------- 状态监听（检测播放停止） --------
  void _onPlayerStateChanged() {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final value = _controller!.value;
    _isPlaying = value.isPlaying;
    _isBuffering = value.isBuffering;

    // 如果播放器异常停止（未结束且未缓冲），触发重连
    if (!value.isPlaying && !value.isBuffering && value.duration != null && value.duration!.inSeconds > 0) {
      LogService.write('播放器异常停止，触发重连');
      if (!_isSwitching && !_isReconnecting) {
        _startReconnect();
      }
    }
  }

  // -------- 定期检测卡顿（额外保障） --------
  void _startStallMonitor() {
    _stallMonitorTimer?.cancel();
    _stallMonitorTimer = Timer.periodic(Duration(seconds: 5), (timer) {
      if (_controller == null || !_controller!.value.isInitialized) return;
      final value = _controller!.value;
      // 如果卡在缓冲且未播放，且未在重连/换台中
      if (value.isBuffering && value.isPlaying == false && _isLoading == false) {
        LogService.write('检测到卡在缓冲，触发重连');
        if (!_isSwitching && !_isReconnecting) {
          _startReconnect();
        }
      }
    });
  }

  // -------- 速度监控 --------
  void _startSpeedMonitor() {
    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(Duration(seconds: 3), (timer) {
      if (_controller != null && _controller!.value.isInitialized) {
        // 模拟网速（可改为实际计算）
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

  // -------- 用户手动重试 --------
  void _retry() {
    _cancelAllTimers();
    _isSwitching = false;
    _isReconnecting = false;
    _initPlayer();
  }

  // ============================================================
  // Build
  // ============================================================
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
}
