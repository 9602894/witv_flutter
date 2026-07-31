import 'dart:async';
import 'dart:io';
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
  bool _isDisposed = false;
  String _currentUrl = '';
  Timer? _speedTimer;
  Timer? _refreshTimer; // 断线刷新定时器
  int _reconnectAttempts = 0;
  static const int maxReconnectAttempts = 5;
  double _speed = 0;
  bool _isReconnecting = false;
  bool _hasError = false;

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
      _isReconnecting = false;
      _hasError = false;
      _initPlayer();
    }
  }

  // 强制销毁并重建播放器
  Future<void> _initPlayer() async {
    if (_isDisposed) return;
    // 取消所有定时器
    _refreshTimer?.cancel();
    _speedTimer?.cancel();

    // 强制释放旧控制器（同步清除监听）
    if (_controller != null) {
      _controller!.removeListener(_onControllerListener);
      await _controller!.dispose();
      _controller = null;
    }

    _isInitialized = false;
    _isLoading = true;
    _hasError = false;
    if (mounted) setState(() {});

    // 记录代理状态（仅日志）
    final proxyStatus = await _getProxyStatus();
    LogService.write('播放频道: ${_extractChannelName(_currentUrl)}，网络状态: $proxyStatus');

    try {
      _controller = VideoPlayerController.network(_currentUrl);
      _controller!.addListener(_onControllerListener);
      // 不设置超时，让播放器自己处理
      await _controller!.initialize();
      if (_isDisposed || !mounted) return;
      setState(() {
        _isInitialized = true;
        _isLoading = false;
        _hasError = false;
      });
      _controller!.play();
      LogService.write('视频初始化成功: $_currentUrl');
      _startSpeedMonitor();
      _startRefreshTimer(); // 启动断线检测
      _reconnectAttempts = 0;
      _isReconnecting = false;
    } catch (e) {
      if (_isDisposed || !mounted) return;
      LogService.write('视频初始化失败: $e');
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
      widget.onError();
      if (!_isReconnecting && _reconnectAttempts < maxReconnectAttempts) {
        _attemptReconnect();
      }
    }
  }

  void _onControllerListener() {
    if (_controller == null || _isDisposed) return;
    final value = _controller!.value;
    // 检测播放停止或错误
    if (value.hasError) {
      LogService.write('播放器错误: ${value.errorDescription}');
      if (!_isReconnecting && !_hasError) {
        _hasError = true;
        _attemptReconnect();
      }
    }
    // 如果播放器停止且未结束，尝试刷新
    if (!value.isPlaying && value.duration > Duration.zero && !value.isCompleted) {
      if (!_isReconnecting && !_hasError && _isInitialized) {
        LogService.write('播放器非正常停止，尝试刷新');
        _attemptReconnect();
      }
    }
  }

  // 断线刷新定时器（每秒检测）
  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (_isDisposed || _controller == null || !_isInitialized) return;
      final value = _controller!.value;
      // 如果缓冲中且超过5秒未恢复，强制刷新
      if (value.isBuffering) {
        if (timer.tick > 5 && !_isReconnecting) {
          LogService.write('缓冲超时，强制刷新');
          _attemptReconnect();
        }
      }
      // 如果播放停止且非正常结束
      if (!value.isPlaying && !value.isCompleted && !value.isBuffering && value.duration > Duration.zero) {
        if (!_isReconnecting) {
          LogService.write('播放停止，尝试刷新');
          _attemptReconnect();
        }
      }
    });
  }

  void _attemptReconnect() {
    if (_isReconnecting || _reconnectAttempts >= maxReconnectAttempts || _isDisposed) {
      if (_reconnectAttempts >= maxReconnectAttempts) {
        LogService.write('重连次数已达上限，停止重试');
      }
      return;
    }
    _isReconnecting = true;
    _reconnectAttempts++;
    LogService.write('尝试重连，第 $_reconnectAttempts 次');
    // 强制重新初始化播放器
    _initPlayer();
  }

  void _startSpeedMonitor() {
    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(Duration(seconds: 3), (timer) {
      if (_controller != null && _controller!.value.isInitialized) {
        // 模拟网速（0.5-5 M/s）
        double simulatedSpeed = 0.5 + (DateTime.now().millisecond % 10) / 2;
        setState(() {
          _speed = simulatedSpeed;
          widget.onSpeedUpdate(simulatedSpeed);
        });
      }
    });
  }

  String _extractChannelName(String url) {
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;
      if (segments.isNotEmpty) {
        return segments.last.split('.').first;
      }
      return url;
    } catch (_) {
      return url;
    }
  }

  Future<String> _getProxyStatus() async {
    try {
      final httpProxy = Platform.environment['http_proxy'] ?? Platform.environment['HTTP_PROXY'];
      final httpsProxy = Platform.environment['https_proxy'] ?? Platform.environment['HTTPS_PROXY'];
      if ((httpProxy != null && httpProxy.isNotEmpty) ||
          (httpsProxy != null && httpsProxy.isNotEmpty)) {
        return '代理 (环境变量)';
      }
      final interfaces = await NetworkInterface.list(includeLinkLocal: false);
      for (var iface in interfaces) {
        if (iface.name.contains('tun') || iface.name.contains('ppp') || iface.name.contains('utun')) {
          return 'VPN (虚拟接口)';
        }
      }
      return '直连';
    } catch (e) {
      return '未知';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || !_isInitialized || _controller == null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 10),
              Text(_hasError ? '播放失败，正在重试...' : '加载中...', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _controller!.value.size.width,
              height: _controller!.value.size.height,
              child: VideoPlayer(_controller!),
            ),
          ),
        ),
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
    _refreshTimer?.cancel();
    _speedTimer?.cancel();
    _reconnectTimer?.cancel();
    if (_controller != null) {
      _controller!.removeListener(_onControllerListener);
      _controller!.dispose();
    }
    super.dispose();
  }
}
