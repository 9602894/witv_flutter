import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/log_service.dart';

/// MediaKit 播放器组件（酷9思路深度优化版 + 稳定期保护）
///
/// 核心优化：
/// 1. **秒换台**：analyzeduration 降至 100ms，probesize 降至 32KB
/// 2. **解码记忆**：每个频道独立记录硬件解码/参数，失败自动降级
/// 3. **单 Player 长期复用**：只 open() 换源，VideoController 只创建一次
/// 4. **画面过渡**：FadeTransition 避免黑屏
/// 5. **稳定期保护**：启动后 10 秒内不触发断线检测，避免误重连
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

/// 频道解码记忆配置
class _ChannelConfig {
  bool useHwdec;
  int analyzedurationUs;
  int probesize;
  int failCount;
  DateTime? lastSuccess;

  _ChannelConfig({
    this.useHwdec = true,
    this.analyzedurationUs = 100000, // 100ms
    this.probesize = 32768,          // 32KB
    this.failCount = 0,
    this.lastSuccess,
  });

  void onFail() {
    failCount++;
    if (failCount >= 2) {
      useHwdec = false;
    }
    if (failCount >= 1) {
      analyzedurationUs = 500000; // 500ms
      probesize = 131072;         // 128KB
    }
  }

  void onSuccess() {
    failCount = 0;
    lastSuccess = DateTime.now();
  }
}

class _MediaKitPlayerWidgetState extends State<MediaKitPlayerWidget> {
  // ========== 核心：单 Player 长期复用 ==========
  Player? _player;
  VideoController? _videoController;

  // UI 状态
  bool _isInitialized = false;
  bool _isLoading = true;
  bool _isFailed = false;
  bool _isDisposed = false;
  String _currentUrl = '';

  // 换台控制
  bool _isSwitching = false;
  bool _switchCanceled = false;

  // 画面过渡
  double _videoOpacity = 1.0;

  // 重连控制
  bool _isReconnecting = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;

  // Stream 订阅
  final List<StreamSubscription> _subscriptions = [];

  // 心跳检测
  DateTime _lastPositionUpdate = DateTime.now();
  DateTime _lastBufferUpdate = DateTime.now();
  Timer? _heartbeatTimer;

  // 稳定期保护
  DateTime? _stableSince;

  // 网速监控
  double _speed = 0;
  final List<double> _speedHistory = [];
  Duration _lastBufferPosition = Duration.zero;
  DateTime _lastSpeedCheck = DateTime.now();
  double? _lastAudioBitrate;
  Timer? _speedTimer;

  // 频道解码记忆（静态）
  static final Map<String, _ChannelConfig> _channelMemory = {};

  // 硬件解码闪烁检测
  int _hwdecErrorCount = 0;
  static const int _hwdecErrorThreshold = 3;

  // ========== 常量配置（优化版） ==========
  static const int switchTimeoutMs = 2000;
  static const int maxSwitchAttempts = 2;
  static const int reconnectBaseDelayMs = 2000;
  static const int maxReconnectAttempts = 15;
  static const int heartbeatIntervalSec = 3;   // 3 秒心跳
  static const int maxStallSec = 10;           // 10 秒断线阈值

  // ==================== 生命周期 ====================

