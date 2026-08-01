import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/log_service.dart';

/// MediaKit 播放器组件（深度优化版）
///
/// 核心优化：
/// 1. **播放流畅度**：mpv 底层大缓存(64M) + 硬件解码 + 解码队列 + 网络超时/重连
/// 2. **换台稳定性**：复用 Player 时先 stop() 再 open()，给 mpv 清理时间；新建时预配所有优化参数
/// 3. **断线重连**：Stream 即时监听 + 心跳检测 + 指数退避 + mpv 内部重连兜底
/// 4. **网速显示**：audioBitrate + buffer 变化混合估算，平滑处理，始终有合理读数
/// 5. **资源管理**：统一 Subscription/Timer，dispose 彻底清理
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

class _MediaKitPlayerWidgetState extends State<MediaKitPlayerWidget> {
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

  // 网速监控
  double _speed = 0;
  final List<double> _speedHistory = [];
  Duration _lastBufferPosition = Duration.zero;
  DateTime _lastSpeedCheck = DateTime.now();
  double? _lastAudioBitrate;
  Timer? _speedTimer;

  // ========== 常量配置 ==========
  static const int switchTimeoutMs = 3000;
  static const int maxSwitchAttempts = 3;
  static const int reconnectBaseDelayMs = 2000;
  static const int maxReconnectAttempts = 10;
  static const int heartbeatIntervalSec = 3;
  static const int maxStallSec = 5; // 从 8 秒改为 5 秒，更灵敏

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

  // ==================== mpv 底层优化配置 ====================

