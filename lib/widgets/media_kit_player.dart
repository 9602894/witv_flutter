import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/log_service.dart';

/// MediaKit 播放器组件（Xtream Codes IPTV 专用修复版）
///
/// 核心修复：
/// 1. **PlaylistMode.single**：completed 时自动循环播放，而不是停止。这是 IPTV 流的关键设置。
/// 2. **移除 completed 重连**：completed 对直播流是正常行为（服务器断开），mpv 自己循环即可。
/// 3. **只监听 error 流**：真正的断线（服务器彻底挂了）才会触发 error，这时才需要 Flutter 层重连。
/// 4. **心跳检测放宽**：playing=true 时完全信任，不检查 position。
/// 5. **单 Player 复用**：换台不重建，VideoController 终身绑定。
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
  int failCount;
  DateTime? lastSuccess;

  _ChannelConfig({
    this.useHwdec = true,
    this.failCount = 0,
    this.lastSuccess,
  });

  void onFail() {
    failCount++;
    if (failCount >= 2) useHwdec = false;
  }

  void onSuccess() {
    failCount = 0;
    lastSuccess = DateTime.now();
  }
}

class _MediaKitPlayerWidgetState extends State<MediaKitPlayerWidget> {
  // 核心：单 Player 终身复用
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

  // 重连控制（只由 error 触发）
  bool _isReconnecting = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;

  // Stream 订阅
  final List<StreamSubscription> _subscriptions = [];

  // 心跳检测（仅备用）
  DateTime _lastPositionUpdate = DateTime.now();
  DateTime _lastBufferUpdate = DateTime.now();
  Timer? _heartbeatTimer;
  bool _heartbeatPlaying = false;

  // 网速监控
  double _speed = 0;
  final List<double> _speedHistory = [];
  Duration _lastBufferPosition = Duration.zero;
  DateTime _lastSpeedCheck = DateTime.now();
  double? _lastAudioBitrate;
  Timer? _speedTimer;

  // 频道解码记忆
  static final Map<String, _ChannelConfig> _channelMemory = {};

  // 硬件解码闪烁检测
  int _hwdecErrorCount = 0;
  static const int _hwdecErrorThreshold = 3;

  // ========== 常量配置 ==========
  static const int switchTimeoutMs = 4000;
  static const int maxSwitchAttempts = 3;
  static const int reconnectBaseDelayMs = 3000;
  static const int maxReconnectAttempts = 10;
  static const int heartbeatIntervalSec = 5;
  static const int maxStallSec = 15;

  // ==================== 生命周期 ====================

