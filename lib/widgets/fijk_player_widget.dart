import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 基于 media_kit + mpv 的硬解播放器
/// 接口与之前的 IjkPlayerWidget / MediaKitPlayerWidget 保持一致
class IjkPlayerWidget extends StatefulWidget {
  final String url;
  final VoidCallback? onError;
  final ValueChanged<double>? onSpeedUpdate;

  const IjkPlayerWidget({
    Key? key,
    required this.url,
    this.onError,
    this.onSpeedUpdate,
  }) : super(key: key);

  @override
  State<IjkPlayerWidget> createState() => _IjkPlayerWidgetState();
}

class _IjkPlayerWidgetState extends State<IjkPlayerWidget> {
  late final Player _player;
  late final VideoController _controller;
  Timer? _speedTimer;
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  void _initPlayer() {
    // ==================== 硬解配置（核心） ====================
    _player = Player(
      configuration: const PlayerConfiguration(
        // 启用硬件加速解码
        // Android: mediacodec / mediacodec-copy
        // iOS: videotoolbox
        vo: 'gpu',              // 视频输出使用 GPU
        // 低延迟直播优化
        bufferSize: 1024 * 1024, // 1MB 缓冲
        // 其他 mpv 参数通过 extra 传递
      ),
    );

    // mpv 原生参数：开启硬解
    _player.setProperty('hwdec', 'auto');           // 自动选择硬解
    _player.setProperty('hwdec-codecs', 'all');     // 所有编码格式都尝试硬解
    
    // 直播/IPTV 低延迟优化
    _player.setProperty('cache', 'no');             // 关闭文件缓存（直播流）
    _player.setProperty('demuxer-max-bytes', '4M');
    _player.setProperty('demuxer-max-back-bytes', '1M');
    _player.setProperty('network-timeout', '10');
    _player.setProperty('reconnect', '1');
    
    // RTSP 强制 TCP（避免 UDP 花屏）
    if (widget.url.startsWith('rtsp')) {
      _player.setProperty('rtsp-transport', 'tcp');
    }

    // 错误监听
    _player.stream.error.listen((error) {
      if (_isDisposed) return;
      debugPrint('MediaKit error: $error');
      widget.onError?.call();
    });

    // 播放状态监听
    _player.stream.playing.listen((playing) {
      if (_isDisposed) return;
      // 可以在这里处理播放状态
    });

    // 初始化视频控制器
    _controller = VideoController(_player);

    // 打开媒体
    _player.open(Media(widget.url));

    // 网速模拟（兼容原接口）
    _startSpeedTimer();
  }

  void _startSpeedTimer() {
    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isDisposed) return;
      widget.onSpeedUpdate?.call(0.0);
    });
  }

  @override
  void didUpdateWidget(covariant IjkPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _player.open(Media(widget.url));
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _speedTimer?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Video(
      controller: _controller,
      controls: NoVideoControls,          // 无控制面板，由外层控制
      fit: BoxFit.contain,
      wakelock: true,
    );
  }
}
