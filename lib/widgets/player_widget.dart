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
  bool _isFailed = false;       // 是否加载失败
  bool _isDisposed = false;
  String _currentUrl = '';
  Timer? _speedTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int maxReconnectAttempts = 3;
  static const int initTimeoutMs = 1000;   // ★ 1秒超时
  static const int retryDelayMs = 200;     // ★ 200毫秒重试
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
      _isFailed = false;
      _hasError = false;
      _initPlayer();
    }
  }

  Future<void> _initPlayer() async {
    if (_isDisposed) return;
    // 清理旧控制器
    _controller?.removeListener(_onControllerListener);
    await _controller?.dispose();
    _controller = null;
    _isInitialized = false;
    _isLoading = true;
    _isFailed = false;
    _hasError = false;
    setState(() {});

    // 日志
    final proxyStatus = await _getProxyStatus();
    LogService.write('播放频道: ${_extractChannelName(_currentUrl)}，网络状态: $proxyStatus');

    // 创建新控制器
    _controller = VideoPlayerController.network(_currentUrl);
    _controller!.addListener(_onControllerListener);

    // 极速超时初始化
    try {
      await _controller!.initialize().timeout(Duration(milliseconds: initTimeoutMs));
      if (_isDisposed) return;
      if (mounted) {
        setState(() {
          _isInitialized = true;
          _isLoading = false;
          _isFailed = false;
        });
        _controller!.play();
        LogService.write('视频初始化成功: $_currentUrl');
        _startSpeedMonitor();
        _reconnectAttempts = 0;
        _isReconnecting = false;
      }
    } catch (e) {
      if (_isDisposed) return;
      LogService.write('视频初始化失败: $e (尝试 ${_reconnectAttempts+1}/$maxReconnectAttempts)');
      setState(() {
        _isLoading = false;
        _isFailed = true;
      });
      widget.onError();
      if (_reconnectAttempts < maxReconnectAttempts && !_isReconnecting) {
        _scheduleReconnect();
      } else {
        // 重试次数用尽，显示失败状态
        setState(() => _isFailed = true);
      }
    }
  }

  void _scheduleReconnect() {
    if (_isReconnecting) return;
    _isReconnecting = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: retryDelayMs), () {
      if (_isDisposed) return;
      _reconnectAttempts++;
      _isReconnecting = false;
      _initPlayer();
    });
  }

  void _onControllerListener() {
    if (_controller == null || _isDisposed) return;
    if (_controller!.value.hasError) {
      final error = _controller!.value.errorDescription ?? '未知错误';
      LogService.write('播放器错误: $error');
      if (!_hasError && !_isReconnecting && _reconnectAttempts < maxReconnectAttempts) {
        _hasError = true;
        _scheduleReconnect();
      } else {
        setState(() => _isFailed = true);
      }
    } else {
      _hasError = false;
    }
  }

  // 手动重试按钮点击
  void _retry() {
    if (_isDisposed) return;
    _reconnectAttempts = 0;
    _isReconnecting = false;
    _isFailed = false;
    _initPlayer();
  }

  Future<String> _getProxyStatus() async {
    try {
      final httpProxy = Platform.environment['http_proxy'] ?? Platform.environment['HTTP_PROXY'];
      final httpsProxy = Platform.environment['https_proxy'] ?? Platform.environment['HTTPS_PROXY'];
      if ((httpProxy != null && httpProxy.isNotEmpty) || (httpsProxy != null && httpsProxy.isNotEmpty)) {
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

  void _startSpeedMonitor() {
    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(Duration(seconds: 3), (timer) {
      if (_controller != null && _controller!.value.isInitialized) {
        double simulatedSpeed = 0.5 + (DateTime.now().millisecond % 10) / 2;
        setState(() {
          _speed = simulatedSpeed;
          widget.onSpeedUpdate(simulatedSpeed);
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 加载失败状态
    if (_isFailed) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, color: Colors.white70, size: 48),
              SizedBox(height: 16),
              Text('加载失败', style: TextStyle(color: Colors.white70, fontSize: 16)),
              SizedBox(height: 16),
              ElevatedButton(
                onPressed: _retry,
                child: Text('重试'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              ),
            ],
          ),
        ),
      );
    }

    // 加载中状态
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

    // 正常播放
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
    _controller?.removeListener(_onControllerListener);
    _controller?.dispose();
    _speedTimer?.cancel();
    _reconnectTimer?.cancel();
    super.dispose();
  }
}