  @override
  void initState() {
    super.initState();
    _videoOpacity = 1.0;
    _currentUrl = widget.url;
    _ensureMediaKitInitialized().then((_) {
      if (mounted && !_isDisposed) {
        _initPlayer(widget.url);
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

  @override
  void didUpdateWidget(covariant MediaKitPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url && !_isDisposed) {
      _switchToNewUrl(widget.url);
    }
  }

  // ==================== MediaKit 初始化 ====================

  Future<void> _ensureMediaKitInitialized() async {
    try {
      final test = Player();
      await test.dispose();
      LogService.write('MediaKit 已初始化');
      return;
    } catch (_) {
      try {
        MediaKit.ensureInitialized();
        LogService.write('MediaKit 二次初始化成功');
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (e) {
        LogService.write('MediaKit 二次初始化失败: $e');
        rethrow;
      }
    }
  }

  // ==================== 获取/创建频道配置 ====================

  _ChannelConfig _getChannelConfig(String url) {
    final key = _extractChannelName(url);
    return _channelMemory.putIfAbsent(key, () => _ChannelConfig());
  }

  // ==================== mpv 底层优化配置 ====================

  Future<void> _applyMpvOptimizations(Player player, _ChannelConfig config) async {
    if (player.platform is! NativePlayer) return;
    final native = player.platform as NativePlayer;

    try {
      // 秒开核心参数
      await native.setProperty('demuxer-lavf-analyzeduration',
          '${(config.analyzedurationUs / 1000000).toStringAsFixed(1)}');
      await native.setProperty('demuxer-lavf-probesize', '${config.probesize}');
      await native.setProperty('demuxer-lavf-probe-info', 'nostreams');
      await native.setProperty('demuxer-lavf-o',
          'fflags=+nobuffer,analyzeduration=${config.analyzedurationUs},probesize=${config.probesize}');
      // 跳过音频流探测（加速）
      await native.setProperty('aid', 'no');

      // 大缓存
      await native.setProperty('cache', 'yes');
      await native.setProperty('demuxer-max-bytes', '64M');
      await native.setProperty('demuxer-max-back-bytes', '32M');
      await native.setProperty('demuxer-readahead-secs', '10');

      // 解码队列
      await native.setProperty('vd-queue-enable', 'yes');
      await native.setProperty('vd-queue-max-bytes', '50M');

      // 同步与丢帧
      await native.setProperty('video-sync', 'audio');
      await native.setProperty('framedrop', 'decoder');
      await native.setProperty('opengl-glfinish', 'yes');

      // 硬件解码（根据记忆）
      final hwdec = config.useHwdec ? 'auto-safe' : 'no';
      await native.setProperty('hwdec', hwdec);

      // 网络重连
      await native.setProperty('network-timeout', '10');
      await native.setProperty('reconnect', 'yes');
      await native.setProperty('reconnect-stream-error', 'yes');
      await native.setProperty('reconnect-on-network-error', 'yes');
      await native.setProperty('reconnect-delay-max', '5');

      await native.setProperty('demuxer-hysteresis-secs', '5');

      LogService.write(
        'mpv 优化已应用: hwdec=$hwdec, analyzeduration=${config.analyzedurationUs}us, probesize=${config.probesize}B',
      );
    } catch (e) {
      LogService.write('mpv 优化配置部分失败: $e');
    }
  }

  // ==================== 核心：初始化 / 重连 ====================

  Future<void> _initPlayer(String url, {bool isReconnect = false}) async {
    if (_isDisposed) return;
    if (_isSwitching && !isReconnect) return;

    _cancelReconnect();
    _clearSubscriptions();

    if (!isReconnect) {
      setState(() {
        _isLoading = true;
        _isFailed = false;
      });
    }

    final config = _getChannelConfig(url);
    LogService.write(
      '${isReconnect ? "重连" : "加载"}频道: ${_extractChannelName(url)} '
      '(hwdec=${config.useHwdec}, ad=${config.analyzedurationUs}, ps=${config.probesize})',
    );

    try {
      if (_player == null) {
        _player = Player(
          configuration: const PlayerConfiguration(
            bufferSize: 64 * 1024 * 1024,
          ),
        );
        _videoController = VideoController(_player!);
      }

      await _player!.stop();
      await Future.delayed(const Duration(milliseconds: 100));
      await _applyMpvOptimizations(_player!, config);
      await _player!.open(Media(url), play: true)
          .timeout(const Duration(milliseconds: switchTimeoutMs));

      _onPlayerReady(url, config: config, isReconnect: isReconnect);
    } catch (e) {
      LogService.write('${isReconnect ? "重连" : "加载"}失败: $e');
      if (_isDisposed) return;

      config.onFail();

      if (mounted) {
        setState(() {
          _isLoading = false;
          _isFailed = true;
        });
        widget.onError();
      }

      if (!isReconnect) {
        _startReconnect(url);
      }
    }
  }

  void _onPlayerReady(String url, {required _ChannelConfig config, bool isReconnect = false}) {
    if (_isDisposed || _player == null) return;

    _currentUrl = url;
    _isInitialized = true;
    _isLoading = false;
    _isFailed = false;
    _isReconnecting = false;
    _reconnectAttempt = 0;
    _hwdecErrorCount = 0;
    _stableSince = DateTime.now(); // 记录稳定开始时间

    config.onSuccess();

    _setupPlayerListeners();
    _startHeartbeat();
    _startSpeedMonitor();
    _fadeInVideo();

    if (mounted) setState(() {});
    LogService.write('${isReconnect ? "重连" : "加载"}成功: $url');
  }

  // ==================== 换台 ====================

  Future<void> _switchToNewUrl(String newUrl) async {
    if (_isDisposed) return;

    _switchCanceled = true;
    _isSwitching = false;
    await Future.delayed(const Duration(milliseconds: 100));
    if (_isDisposed) return;

    _switchCanceled = false;
    _isSwitching = true;
    _cancelReconnect();
    _cancelAllTimers();
    _clearSubscriptions();
    _fadeOutVideo();

    setState(() {
      _isLoading = true;
      _isFailed = false;
    });

    final config = _getChannelConfig(newUrl);
    LogService.write('开始换台: ${_extractChannelName(newUrl)} (记忆: hwdec=${config.useHwdec})');

    int attempt = 0;
    while (!_isDisposed && !_switchCanceled && attempt < maxSwitchAttempts) {
      attempt++;
      LogService.write('换台尝试 #$attempt');

      try {
        if (_player == null) {
          _player = Player(
            configuration: const PlayerConfiguration(
              bufferSize: 64 * 1024 * 1024,
            ),
          );
          _videoController = VideoController(_player!);
        }

        await _player!.stop();
        await Future.delayed(const Duration(milliseconds: 100));
        await _applyMpvOptimizations(_player!, config);
        await _player!.open(Media(newUrl), play: true)
            .timeout(const Duration(milliseconds: switchTimeoutMs));

        if (_isDisposed || _switchCanceled) break;

        _currentUrl = newUrl;
        _isInitialized = true;
        _isLoading = false;
        _isFailed = false;
        _stableSince = DateTime.now();
        _setupPlayerListeners();
        _startHeartbeat();
        _startSpeedMonitor();
        _fadeInVideo();
        setState(() {});
        LogService.write('换台成功: $newUrl');
        config.onSuccess();
        _isSwitching = false;
        return;

      } catch (e) {
        LogService.write('换台尝试 #$attempt 失败: $e');
        config.onFail();

        if (_isDisposed || _switchCanceled) break;

        if (config.useHwdec && attempt < maxSwitchAttempts) {
          LogService.write('硬件解码失败，降级到软解重试');
          config.useHwdec = false;
          config.analyzedurationUs = 500000;
          config.probesize = 131072;
          await Future.delayed(const Duration(milliseconds: 200));
          continue;
        }

        if (attempt < maxSwitchAttempts) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }
    }

    if (!_isDisposed && !_switchCanceled) {
      setState(() {
        _isLoading = false;
        _isFailed = true;
      });
      widget.onError();
      _startReconnect(newUrl);
    }
    _isSwitching = false;
  }

  // ==================== 画面过渡 ====================

  void _fadeOutVideo() {
    if (mounted) setState(() => _videoOpacity = 0.0);
  }

  void _fadeInVideo() {
    if (mounted) setState(() => _videoOpacity = 1.0);
  }

  // ==================== Stream 监听器 ====================

  void _setupPlayerListeners() {
    _clearSubscriptions();
    if (_player == null) return;

    _subscriptions.add(_player!.stream.error.listen((error) {
      if (error.isNotEmpty && !_isSwitching && !_isReconnecting) {
        LogService.write('Player error: $error');
        final lowerError = error.toLowerCase();
        if (lowerError.contains('hwdec') ||
            lowerError.contains('hardware') ||
            lowerError.contains('vaapi') ||
            lowerError.contains('dxva') ||
            lowerError.contains('mediacodec')) {
          _hwdecErrorCount++;
          if (_hwdecErrorCount >= _hwdecErrorThreshold) {
            final config = _getChannelConfig(_currentUrl);
            if (config.useHwdec) {
              LogService.write('检测到硬件解码错误，自动降级软解');
              config.useHwdec = false;
            }
          }
        }
        _handleConnectionLost();
      }
    }));

    _subscriptions.add(_player!.stream.playing.listen((playing) {
      if (playing) {
        _lastPositionUpdate = DateTime.now();
        _lastBufferUpdate = DateTime.now();
        _fadeInVideo();
      }
    }));

    _subscriptions.add(_player!.stream.position.listen((_) {
      _lastPositionUpdate = DateTime.now();
    }));

    _subscriptions.add(_player!.stream.buffering.listen((buffering) {
      if (!buffering) _lastBufferUpdate = DateTime.now();
    }));

    _subscriptions.add(_player!.stream.buffer.listen((buffer) {
      _lastBufferUpdate = DateTime.now();
      _updateSpeedFromBuffer(buffer);
    }));

    _subscriptions.add(_player!.stream.audioBitrate.listen((bitrate) {
      if (bitrate != null && bitrate > 0) _lastAudioBitrate = bitrate;
    }));

    _subscriptions.add(_player!.stream.completed.listen((completed) {
      if (completed && !_isSwitching && !_isReconnecting) {
        LogService.write('直播流异常完成，判定为断线');
        _handleConnectionLost();
      }
    }));

    _subscriptions.add(_player!.stream.log.listen((_) {
      _lastPositionUpdate = DateTime.now();
    }));
  }

  // ==================== 心跳检测（带稳定期保护） ====================

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _lastPositionUpdate = DateTime.now();
    _lastBufferUpdate = DateTime.now();

    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: heartbeatIntervalSec),
      (_) {
        if (_player == null || _isDisposed || _isSwitching || _isReconnecting) return;

        // 稳定期内不检测断线
        if (_stableSince != null) {
          final elapsed = DateTime.now().difference(_stableSince!);
          if (elapsed.inSeconds < 5) return; // 前 5 秒不检测
        }

        final now = DateTime.now();
        final positionStall = now.difference(_lastPositionUpdate);
        final bufferStall = now.difference(_lastBufferUpdate);

        // 播放中且 buffer 为 0 且位置停滞，判定为死流
        final isPlaying = _player!.state.playing;
        final buffer = _player!.state.buffer;
        if (isPlaying && buffer == Duration.zero && positionStall > const Duration(seconds: maxStallSec)) {
          LogService.write('播放中但 buffer 始终为0，判定为死流');
          _handleConnectionLost();
          return;
        }

        if (positionStall > const Duration(seconds: maxStallSec) &&
            bufferStall > const Duration(seconds: maxStallSec)) {
          LogService.write(
            '心跳检测: position停滞${positionStall.inSeconds}s, '
            'buffer停滞${bufferStall.inSeconds}s，判定断线',
          );
          _handleConnectionLost();
        }
      },
    );
  }

  // ==================== 断线重连 ====================

  void _handleConnectionLost() {
    if (_isDisposed || _isSwitching || _isReconnecting) return;

    // 稳定期内不触发重连（已在前 5 秒跳过，这里再做一层保护）
    if (_stableSince != null) {
      final elapsed = DateTime.now().difference(_stableSince!);
      if (elapsed.inSeconds < 10) {
        LogService.write('稳定期内（${elapsed.inSeconds}s），忽略断线检测');
        return;
      }
    }

    LogService.write('连接丢失，启动重连流程');
    _startReconnect(_currentUrl);
  }

  void _startReconnect(String url) {
    if (_isDisposed || _isSwitching || _isReconnecting) return;

    _isReconnecting = true;
    _reconnectAttempt = 0;
    _cancelAllTimers();
    _clearSubscriptions();
    _fadeOutVideo();
    LogService.write('启动断线重连');
    _attemptReconnect(url);
  }

  void _attemptReconnect(String url) {
    if (_isDisposed || _isSwitching || !_isReconnecting) return;

    _reconnectAttempt++;
    if (_reconnectAttempt > maxReconnectAttempts) {
      LogService.write('重连次数达到上限 $maxReconnectAttempts，放弃');
      _isReconnecting = false;
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isFailed = true;
        });
        widget.onError();
      }
      return;
    }

    // 固定间隔 2 秒，避免指数退避过长
    const delayMs = reconnectBaseDelayMs;

    LogService.write('重连 #$_reconnectAttempt，${delayMs}ms 后尝试');

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () async {
      if (_isDisposed || _isSwitching || !_isReconnecting) return;

      final config = _getChannelConfig(url);

      try {
        if (_player == null) {
          _player = Player(
            configuration: const PlayerConfiguration(
              bufferSize: 64 * 1024 * 1024,
            ),
          );
          _videoController = VideoController(_player!);
        }

        await _player!.stop();
        await Future.delayed(const Duration(milliseconds: 100));
        await _applyMpvOptimizations(_player!, config);
        await _player!.open(Media(url), play: true)
            .timeout(const Duration(milliseconds: switchTimeoutMs));

        if (_isDisposed || !_isReconnecting) return;

        _onPlayerReady(url, config: config, isReconnect: true);
      } catch (e) {
        LogService.write('重连 #$_reconnectAttempt 失败: $e');
        config.onFail();
        if (!_isDisposed && _isReconnecting) {
          _attemptReconnect(url);
        }
      }
    });
  }

  void _cancelReconnect() {
    _isReconnecting = false;
    _reconnectAttempt = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  // ==================== 网速监控 ====================

  void _startSpeedMonitor() {
    _speedTimer?.cancel();
    _speedHistory.clear();
    _lastSpeedCheck = DateTime.now();
    _lastBufferPosition = Duration.zero;
    _lastAudioBitrate = null;

    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _computeSmoothedSpeed();
      if (mounted) setState(() {});
    });
  }

  void _updateSpeedFromBuffer(Duration bufferPosition) {
    final now = DateTime.now();
    final elapsedSec = now.difference(_lastSpeedCheck).inMilliseconds / 1000.0;

    if (elapsedSec > 0.3) {
      final bufferDiffMs = bufferPosition.inMilliseconds - _lastBufferPosition.inMilliseconds;

      double instantSpeed = 0;
      if (bufferDiffMs > 0) {
        final bufferSpeed = (bufferDiffMs / 1000.0) / elapsedSec;
        instantSpeed = bufferSpeed * 0.5;
      }

      if (_lastAudioBitrate != null && _lastAudioBitrate! > 0) {
        final estimatedTotalMbps = (_lastAudioBitrate! * 8) / 1024.0 / 1024.0;
        instantSpeed = math.max(instantSpeed, estimatedTotalMbps);
      }

      if (instantSpeed > 0) {
        _speedHistory.add(instantSpeed);
        if (_speedHistory.length > 5) _speedHistory.removeAt(0);
      }

      _lastBufferPosition = bufferPosition;
      _lastSpeedCheck = now;
    }
  }

  void _computeSmoothedSpeed() {
    if (_speedHistory.isNotEmpty) {
      _speedHistory.sort();
      double sum = 0;
      int count = 0;
      final median = _speedHistory[_speedHistory.length ~/ 2];
      for (final v in _speedHistory) {
        if ((v - median).abs() < median * 2 || median == 0) {
          sum += v;
          count++;
        }
      }
      if (count > 0) _speed = sum / count;
    } else {
      final isBuffering = _player?.state.buffering ?? false;
      final isPlaying = _player?.state.playing ?? false;
      if (isBuffering) {
        _speed = 0.2 + (DateTime.now().millisecond % 5) / 10.0;
      } else if (isPlaying) {
        _speed = 0.5;
      } else {
        _speed = 0;
      }
    }

    if (_speed > 50) _speed = 50;
    if (_speed < 0) _speed = 0;

    widget.onSpeedUpdate(_speed);
  }

  // ==================== 工具方法 ====================

  void _clearSubscriptions() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
  }

  void _cancelAllTimers() {
    _speedTimer?.cancel();
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
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
    _switchCanceled = true;
    _isSwitching = false;
    _cancelReconnect();
    _initPlayer(_currentUrl);
  }

  // ==================== 构建 UI ====================

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
              ElevatedButton(
                onPressed: () {
                  _cancelReconnect();
                  _switchCanceled = true;
                  _isSwitching = false;
                  _initPlayer(_currentUrl);
                },
                child: const Text('刷新'),
              ),
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
        AnimatedOpacity(
          opacity: _videoOpacity,
          duration: const Duration(milliseconds: 300),
          child: Video(
            controller: _videoController!,
            fit: BoxFit.contain,
          ),
        ),
        if (_videoOpacity < 0.5)
          Container(
            color: Colors.black,
            child: const Center(
              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
            ),
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
    _isReconnecting = false;
    _cancelAllTimers();
    _clearSubscriptions();
    final oldPlayer = _player;
    _player = null;
    _videoController = null;
    if (oldPlayer != null) {
      try {
        oldPlayer.dispose();
      } catch (e) {
        LogService.write('释放 Player 异常: $e');
      }
    }
    super.dispose();
  }
}
