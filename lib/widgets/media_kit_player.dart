import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/log_service.dart';

class MediaKitPlayerWidget extends StatefulWidget {
  final String url;
  final VoidCallback onError;
  final Function(double speed) onSpeedUpdate;

  const MediaKitPlayerWidget({
    Key? key,
    required this.url,
    required this.onError,
    required this.onSpeedUpdate,
  }) : super(key: key);

  @override
  _MediaKitPlayerWidgetState createState() => _MediaKitPlayerWidgetState();
}

class _MediaKitPlayerWidgetState extends State<MediaKitPlayerWidget> {
  Player? _player;
  VideoController? _videoController;
  bool _isInitialized = false;
  bool _isLoading = true;
  bool _isFailed = false;
  bool _isDisposed = false;
  String _currentUrl = '';

  Timer? _speedTimer;
  Timer? _stallMonitorTimer;
  Timer? _reconnectTimer;
  bool _isReconnecting = false;
  bool _isSwitching = false;
  bool _switchCanceled = false;

  static const int switchTimeoutMs = 2500;
  static const int reconnectIntervalMs = 3000;
  static const int maxSwitchAttempts = 5;
  double _speed = 0;

  // 播放状态监听
  bool _wasPlaying = false;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
    _ensureMediaKitInitialized().then((_) {
      if (mounted && !_isDisposed) {
        _player = Player();
        _initPlayer();
      }
    }).catchError((e) {
      LogService.write('MediaKit 初始化最终失败: $e');
      if (mounted) {
        setState(() {
          _isFailed = true;
          _isLoading = false;
        });
      }
    });
  }

  Future<void> _ensureMediaKitInitialized() async {
    try {
      final test = Player();
      test.dispose();
      LogService.write('MediaKit 已初始化');
      return;
    } catch (_) {
      try {
        MediaKit.ensureInitialized();
        LogService.write('MediaKit 二次初始化成功');
        await Future.delayed(Duration(milliseconds: 200));
      } catch (e) {
        LogService.write('MediaKit 二次初始化失败: $e');
        rethrow;
      }
    }
  }

  @override
  void didUpdateWidget(MediaKitPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url && !_isDisposed && _player != null) {
      _switchToNewUrl(widget.url);
    }
  }

  // ==================== 换台（彻底释放旧播放器） ====================
  Future<void> _switchToNewUrl(String newUrl) async {
    if (_isDisposed || _player == null) return;
    if (_isSwitching) {
      _switchCanceled = true;
      await Future.delayed(Duration(milliseconds: 200));
    }
    _switchCanceled = false;
    _isSwitching = true;
    _isReconnecting = false;
    _cancelAllTimers();

    LogService.write('开始换台: ${_extractChannelName(newUrl)}');

    // 1. 释放旧播放器（立刻释放，节省资源）
    await _player?.stop();
    await _player?.dispose();
    _player = null;
    _videoController = null;
    _isInitialized = false;
    _isLoading = true;
    _isFailed = false;
    setState(() {});

    int attempt = 0;
    bool success = false;
    while (!_isDisposed && !_switchCanceled && _isSwitching && attempt < maxSwitchAttempts) {
      attempt++;
      LogService.write('换台尝试 #$attempt (超时 ${switchTimeoutMs}ms)');
      try {
        final newPlayer = Player();
        await newPlayer.open(
          Media(newUrl),
          play: true,
        ).timeout(Duration(milliseconds: switchTimeoutMs));

        if (_isDisposed || _switchCanceled || !_isSwitching) {
          newPlayer.dispose();
          break;
        }

        // 成功
        _player = newPlayer;
        _currentUrl = newUrl;
        _isInitialized = true;
        _isLoading = false;
        _isFailed = false;
        _videoController = VideoController(_player!);
        _startSpeedMonitor();
        _startStallMonitor();
        setState(() {});
        LogService.write('换台成功: $newUrl');
        success = true;
        _isSwitching = false;
        break;
      } catch (e) {
        LogService.write('换台尝试 #$attempt 失败: $e');
        if (_isDisposed || _switchCanceled || !_isSwitching) break;
        await Future.delayed(Duration(milliseconds: 500));
      }
    }

    if (!success && !_switchCanceled && !_isDisposed) {
      setState(() {
        _isLoading = false;
        _isFailed = true;
      });
      widget.onError();
      _startReconnect();
    }
    _isSwitching = false;
  }

  // ==================== 初始化播放器 ====================
  Future<void> _initPlayer() async {
    if (_isDisposed || _isSwitching) return;
    // 若已有旧播放器，先释放
    if (_player != null) {
      await _player!.stop();
      await _player!.dispose();
      _player = null;
      _videoController = null;
      _isInitialized = false;
    }
    _isLoading = true;
    _isFailed = false;
    _isReconnecting = false;
    _cancelAllTimers();
    setState(() {});

    LogService.write('加载频道: ${_extractChannelName(_currentUrl)}');

    try {
      _player = Player();
      await _player!.open(
        Media(_currentUrl),
        play: true,
      ).timeout(Duration(milliseconds: switchTimeoutMs));
      if (_isDisposed) return;
      _isInitialized = true;
      _isLoading = false;
      _isFailed = false;
      _videoController = VideoController(_player!);
      _startSpeedMonitor();
      _startStallMonitor();
      setState(() {});
      LogService.write('加载成功: $_currentUrl');
    } catch (e) {
      if (_isDisposed) return;
      LogService.write('加载失败: $e');
      await _player?.stop();
      await _player?.dispose();
      _player = null;
      setState(() {
        _isLoading = false;
        _isFailed = true;
      });
      widget.onError();
      _startReconnect();
    }
  }

  // ==================== 断线重连 ====================
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

  void _cancelAllTimers() {
    _speedTimer?.cancel();
    _stallMonitorTimer?.cancel();
    _cancelReconnect();
  }

  // ==================== 监控 ====================
  void _startStallMonitor() {
    if (_player == null) return;
    _stallMonitorTimer?.cancel();
    _stallMonitorTimer = Timer.periodic(Duration(seconds: 5), (timer) {
      if (_player == null || _isDisposed) return;
      final state = _player!.state;
      // 如果缓冲中且未播放，且不在加载状态，则触发重连
      if (state.buffering && !state.playing && !_isLoading) {
        LogService.write('检测到卡在缓冲，触发重连');
        if (!_isSwitching && !_isReconnecting) {
          _startReconnect();
        }
      }
      // 如果播放停止（且不是正常结束，即 duration > 0 且未播放）
      if (!state.playing && state.duration > const Duration(seconds: 0) && !state.buffering && !_isLoading) {
        LogService.write('播放停止，触发重连');
        if (!_isSwitching && !_isReconnecting) {
          _startReconnect();
        }
      }
    });
  }

  void _startSpeedMonitor() {
    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(Duration(seconds: 3), (timer) {
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

    return Stack(
      children: [
        Video(
          controller: _videoController!,
          fit: BoxFit.contain,
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
    _switchCanceled = true;
    _isSwitching = false;
    _cancelAllTimers();
    _player?.stop();
    _player?.dispose();
    _player = null;
    super.dispose();
  }
}
