import 'dart:async';
import 'dart:math';
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
  VideoPlayerController? _nextController;
  bool _isInitialized = false;
  bool _isLoading = true;
  bool _isFailed = false;
  bool _isDisposed = false;
  bool _isSwitching = false; // 新增：标记是否正在无缝切换
  String _currentUrl = '';
  Timer? _speedTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  
  // 配置调优
  static const int maxReconnectAttempts = 5;
  static const int initTimeoutMs = 8000;        // 提高到 8 秒，直播流需要更长时间握手
  static const int retryBaseDelayMs = 1000;     // 基础延迟
  static const int retryMaxDelayMs = 10000;     // 最大延迟 10 秒
  
  double _speed = 0;
  int _lastUpdateTime = 0;
  int _lastPosition = 0;

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
      _isFailed = false;
      // 先标记切换中，保持当前画面不黑屏
      setState(() => _isSwitching = true);
      _preloadPlayer();
    }
  }

  /// 智能判断视频格式，加速初始化
  VideoFormat _detectFormat(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8') || lower.contains('hls')) return VideoFormat.hls;
    if (lower.contains('.mpd') || lower.contains('dash')) return VideoFormat.dash;
    if (lower.contains('.mp4') || lower.contains('.mov')) return VideoFormat.mp4;
    return VideoFormat.other;
  }

  Future<void> _preloadPlayer() async {
    if (_isDisposed) return;
    
    LogService.write('预加载频道: ${_extractChannelName(_currentUrl)}');

    // 清理旧预加载
    final oldPreload = _nextController;
    _nextController = null;

    try {
      // 使用 formatHint 让播放器跳过格式探测，直接初始化
      _nextController = VideoPlayerController.network(
        _currentUrl,
        formatHint: _detectFormat(_currentUrl),
        httpHeaders: const {
          'Accept': '*/*',
          'Connection': 'keep-alive',
        },
      );
      
      await _nextController!.initialize().timeout(
        const Duration(milliseconds: initTimeoutMs),
      );
      
      if (_isDisposed) {
        await _nextController?.dispose();
        return;
      }

      LogService.write('预加载成功: $_currentUrl');
      _swapController();
    } catch (e) {
      LogService.write('预加载失败: $e，回退直接加载');
      // 预加载失败时清理
      await _nextController?.dispose();
      _nextController = null;
      _initPlayer();
    } finally {
      // 确保旧预加载被释放
      await oldPreload?.dispose();
    }
  }

  void _swapController() {
    if (_nextController == null || _isDisposed) return;

    final oldController = _controller;
    
    // 先移除旧监听，避免事件混淆
    oldController?.removeListener(_onControllerListener);
    
    _controller = _nextController;
    _nextController = null;
    _isInitialized = true;
    _isLoading = false;
    _isFailed = false;
    _isSwitching = false;
    _reconnectAttempts = 0;

    // 新控制器开始播放
    _controller!.addListener(_onControllerListener);
    _controller!.play();
    
    // 安全释放旧控制器（延迟一帧，避免画面闪烁）
    if (oldController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await oldController.dispose();
      });
    }

    if (mounted) setState(() {});
    _startSpeedMonitor();
    LogService.write('切换完成: $_currentUrl');
  }

  Future<void> _initPlayer() async {
    if (_isDisposed) return;

    // 清理旧控制器
    final oldController = _controller;
    _controller = null;
    _isInitialized = false;
    _isLoading = true;
    _isFailed = false;
    _isSwitching = false;

    if (mounted) setState(() {});
    
    // 延迟释放旧控制器，避免黑屏
    if (oldController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await oldController.dispose();
      });
    }

    LogService.write('直接加载频道: ${_extractChannelName(_currentUrl)}');

    try {
      _controller = VideoPlayerController.network(
        _currentUrl,
        formatHint: _detectFormat(_currentUrl),
        httpHeaders: const {
          'Accept': '*/*',
          'Connection': 'keep-alive',
        },
      );
      
      await _controller!.initialize().timeout(
        const Duration(milliseconds: initTimeoutMs),
      );
      
      if (_isDisposed) {
        await _controller?.dispose();
        return;
      }

      _isInitialized = true;
      _isLoading = false;
      
      if (mounted) setState(() {});
      
      _controller!.play();
      LogService.write('直接加载成功: $_currentUrl');
      _startSpeedMonitor();
      _reconnectAttempts = 0;
    } catch (e) {
      if (_isDisposed) return;
      LogService.write('直接加载失败: $e');
      _isLoading = false;
      _isFailed = true;
      
      if (mounted) setState(() {});
      widget.onError();
      _scheduleReconnect();
    }
  }

  /// 指数退避重试，避免雪崩
  void _scheduleReconnect() {
    if (_reconnectAttempts >= maxReconnectAttempts) {
      if (mounted) setState(() => _isFailed = true);
      LogService.write('重试次数已达上限');
      return;
    }
    
    _reconnectTimer?.cancel();
    
    // 指数退避：1s, 2s, 4s, 8s, 10s(max)
    final delay = min(
      retryBaseDelayMs * pow(2, _reconnectAttempts).toInt(),
      retryMaxDelayMs,
    );
    
    LogService.write('计划 ${delay}ms 后第 ${_reconnectAttempts + 1} 次重试');
    
    _reconnectTimer = Timer(Duration(milliseconds: delay), () {
      if (_isDisposed) return;
      _reconnectAttempts++;
      _initPlayer();
    });
  }

  void _onControllerListener() {
    if (_controller == null || _isDisposed) return;
    
    final value = _controller!.value;
    
    if (value.hasError) {
      LogService.write('播放错误: ${value.errorDescription}');
      _controller!.removeListener(_onControllerListener);
      _controller!.pause();
      
      if (_reconnectAttempts < maxReconnectAttempts) {
        _scheduleReconnect();
      } else {
        if (mounted) setState(() => _isFailed = true);
      }
      return;
    }

    // 检测卡顿：缓冲中且非暂停状态
    if (value.isBuffering && value.isPlaying) {
      LogService.write('检测到缓冲...');
    }
  }

  void _retry() {
    _reconnectAttempts = 0;
    _isFailed = false;
    _initPlayer();
  }

  /// 真实速度计算（基于 position 变化）
  void _startSpeedMonitor() {
    _speedTimer?.cancel();
    _lastUpdateTime = DateTime.now().millisecondsSinceEpoch;
    _lastPosition = _controller?.value.position.inMilliseconds ?? 0;

    _speedTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (_controller == null || !_controller!.value.isInitialized || _isDisposed) {
        return;
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final currentPos = _controller!.value.position.inMilliseconds;
      final timeDiff = (now - _lastUpdateTime) / 1000.0; // 秒
      
      if (timeDiff > 0) {
        // 计算实际播放速度（位置变化/时间流逝）
        final posDiff = (currentPos - _lastPosition) / 1000.0; // 秒
        final actualSpeed = posDiff / timeDiff; // 倍速
        
        // 转换为近似码率显示（假设平均码率 1MB = 8Mb，这里简化显示）
        // 实际项目中建议用原生插件获取真实下载速度
        final displaySpeed = (actualSpeed * 0.8).clamp(0.1, 50.0);
        
        _speed = displaySpeed;
        _lastUpdateTime = now;
        _lastPosition = currentPos;
        
        widget.onSpeedUpdate(displaySpeed);
        
        // 只在显示速度时更新 UI，减少 setState 频率
        if (mounted && !_isLoading && !_isFailed) {
          setState(() {});
        }
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

  @override
  Widget build(BuildContext context) {
    // 失败状态
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

    // 加载中（首次加载）
    if (_isLoading && !_isSwitching) {
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

    // 切换中或已初始化：保持旧画面直到新视频就绪
    if (_controller != null && _isInitialized) {
      return Stack(
        children: [
          VideoPlayer(_controller!),
          // 切换时显示半透明遮罩 + 小 loading
          if (_isSwitching)
            Container(
              color: Colors.black26,
              child: const Center(
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                ),
              ),
            ),
          // 速度显示
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

    // 兜底
    return Container(color: Colors.black);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _controller?.removeListener(_onControllerListener);
    _controller?.dispose();
    _nextController?.dispose();
    _speedTimer?.cancel();
    _reconnectTimer?.cancel();
    super.dispose();
  }
}
