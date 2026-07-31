import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';
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
  VlcPlayerController? _controller;
  bool _isInitialized = false;
  bool _isLoading = true;
  bool _isFailed = false;
  bool _isDisposed = false;
  String _currentUrl = '';
  Timer? _speedTimer;
  int _reconnectAttempts = 0;
  static const int maxReconnectAttempts = 2;
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
      _reconnectAttempts = 0;
      _initPlayer();
    }
  }

  Future<void> _initPlayer() async {
    if (_isDisposed) return;
    await _controller?.stop();
    await _controller?.dispose();
    _controller = null;
    _isInitialized = false;
    _isLoading = true;
    _isFailed = false;
    setState(() {});

    LogService.write('播放频道 (VLC): ${_extractChannelName(_currentUrl)}');

    _controller = VlcPlayerController.network(
      _currentUrl,
      hwAcc: HwAcc.full,
      autoPlay: true,
      options: VlcPlayerOptions(
        advanced: VlcAdvancedOptions([
          VlcAdvancedOptions.networkCaching(300),
        ]),
        http: VlcHttpOptions([
          VlcHttpOptions.httpReconnect(true),
        ]),
      ),
    );

    _controller!.addListener(_onControllerListener);

    try {
      await _controller!.initialize().timeout(Duration(seconds: 2));
      if (_isDisposed) return;
      setState(() {
        _isInitialized = true;
        _isLoading = false;
      });
      await _controller!.play();
      LogService.write('VLC 初始化成功: $_currentUrl');
      _startSpeedMonitor();
      _reconnectAttempts = 0;
    } catch (e) {
      if (_isDisposed) return;
      LogService.write('VLC 初始化失败: $e');
      setState(() {
        _isLoading = false;
        _isFailed = true;
      });
      widget.onError();
      if (_reconnectAttempts < maxReconnectAttempts) {
        _reconnectAttempts++;
        Future.delayed(Duration(milliseconds: 500), _initPlayer);
      }
    }
  }

  void _onControllerListener() {
    if (_controller == null || _isDisposed) return;
    final state = _controller!.value;
    if (state.isPlaying) {
      setState(() => _isLoading = false);
    }
    if (state.hasError) {
      // 使用 errorDescription 获取错误信息
      LogService.write('VLC 播放错误: ${state.errorDescription}');
      if (_reconnectAttempts < maxReconnectAttempts) {
        _reconnectAttempts++;
        Future.delayed(Duration(milliseconds: 500), _initPlayer);
      } else {
        setState(() => _isFailed = true);
      }
    }
  }

  void _retry() {
    _reconnectAttempts = 0;
    _initPlayer();
  }

  void _startSpeedMonitor() {
    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(Duration(seconds: 3), (timer) {
      if (_controller != null && _controller!.value.isPlaying) {
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
      if (segments.isNotEmpty) {
        return segments.last.split('.').first;
      }
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
              Icon(Icons.error_outline, color: Colors.white70, size: 48),
              SizedBox(height: 16),
              Text('加载失败', style: TextStyle(color: Colors.white70)),
              SizedBox(height: 16),
              ElevatedButton(onPressed: _retry, child: Text('重试')),
            ],
          ),
        ),
      );
    }

    if (_isLoading || _controller == null) {
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
        VlcPlayer(
          controller: _controller!,
          aspectRatio: 16 / 9,
          placeholder: Container(color: Colors.black),
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
    _controller?.stop();
    _controller?.dispose();
    _speedTimer?.cancel();
    super.dispose();
  }
}