  @override
  void initState() {
    super.initState();
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
      // 换台加速（保守值）
      await native.setProperty('demuxer-lavf-analyzeduration', '0.5');
      await native.setProperty('demuxer-lavf-probesize', '131072');

      // 大缓存
      await native.setProperty('cache', 'yes');
      await native.setProperty('demuxer-max-bytes', '64M');
      await native.setProperty('demuxer-max-back-bytes', '32M');
      await native.setProperty('demuxer-readahead-secs', '10');

      // 解码队列
      await native.setProperty('vd-queue-enable', 'yes');
      await native.setProperty('vd-queue-max-bytes', '50M');

      // 音画同步
      await native.setProperty('video-sync', 'audio');
      await native.setProperty('framedrop', 'decoder');
      await native.setProperty('opengl-glfinish', 'yes');

      // 硬件解码
      final hwdec = config.useHwdec ? 'auto-safe' : 'no';
      await native.setProperty('hwdec', hwdec);

      // 网络超时与 mpv 内部重连
      await native.setProperty('network-timeout', '10');
      await native.setProperty('reconnect', 'yes');
      await native.setProperty('reconnect-stream-error', 'yes');
      await native.setProperty('reconnect-on-network-error', 'yes');
      await native.setProperty('reconnect-delay-max', '5');

      // 直播流优化
      await native.setProperty('demuxer-hysteresis-secs', '5');

      LogService.write('mpv 优化: hwdec=$hwdec');
    } catch (e) {
      LogService.write('mpv 优化部分失败: $e');
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
    LogService.write('${isReconnect ? "重连" : "加载"}频道: ${_extractChannelName(url)}');

    try {
      // 单 Player 终身复用
      if (_player == null) {
        _player = Player(
          configuration: const PlayerConfiguration(
            bufferSize: 64 * 1024 * 1024,
          ),
        );
        _videoController = VideoController(_player!);
      }

      await _player!.stop();
      await Future.delayed(const Duration(milliseconds: 150));
      await _applyMpvOptimizations(_player!, config);

      // 【关键修复】设置单曲循环，completed 时自动重新播放而不是停止
      await _player!.setPlaylistMode(PlaylistMode.single);

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

    config.onSuccess();

    _setupPlayerListeners();
    _startHeartbeat();
    _startSpeedMonitor();
    _fadeInVideo();

    if (mounted) setState(() {});
    LogService.write('${isReconnect ? "重连" : "加载"}成功: $url');
  }

  // ==================== 核心：换台 ====================

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
    LogService.write('换台: ${_extractChannelName(newUrl)}');

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
        await Future.delayed(const Duration(milliseconds: 150));
        await _applyMpvOptimizations(_player!, config);
        await _player!.setPlaylistMode(PlaylistMode.single);
        await _player!.open(Media(newUrl), play: true)
            .timeout(const Duration(milliseconds: switchTimeoutMs));

        if (_isDisposed || _switchCanceled) break;

        _currentUrl = newUrl;
        _isInitialized = true;
        _isLoading = false;
        _isFailed = false;
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
        LogService.write('换台 #$attempt 失败: $e');
        config.onFail();

        if (_isDisposed || _switchCanceled) break;

        if (config.useHwdec && attempt < maxSwitchAttempts) {
          LogService.write('硬件解码失败，降级软解重试');
          config.useHwdec = false;
          await Future.delayed(const Duration(milliseconds: 200));
          continue;
        }

        if (attempt < maxSwitchAttempts) {
          await Future.delayed(const Duration(milliseconds: 300));
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
    if (mounted && _videoOpacity > 0) {
      setState(() => _videoOpacity = 0.0);
    }
  }

  void _fadeInVideo() {
    if (mounted && _videoOpacity < 1.0) {
      setState(() => _videoOpacity = 1.0);
    }
  }

  // ==================== Stream 监听器（关键修复） ====================

  void _setupPlayerListeners() {
    _clearSubscriptions();
    if (_player == null) return;

    // 1. 错误流 —— 唯一触发重连的来源
    _subscriptions.add(_player!.stream.error.listen((error) {
      if (error.isNotEmpty && !_isSwitching && !_isReconnecting) {
        LogService.write('Player error: $error');

        // 检测硬件解码错误
        final lowerError = error.toLowerCase();
        if (lowerError.contains('hwdec') ||
            lowerError.contains('hardware') ||
            lowerError.contains('vaapi') ||
            lowerError.contains('dxva') ||
            lowerError.contains('mediacodec')) {
          _hwdecErrorCount++;
          if (_hwdecErrorCount >= _hwdecErrorThreshold) {
            final cfg = _getChannelConfig(_currentUrl);
            if (cfg.useHwdec) {
              LogService.write('硬件解码错误，自动降级软解');
              cfg.useHwdec = false;
            }
          }
        }

        _handleConnectionLost();
      }
    }));

    // 2. 播放状态
    _subscriptions.add(_player!.stream.playing.listen((playing) {
      _heartbeatPlaying = playing;
      if (playing) {
        _lastPositionUpdate = DateTime.now();
        _lastBufferUpdate = DateTime.now();
        _fadeInVideo();
      }
    }));

    // 3. 位置变化
    _subscriptions.add(_player!.stream.position.listen((_) {
      _lastPositionUpdate = DateTime.now();
    }));

    // 4. 缓冲状态
    _subscriptions.add(_player!.stream.buffering.listen((buffering) {
      if (!buffering) {
        _lastBufferUpdate = DateTime.now();
      }
    }));

    // 5. 缓冲位置 —— 用于网速估算
    _subscriptions.add(_player!.stream.buffer.listen((buffer) {
      _lastBufferUpdate = DateTime.now();
      _updateSpeedFromBuffer(buffer);
    }));

    // 6. 音频比特率
    _subscriptions.add(_player!.stream.audioBitrate.listen((bitrate) {
      if (bitrate != null && bitrate > 0) {
        _lastAudioBitrate = bitrate;
      }
    }));

    // 7. 【关键修复】completed 流：只记录日志，不触发重连
    // PlaylistMode.single 会让 mpv 自动循环播放，completed 是正常行为
    _subscriptions.add(_player!.stream.completed.listen((completed) {
      if (completed) {
        LogService.write('completed=true（PlaylistMode.single 已自动循环）');
        // 不触发重连！mpv 自己处理
      }
    }));

    // 8. 日志流
    _subscriptions.add(_player!.stream.log.listen((_) {
      _lastPositionUpdate = DateTime.now();
    }));
  }

  // ==================== 心跳检测（仅备用） ====================

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _lastPositionUpdate = DateTime.now();
    _lastBufferUpdate = DateTime.now();
    _heartbeatPlaying = false;

    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: heartbeatIntervalSec),
      (_) {
        if (_player == null || _isDisposed || _isSwitching || _isReconnecting) return;

        final now = DateTime.now();
        final positionStall = now.difference(_lastPositionUpdate);
        final bufferStall = now.difference(_lastBufferUpdate);

        // 如果正在播放，完全信任，不判定断线
        if (_heartbeatPlaying) {
          _lastPositionUpdate = now;
          _lastBufferUpdate = now;
          return;
        }

        // 只有 position 和 buffer 都长时间停滞，且不在播放中，才判定断线
        if (positionStall > const Duration(seconds: maxStallSec) &&
            bufferStall > const Duration(seconds: maxStallSec)) {
          LogService.write(
            '心跳: position停${positionStall.inSeconds}s, buffer停${bufferStall.inSeconds}s，断线',
          );
          _handleConnectionLost();
        }
      },
    );
  }

  // ==================== 断线重连（只由 error/heartbeat 触发） ====================

  void _handleConnectionLost() {
    if (_isDisposed || _isSwitching || _isReconnecting) return;
    LogService.write('连接丢失，启动重连');
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

    final delayMs = reconnectBaseDelayMs * (1 << (_reconnectAttempt - 1));
    final cappedDelayMs = delayMs > 10000 ? 10000 : delayMs;

    LogService.write('重连 #$_reconnectAttempt，${cappedDelayMs}ms 后尝试');

    _reconnectTimer = Timer(Duration(milliseconds: cappedDelayMs), () async {
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
        await Future.delayed(const Duration(milliseconds: 150));
        await _applyMpvOptimizations(_player!, config);
        await _player!.setPlaylistMode(PlaylistMode.single);
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
      if (count > 0) {
        _speed = sum / count;
      }
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
              ElevatedButton(onPressed: _retry, child: const Text('重试')),
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
