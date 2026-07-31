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
  String _currentUrl = '';
  Timer? _speedTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int maxReconnectAttempts = 10;
  double _speed = 0;
  bool _isReconnecting = false;

  // ★ 新增：加载状态
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initPlayer(widget.url);
  }

  // ★ 优化：使用 Future.microtask 让 UI 先更新，再初始化播放器
  void _initPlayer(String url) {
    _currentUrl = url;
    _isLoading = true;
    setState(() {}); // 立即显示加载状态

    // 取消旧控制器，但不立即 dispose，让旧播放器继续播放直到新控制器准备好
    // 但我们直接 dispose 并创建新的，因为 video_player 不支持复用
    _controller?.dispose();

    // 延迟一帧，让 UI 先刷新
    Future.microtask(() {
      _createController(url);
    });
  }

  void _createController(String url) async {
    // 先检测网络状态（仅日志）
    final proxyStatus = await _getProxyStatus();
    LogService.write('播放频道: ${_extractChannelName(url)}，网络状态: $proxyStatus');

    _controller = VideoPlayerController.network(url)
      ..initialize().then((_) {
        if (mounted) {
          setState(() {
            _isInitialized = true;
            _isLoading = false;
          });
          _controller!.play();
          LogService.write('视频初始化成功: $url');
          _startSpeedMonitor();
          _reconnectAttempts = 0;
          _isReconnecting = false;
        }
      }).catchError((e) {
        LogService.write('视频初始化失败: $e');
        setState(() {
          _isLoading = false;
        });
        widget.onError();
        if (!_isReconnecting) {
          _attemptReconnect();
        }
      });
  }

  // 检测代理状态（仅日志）
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

  void _attemptReconnect() {
    if (_reconnectAttempts >= maxReconnectAttempts || _isReconnecting) {
      LogService.write('重连次数过多或正在重连，停止');
      return;
    }
    _isReconnecting = true;
    _reconnectAttempts++;
    LogService.write('尝试重连，第 $_reconnectAttempts 次');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: 3), () {
      if (mounted && !_isInitialized) {
        _initPlayer(_currentUrl);
      } else {
        _isReconnecting = false;
      }
    });
  }

  @override
  void didUpdateWidget(PlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _isReconnecting = false;
      _reconnectAttempts = 0;
      _isInitialized = false;
      _initPlayer(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    // ★ 显示加载状态
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
    _controller?.dispose();
    _speedTimer?.cancel();
    _reconnectTimer?.cancel();
    super.dispose();
  }
}
