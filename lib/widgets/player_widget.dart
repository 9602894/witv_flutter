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

  @override
  void initState() {
    super.initState();
    _initPlayer(widget.url);
  }

  /// 检测当前网络是否经过代理/VPN（同步方法）
  Future<String> _getProxyStatus() async {
    try {
      // 1. 检查环境变量代理（适用于手动设置 http_proxy）
      final httpProxy = Platform.environment['http_proxy'] ??
                         Platform.environment['HTTP_PROXY'];
      final httpsProxy = Platform.environment['https_proxy'] ??
                          Platform.environment['HTTPS_PROXY'];
      if ((httpProxy != null && httpProxy.isNotEmpty) ||
          (httpsProxy != null && httpsProxy.isNotEmpty)) {
        return '代理 (环境变量)';
      }

      // 2. 检查网络接口是否存在虚拟 VPN 接口
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        includeLoopback: false,
      );
      
      // 收集所有接口名称用于日志
      final interfaceNames = interfaces.map((i) => i.name).join(', ');
      LogService.write('检测到的网络接口: $interfaceNames');

      // 常见 VPN 接口名称关键词
      const vpnKeywords = ['tun', 'ppp', 'utun', 'tap', 'wg', 'ipsec'];
      for (var iface in interfaces) {
        if (!iface.isUp) continue; // 只检测活跃接口
        final name = iface.name.toLowerCase();
        for (var keyword in vpnKeywords) {
          if (name.contains(keyword)) {
            // 额外记录接口详细信息
            final addresses = iface.addresses.map((a) => a.address).join(', ');
            LogService.write('发现 VPN 接口: ${iface.name} (地址: $addresses)');
            return 'VPN ($keyword 接口)';
          }
        }
      }

      return '直连';
    } catch (e) {
      LogService.write('检测代理状态失败: $e');
      return '未知 (检测失败)';
    }
  }

  void _initPlayer(String url) async {
    _currentUrl = url;
    _controller?.dispose();

    // 检测代理状态（异步）
    final proxyStatus = await _getProxyStatus();
    LogService.write('播放频道: ${_extractChannelName(url)}，网络状态: $proxyStatus');

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
        // 在错误日志中再次记录网络状态
        _getProxyStatus().then((status) {
          LogService.write('播放失败时网络状态: $status');
        });
        widget.onError();
        if (!_isReconnecting) {
          _attemptReconnect();
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
