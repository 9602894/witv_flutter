import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/log_service.dart';

/// MediaKit 播放器组件（优化版）
/// 
/// 核心优化：
/// 1. **换台速度**：优先复用 Player 实例直接 open()，避免 dispose/create 开销；失败才回退创建新 Player
/// 2. **断线检测**：使用 Stream 监听(error/position/buffer/completed) + 心跳机制，替代轮询；直播流停止能即时捕获
/// 3. **断线重连**：指数退避(2s→4s→8s→10s)，带最大次数限制；错误流触发即时重连
/// 4. **资源管理**：统一 Subscription/Timer 管理，dispose 时彻底清理，避免内存泄漏
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

  // Stream 订阅（必须集中管理，防止内存泄漏）
  final List<StreamSubscription> _subscriptions = [];

  // 心跳检测（替代 5 秒轮询）
  DateTime _lastPositionUpdate = DateTime.now();
  DateTime _lastBufferUpdate = DateTime.now();
  Timer? _heartbeatTimer;

  // 网速监控
  double _speed = 0;
  Duration _lastBufferPosition = Duration.zero;
  DateTime _lastSpeedCheck = DateTime.now();
  Timer? _speedTimer;

  // ========== 常量配置 ==========
  /// 换台/打开超时（复用 Player 时 2 秒足够，新建 Player 时略长）
  static const int switchTimeoutMs = 2500;
  /// 换台最大尝试次数（复用失败 + 新建失败）
  static const int maxSwitchAttempts = 3;
  /// 重连基础延迟（指数退避：2s → 4s → 8s → 10s封顶）
  static const int reconnectBaseDelayMs = 2000;
  /// 最大重连次数
  static const int maxReconnectAttempts = 10;
  /// 心跳检测间隔
  static const int heartbeatIntervalSec = 3;
  /// 超过此时间无 position/buffer 更新即判定断线（直播流用）
  static const int maxStallSec = 8;

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
      LogService.write('MediaKit 初始化最终失败: \$e');
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
      // 如果正在初始化中，直接走换台逻辑；_switchToNewUrl 会强制释放旧资源
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
        LogService.write('MediaKit 二次初始化失败: \$e');
        rethrow;
      }
    }
  }

  // ==================== 核心：初始化 / 重连 ====================

  Future<void> _initPlayer(String url, {bool isReconnect = false}) async {
    if (_isDisposed) return;
    // 如果正在换台，不重入（换台逻辑自己处理）
    if (_isSwitching && !isReconnect) return;

    _cancelReconnect();
    _clearSubscriptions();

    if (!isReconnect) {
      setState(() {
        _isLoading = true;
        _isFailed = false;
      });
    }

    LogService.write('\${isReconnect ? "重连" : "加载"}频道: \${_extractChannelName(url)}');

    try {
      // 【核心优化 1】优先复用现有 Player，直接 open()，省去 dispose/create 时间
      if (_player != null) {
        try {
          await _player!.open(Media(url), play: true)
              .timeout(const Duration(milliseconds: switchTimeoutMs));
          _onPlayerReady(url, isReconnect: isReconnect);
          return;
        } catch (e) {
          LogService.write('复用 Player 失败: \$e，回退到新建 Player');
          await _releasePlayer();
        }
      }

      // 回退：创建新 Player
      _player = Player();
      await _player!.open(Media(url), play: true)
          .timeout(const Duration(milliseconds: switchTimeoutMs));
      _onPlayerReady(url, isReconnect: isReconnect);

    } catch (e) {
      LogService.write('\${isReconnect ? "重连" : "加载"}失败: \$e');
      if (_isDisposed) return;

      await _releasePlayer();

      if (mounted) {
        setState(() {
          _isLoading = false;
          _isFailed = true;
        });
        widget.onError();
      }

      // 首次加载失败才启动重连；重连失败由 _attemptReconnect 自己递归
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

    // VideoController 复用：同一个 Player 不需要重新创建
    _videoController ??= VideoController(_player!);

    _setupPlayerListeners();
    _startHeartbeat();
    _startSpeedMonitor();

    if (mounted) setState(() {});
    LogService.write('\${isReconnect ? "重连" : "加载"}成功: \$url');
  }

  // ==================== 核心：换台（极速版） ====================

  Future<void> _switchToNewUrl(String newUrl) async {
    if (_isDisposed) return;

    // 1. 强制取消旧流程
    _switchCanceled = true;
    _isSwitching = false;
    await Future.delayed(const Duration(milliseconds: 100));
    if (_isDisposed) return;

    // 2. 重置状态，强制释放旧资源（确保旧 Player 不会和新流程冲突）
    _switchCanceled = false;
    _isSwitching = true;
    _cancelReconnect();
    _cancelAllTimers();
    await _releasePlayer();

    setState(() {
      _isLoading = true;
      _isFailed = false;
    });

    LogService.write('开始换台: \${_extractChannelName(newUrl)}');

    int attempt = 0;
    while (!_isDisposed && !_switchCanceled && attempt < maxSwitchAttempts) {
      attempt++;
      LogService.write('换台尝试 #\$attempt');

      try {
        // 策略 A：复用 Player（最快，通常 <500ms）
        if (_player != null) {
          try {
            await _player!.open(Media(newUrl), play: true)
                .timeout(const Duration(milliseconds: switchTimeoutMs));

            if (_isDisposed || _switchCanceled) break;

            _currentUrl = newUrl;
            _isInitialized = true;
            _isLoading = false;
            _isFailed = false;
            _videoController ??= VideoController(_player!);
            _setupPlayerListeners();
            _startHeartbeat();
            _startSpeedMonitor();
            setState(() {});
            LogService.write('换台成功(复用): \$newUrl');
            _isSwitching = false;
            return;
          } catch (e) {
            LogService.write('换台复用失败 #\$attempt: \$e');
            // 非最后一次尝试时，短暂等待再试
            if (attempt < maxSwitchAttempts) {
              await Future.delayed(const Duration(milliseconds: 200));
              continue;
            }
            // 最后一次尝试失败，释放旧 Player，回退到策略 B
            await _releasePlayer();
          }
        }

        // 策略 B：新建 Player（稍慢，但干净）
        final newPlayer = Player();
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
        LogService.write('换台成功(新建): \$newUrl');
        _isSwitching = false;
        return;

      } catch (e) {
        LogService.write('换台尝试 #\$attempt 失败: \$e');
        if (_isDisposed || _switchCanceled) break;
        if (attempt < maxSwitchAttempts) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }
    }

    // 换台彻底失败
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

  // ==================== Stream 监听器（核心改进） ====================

  void _setupPlayerListeners() {
    _clearSubscriptions();
    if (_player == null) return;

    // 1. 错误流 —— 即时触发重连（比轮询快得多）
    _subscriptions.add(_player!.stream.error.listen((error) {
      if (error.isNotEmpty && !_isSwitching && !_isReconnecting) {
        LogService.write('Player error: \$error');
        _handleConnectionLost();
      }
    }));

    // 2. 播放状态 —— 播放中时更新活跃时间
    _subscriptions.add(_player!.stream.playing.listen((playing) {
      if (playing) {
        _lastPositionUpdate = DateTime.now();
        _lastBufferUpdate = DateTime.now();
      }
    }));

    // 3. 位置变化 —— 直播流 position 更新意味着有数据流入
    _subscriptions.add(_player!.stream.position.listen((_) {
      _lastPositionUpdate = DateTime.now();
    }));

    // 4. 缓冲状态 —— 缓冲结束说明数据已到达
    _subscriptions.add(_player!.stream.buffering.listen((buffering) {
      if (!buffering) {
        _lastBufferUpdate = DateTime.now();
      }
    }));

    // 5. 缓冲位置 —— 用于网速估算 + 活跃检测
    _subscriptions.add(_player!.stream.buffer.listen((buffer) {
      _lastBufferUpdate = DateTime.now();
      _updateSpeed(buffer);
    }));

    // 6. 完成状态 —— 直播流不应完成，若完成说明服务器断流
    _subscriptions.add(_player!.stream.completed.listen((completed) {
      if (completed && !_isSwitching && !_isReconnecting) {
        LogService.write('直播流异常完成，判定为断线');
        _handleConnectionLost();
      }
    }));

    // 7. 日志流 —— 作为额外心跳（底层有日志输出说明连接还活着）
    _subscriptions.add(_player!.stream.log.listen((_) {
      _lastPositionUpdate = DateTime.now();
    }));
  }

  // ==================== 心跳检测（替代 5s 轮询） ====================

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

        // 直播流：position 和 buffer 都长时间不更新 = 断线
        if (positionStall > const Duration(seconds: maxStallSec) &&
            bufferStall > const Duration(seconds: maxStallSec)) {
          LogService.write(
            '心跳检测: position停滞\${positionStall.inSeconds}s, '
            'buffer停滞\${bufferStall.inSeconds}s，判定断线',
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
      LogService.write('重连次数达到上限 \$maxReconnectAttempts，放弃');
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

    // 指数退避：2s, 4s, 8s, 10s(max)
    final delayMs = reconnectBaseDelayMs * (1 << (_reconnectAttempt - 1));
    final cappedDelayMs = delayMs > 10000 ? 10000 : delayMs;

    LogService.write('重连 #\$_reconnectAttempt，\${cappedDelayMs}ms 后尝试');

    _reconnectTimer = Timer(Duration(milliseconds: cappedDelayMs), () async {
      if (_isDisposed || _isSwitching || !_isReconnecting) return;

      // 彻底释放旧资源再重连
      await _releasePlayer();

      try {
        final newPlayer = Player();
        await newPlayer.open(Media(url), play: true)
            .timeout(const Duration(milliseconds: switchTimeoutMs));

        if (_isDisposed || !_isReconnecting) {
          newPlayer.dispose();
          return;
        }

        _player = newPlayer;
        _onPlayerReady(url, isReconnect: true);
      } catch (e) {
        LogService.write('重连 #\$_reconnectAttempt 失败: \$e');
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

  // ==================== 网速监控（基于 buffer 变化估算） ====================

  void _startSpeedMonitor() {
    _speedTimer?.cancel();
    _lastSpeedCheck = DateTime.now();
    _lastBufferPosition = Duration.zero;

    // 每 2 秒刷新一次 UI 上的速度显示
    _speedTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  void _updateSpeed(Duration bufferPosition) {
    final now = DateTime.now();
    final elapsedSec = now.difference(_lastSpeedCheck).inMilliseconds / 1000.0;

    if (elapsedSec > 0.5) {
      final bufferDiffMs = bufferPosition.inMilliseconds - _lastBufferPosition.inMilliseconds;

      // 估算逻辑：buffer 前进秒数 / 经过秒数 ≈ 缓冲倍速
      // 假设直播码率约 4Mbps(0.5MB/s)，则 bufferSpeed * 0.5 ≈ 近似下载速度
      final bufferSpeed = bufferDiffMs > 0
          ? (bufferDiffMs / 1000.0) / elapsedSec
          : 0.0;

      _speed = bufferSpeed * 0.5; // 粗略换算为 MB/s
      if (_speed < 0) _speed = 0;

      widget.onSpeedUpdate(_speed);
    }

    _lastBufferPosition = bufferPosition;
    _lastSpeedCheck = now;
  }

  // ==================== 工具方法 ====================

  /// 彻底释放 Player 及相关资源
  Future<void> _releasePlayer() async {
    _clearSubscriptions();
    final oldPlayer = _player;
    _player = null;
    _videoController = null;
    _isInitialized = false;

    if (oldPlayer != null) {
      try {
        // 不调用 stop()，直接 dispose 更快；media_kit 内部会处理清理
        await oldPlayer.dispose();
      } catch (e) {
        LogService.write('释放 Player 异常: \$e');
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
              '\${_speed.toStringAsFixed(1)} M/s',
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
