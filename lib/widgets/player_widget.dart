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
  bool _isLoading = false;
  bool _hasError = false;
  bool _isDisposed = false;
  String _currentUrl = '';
  Timer? _speedTimer;

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
      _currentUrl = widget.url;
      _initPlayer();
    }
  }

  Future<void> _initPlayer() async {
    if (_isDisposed) return;
    // 取消旧控制器
    await _controller?.dispose();
    _controller = null;
    _isInitialized = false;
    _hasError = false;
    _isLoading = true;
    setState(() {});

    // 日志记录
    final proxyStatus = await _getProxyStatus();
    LogService.write('播放频道: ${_extractChannelName(_currentUrl)}，网络状态: $proxyStatus');

    try {
      _controller = VideoPlayerController.network(_currentUrl);
      // 设置超时 3 秒
      await _controller!.initialize().timeout(Duration(seconds: 3));
      if (_isDisposed) return;
      if (mounted) {
        setState(() {
          _isInitialized = true;
          _isLoading = false;
          _hasError = false;
        });
        _controller!.play();
        LogService.write('视频初始化成功: $_currentUrl');
        _startSpeedMonitor();
      }
    } catch (e) {
      if (_isDisposed) return;
      LogService.write('视频初始化失败: $e');
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
      widget.onError();
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
    if (_isLoading) {
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

    if (_hasError) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, color: Colors.white, size: 48),
              SizedBox(height: 10),
              Text('加载失败', style: TextStyle(color: Colors.white)),
              SizedBox(height: 10),
              ElevatedButton(
                onPressed: () {
                  _initPlayer();
                },
                child: Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isInitialized || _controller == null) {
      return Container(color: Colors.black);
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
    _controller?.dispose();
    _speedTimer?.cancel();
    super.dispose();
  }
}
