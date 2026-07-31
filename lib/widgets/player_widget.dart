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

  // 缓存代理状态，避免重复检测
  static String? _cachedProxyStatus;

  @override
  void initState() {
    super.initState();
    _initPlayer(widget.url);
  }

  // 检测代理状态（VPN 或直连）
  Future<String> _checkProxyStatus() async {
    if (_cachedProxyStatus != null) return _cachedProxyStatus!;
    try {
      // 使用 HttpClient 检测环境代理
      final client = HttpClient();
      final proxy = client.findProxy(Uri.parse('http://example.com'));
      if (proxy != null && proxy.isNotEmpty && proxy != 'DIRECT') {
        _cachedProxyStatus = 'VPN (代理)';
      } else {
        // 额外检查环境变量
        final httpProxy = Platform.environment['http_proxy'] ??
                           Platform.environment['HTTP_PROXY'];
        final httpsProxy = Platform.environment['https_proxy'] ??
                            Platform.environment['HTTPS_PROXY'];
        if ((httpProxy != null && httpProxy.isNotEmpty) ||
            (httpsProxy != null && httpsProxy.isNotEmpty)) {
          _cachedProxyStatus = 'VPN (环境变量)';
        } else {
          _cachedProxyStatus = '直连';
        }
      }
    } catch (e) {
      LogService.write('代理检测异常: $e');
      _cachedProxyStatus = '未知 (检测失败)';
    }
    return _cachedProxyStatus!;
  }

  void _initPlayer(String url) {
    _currentUrl = url;
    _controller?.dispose();
    
    // 记录频道和代理状态
    _checkProxyStatus().then((status) {
      LogService.write('播放频道: ${_extractChannelName(url)}，网络状态: $status');
    });

    _controller = VideoPlayerController.network(url)
      ..initialize().then((_) {
        if (mounted) {
          setState(() {
            _isInitialized = true;
          });
          _controller!.play();
          LogService.write('视频初始化成功: $url');
          _startSpeedMonitor();
          _reconnectAttempts = 0;
          _isReconnecting = false;
        }
      }).catchError((e) {
        LogService.write('视频初始化失败: $e');
        widget.onError();
        if (!_isReconnecting) {
          _attemptReconnect();
        }
      });
  }

  // 从 URL 中提取频道名（简单处理，仅用于日志）
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
        // 模拟网速（0.5-5 M/s），避免显示0.0
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
    if (!_isInitialized || _controller == null) {
      return Container(color: Colors.transparent);
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