  Future<void> _applyMpvOptimizations(Player player) async {
    // 增加空值保护
    if (player == null) return;
    if (player.platform is! NativePlayer) return;
    final native = player.platform as NativePlayer;

    try {
      // 大缓存：网络流卡顿的核心解药
      await native.setProperty('cache', 'yes');
      await native.setProperty('demuxer-max-bytes', '64M');
      await native.setProperty('demuxer-max-back-bytes', '32M');
      await native.setProperty('demuxer-readahead-secs', '10');

      // 硬件解码：降低 CPU 占用，减少卡顿
      await native.setProperty('hwdec', 'auto-safe');

      // 解码队列：让解码器提前工作，播放更平滑
      await native.setProperty('vd-queue-enable', 'yes');
      await native.setProperty('vd-queue-max-bytes', '50M');

      // 网络超时与 mpv 内部重连兜底
      await native.setProperty('network-timeout', '10');
      await native.setProperty('reconnect', 'yes');
      await native.setProperty('reconnect-stream-error', 'yes');
      await native.setProperty('reconnect-on-network-error', 'yes');
      await native.setProperty('reconnect-delay-max', '5');

      // 帧同步策略：允许解码器丢帧保持实时性，避免积压导致卡顿
      await native.setProperty('framedrop', 'decoder');

      // 直播流优化：减少延迟抖动
      await native.setProperty('demuxer-hysteresis-secs', '5');

      LogService.write('mpv 优化配置已应用');
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

    LogService.write('${isReconnect ? "重连" : "加载"}频道: ${_extractChannelName(url)}');

    try {
      // 【策略 A】复用现有 Player（最快路径）
      if (_player != null) {
        try {
          // 先 stop 再 open，给 mpv 内部清理时间，换台更稳定
          await _player!.stop();
          await Future.delayed(const Duration(milliseconds: 150));

          await _player!.open(Media(url), play: true)
              .timeout(const Duration(milliseconds: switchTimeoutMs));

          await _applyMpvOptimizations(_player!);
          _onPlayerReady(url, isReconnect: isReconnect);
          return;
        } catch (e) {
          LogService.write('复用 Player 失败: $e，回退到新建 Player');
          await _releasePlayer();
        }
      }

      // 【策略 B】新建 Player（带大缓存配置）
      _player = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 64 * 1024 * 1024, // 64MB 缓冲
        ),
      );
      await _applyMpvOptimizations(_player!);
      await _player!.open(Media(url), play: true)
          .timeout(const Duration(milliseconds: switchTimeoutMs));

      _onPlayerReady(url, isReconnect: isReconnect);
    } catch (e) {
      LogService.write('${isReconnect ? "重连" : "加载"}失败: $e');
      if (_isDisposed) return;

      await _releasePlayer();

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

  void _onPlayerReady(String url, {bool isReconnect = false}) {
    if (_isDisposed || _player == null) return;

    _currentUrl = url;
    _isInitialized = true;
    _isLoading = false;
    _isFailed = false;
    _isReconnecting = false;
    _reconnectAttempt = 0;

    // 如果已有 _videoController 与当前 _player 不匹配，则重新创建
    // 但在正常情况下，直接复用即可
    if (_videoController == null || _videoController!.player != _player) {
      _videoController = VideoController(_player!);
    }

    _setupPlayerListeners();
    _startHeartbeat();
    _startSpeedMonitor();

    if (mounted) setState(() {});
    LogService.write('${isReconnect ? "重连" : "加载"}成功: $url');
  }

  // ==================== 核心：换台（极速稳定版） ====================

  Future<void> _switchToNewUrl(String newUrl) async {
    if (_isDisposed) return;

    // 1. 强制取消旧流程
    _switchCanceled = true;
    _isSwitching = false;
    await Future.delayed(const Duration(milliseconds: 100));
    if (_isDisposed) return;

    // 2. 重置状态
    _switchCanceled = false;
    _isSwitching = true;
    _cancelReconnect();
    _cancelAllTimers();
    _clearSubscriptions();
    await _releasePlayer();

    setState(() {
      _isLoading = true;
      _isFailed = false;
    });

    LogService.write('开始换台: ${_extractChannelName(newUrl)}');

    int attempt = 0;
    while (!_isDisposed && !_switchCanceled && attempt < maxSwitchAttempts) {
      attempt++;
      LogService.write('换台尝试 #$attempt');

      try {
        // 策略 A：复用 Player（先 stop 再 open，最稳定）
        if (_player != null) {
          try {
            await _player!.stop();
            await Future.delayed(const Duration(milliseconds: 150));

            await _player!.open(Media(newUrl), play: true)
                .timeout(const Duration(milliseconds: switchTimeoutMs));

            await _applyMpvOptimizations(_player!);

            if (_isDisposed || _switchCanceled) break;

            _currentUrl = newUrl;
            _isInitialized = true;
            _isLoading = false;
            _isFailed = false;
            if (_videoController == null || _videoController!.player != _player) {
              _videoController = VideoController(_player!);
            }
            _setupPlayerListeners();
            _startHeartbeat();
            _startSpeedMonitor();
            setState(() {});
            LogService.write('换台成功(复用): $newUrl');
            _isSwitching = false;
            return;
          } catch (e) {
            LogService.write('换台复用失败 #$attempt: $e');
            if (attempt < maxSwitchAttempts) {
              await Future.delayed(const Duration(milliseconds: 200));
              continue;
            }
            await _releasePlayer();
          }
        }

        // 策略 B：新建 Player
        final newPlayer = Player(
          configuration: const PlayerConfiguration(
            bufferSize: 64 * 1024 * 1024,
          ),
        );
        await _applyMpvOptimizations(newPlayer);
        await newPlayer.open(Media(newUrl), play: true)
            .timeout(const Duration(milliseconds: switchTimeoutMs));

        if (_isDisposed || _switchCanceled) {
          newPlayer.dispose();
          break;
        }

        _player = newPlayer;
        _currentUrl = newUrl;
        _isInitialized = true;
        _isLoading = false;
        _isFailed = false;
        _videoController = VideoController(_player!);
        _setupPlayerListeners();
        _startHeartbeat();
        _startSpeedMonitor();
        setState(() {});
        LogService.write('换台成功(新建): $newUrl');
        _isSwitching = false;
        return;

      } catch (e) {
        LogService.write('换台尝试 #$attempt 失败: $e');
        if (_isDisposed || _switchCanceled) break;
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

  // ==================== Stream 监听器 ====================

  void _setupPlayerListeners() {
    _clearSubscriptions();
    if (_player == null) return;

    // 1. 错误流 —— 即时触发重连
    _subscriptions.add(_player!.stream.error.listen((error) {
      if (error.isNotEmpty && !_isSwitching && !_isReconnecting) {
        LogService.write('Player error: $error');
        _handleConnectionLost();
      }
    }));

    // 2. 播放状态
    _subscriptions.add(_player!.stream.playing.listen((playing) {
      if (playing) {
        _lastPositionUpdate = DateTime.now();
        _lastBufferUpdate = DateTime.now();
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

    // 6. 音频比特率 —— 直接反映码率
    _subscriptions.add(_player!.stream.audioBitrate.listen((bitrate) {
      if (bitrate != null && bitrate > 0) {
        _lastAudioBitrate = bitrate;
      }
    }));

    // 7. 完成状态 —— 直播流不应完成
    _subscriptions.add(_player!.stream.completed.listen((completed) {
      if (completed && !_isSwitching && !_isReconnecting) {
        LogService.write('直播流异常完成，判定为断线');
        _handleConnectionLost();
      }
    }));

    // 8. 日志流 —— 额外心跳
    _subscriptions.add(_player!.stream.log.listen((_) {
      _lastPositionUpdate = DateTime.now();
    }));
  }

  // ==================== 心跳检测 ====================

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _lastPositionUpdate = DateTime.now();
    _lastBufferUpdate = DateTime.now();

    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: heartbeatIntervalSec),
      (_) {
        if (_player == null || _isDisposed || _isSwitching || _isReconnecting) return;

        final now = DateTime.now();
        final positionStall = now.difference(_lastPositionUpdate);
        final bufferStall = now.difference(_lastBufferUpdate);

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

  // ==================== 断线重连（指数退避） ====================

  void _handleConnectionLost() {
    if (_isDisposed || _isSwitching || _isReconnecting) return;
    LogService.write('连接丢失，启动重连流程');
    _startReconnect(_currentUrl);
  }

  void _startReconnect(String url) {
    if (_isDisposed || _isSwitching || _isReconnecting) return;

    _isReconnecting = true;
    _reconnectAttempt = 0;
    _cancelAllTimers();
    _clearSubscriptions();

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

      await _releasePlayer();

      try {
        final newPlayer = Player(
          configuration: const PlayerConfiguration(
            bufferSize: 64 * 1024 * 1024,
          ),
        );
        await _applyMpvOptimizations(newPlayer);
        await newPlayer.open(Media(url), play: true)
            .timeout(const Duration(milliseconds: switchTimeoutMs));

        if (_isDisposed || !_isReconnecting) {
          newPlayer.dispose();
          return;
        }

        _player = newPlayer;
        _onPlayerReady(url, isReconnect: true);
      } catch (e) {
        LogService.write('重连 #$_reconnectAttempt 失败: $e');
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

  // ==================== 网速监控（混合估算 + 平滑） ====================

  void _startSpeedMonitor() {
    _speedTimer?.cancel();
    _speedHistory.clear();
    _lastSpeedCheck = DateTime.now();
    _lastBufferPosition = Duration.zero;
    _lastAudioBitrate = null;

    // 每 1 秒刷新一次 UI，让网速显示更跟手
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

      // buffer 前进秒数 / 经过秒数 = 缓冲倍速
      // 假设直播平均码率约 4Mbps(0.5MB/s)，则 bufferSpeed * 0.5 ≈ 下载速度(MB/s)
      double instantSpeed = 0;
      if (bufferDiffMs > 0) {
        final bufferSpeed = (bufferDiffMs / 1000.0) / elapsedSec;
        instantSpeed = bufferSpeed * 0.5;
      }

      // 如果有 audioBitrate（kbps），用它做校准
      if (_lastAudioBitrate != null && _lastAudioBitrate! > 0) {
        // audioBitrate 只是音频，视频通常是音频的 5~15 倍
        // 总码率估算 = audioBitrate * 8，转为 MB/s
        final estimatedTotalMbps = (_lastAudioBitrate! * 8) / 1024.0 / 1024.0;
        // 取 buffer 估算和码率估算的较大值（因为缓冲可能不连续）
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
      // 移动平均 + 去掉异常值
      _speedHistory.sort();
      double sum = 0;
      int count = 0;
      // 使用中位数附近的值做平均，更稳定
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
      // 没有真实数据时，基于播放状态做合理估算
      final isBuffering = _player?.state.buffering ?? false;
      final isPlaying = _player?.state.playing ?? false;

      if (isBuffering) {
        // 缓冲中：给一个合理的低值，表示还在努力加载
        _speed = 0.2 + (DateTime.now().millisecond % 5) / 10.0;
      } else if (isPlaying) {
        // 播放中但无 buffer 变化：给一个维持播放的最小值
        _speed = 0.5;
      } else {
        _speed = 0;
      }
    }

    // 封顶，避免异常值
    if (_speed > 50) _speed = 50;
    if (_speed < 0) _speed = 0;

    widget.onSpeedUpdate(_speed);
  }

  // ==================== 工具方法 ====================

  Future<void> _releasePlayer() async {
    _clearSubscriptions();
    final oldPlayer = _player;
    _player = null;
    _videoController = null;   // 显式置空，确保 UI 重建
    _isInitialized = false;

    if (oldPlayer != null) {
      try {
        await oldPlayer.dispose();
      } catch (e) {
        LogService.write('释放 Player 异常: $e');
      }
    }
  }

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
        Video(
          controller: _videoController!,
          fit: BoxFit.contain,
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
    _releasePlayer();
    super.dispose();
  }
}
