import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/log_service.dart';

/// MediaKit 播放器组件（m3u8 + TS 终极修复版 v4）
///
/// 核心修复：
/// 1. 视频参数必须 pixelformat != null 才算有效，解决松视1画面不动
/// 2. 音频参数必须 sampleRate > 0 才算有效，解决没声音
/// 3. 竞态条件：重连/换台/软刷新互斥锁，避免流程重叠
/// 4. pixelformat null 时自动软刷新 + 重选轨道，不触发重连
/// 5. m3u8 配置简化，移除 force-seekable 冲突
/// 6. 格式切换时（ts↔m3u8）重建 Player，避免解码器残留
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

enum _StreamFormat { m3u8, ts, unknown }

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
  Player? _player;
  VideoController? _videoController;

  bool _isInitialized = false;
  bool _isLoading = true;
  bool _isFailed = false;
  bool _isDisposed = false;
  String _currentUrl = '';
  _StreamFormat _currentFormat = _StreamFormat.unknown;

  bool _isSwitching = false;
  bool _switchCanceled = false;
  double _videoOpacity = 1.0;

  bool _isReconnecting = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;

  final List<StreamSubscription> _subscriptions = [];

  DateTime _lastPositionUpdate = DateTime.now();
  DateTime _lastBufferUpdate = DateTime.now();
  Timer? _heartbeatTimer;
  bool _heartbeatPlaying = false;
  bool _softRefreshing = false;

  double _speed = 0;
  final List<double> _speedHistory = [];
  Duration _lastBufferPosition = Duration.zero;
  DateTime _lastSpeedCheck = DateTime.now();
  double? _lastAudioBitrate;
  Timer? _speedTimer;

  static final Map<String, _ChannelConfig> _channelMemory = {};

  int _hwdecErrorCount = 0;
  static const int _hwdecErrorThreshold = 3;

  List<AudioTrack> _availableAudioTracks = [];
  List<VideoTrack> _availableVideoTracks = [];
  bool _audioTrackSelected = false;
  bool _videoTrackSelected = false;
  DateTime? _lastValidVideoParamsTime;
  DateTime? _lastValidAudioParamsTime;
  Timer? _trackCheckTimer;

  // 记录上一次格式，用于判断是否需要重建 Player
  _StreamFormat _lastFormat = _StreamFormat.unknown;

  static const int switchTimeoutMsM3u8 = 5000;
  static const int switchTimeoutMsTs = 6000;
  static const int maxSwitchAttempts = 3;
  static const int reconnectBaseDelayMs = 3000;
  static const int maxReconnectAttempts = 10;
  static const int heartbeatIntervalSec = 3;
  static const int maxStallSec = 12;
  static const int softRefreshStallSec = 4;
  static const int paramsNullTimeoutSec = 5;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
    _currentFormat = _detectFormat(widget.url);
    _lastFormat = _currentFormat;
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

  _StreamFormat _detectFormat(String url) {
    final lower = url.toLowerCase();
    if (lower.endsWith('.m3u8') || lower.contains('.m3u8?')) {
      return _StreamFormat.m3u8;
    }
    if (lower.endsWith('.ts') || lower.contains('.ts?')) {
      return _StreamFormat.ts;
    }
    return _StreamFormat.m3u8;
  }

  int get _switchTimeoutMs {
    return _currentFormat == _StreamFormat.ts ? switchTimeoutMsTs : switchTimeoutMsM3u8;
  }

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

  _ChannelConfig _getChannelConfig(String url) {
    final key = _extractChannelName(url);
    return _channelMemory.putIfAbsent(key, () => _ChannelConfig());
  }

  Future<void> _applyMpvOptimizations(Player player, _ChannelConfig config) async {
    if (player.platform is! NativePlayer) return;
    final native = player.platform as NativePlayer;
    final fmt = _currentFormat;

    try {
      if (fmt == _StreamFormat.ts) {
        await native.setProperty('demuxer-lavf-format', 'mpegts');
        await native.setProperty('force-seekable', 'no');
        await native.setProperty('demuxer-lavf-analyzeduration', '0.5');
        await native.setProperty('demuxer-lavf-probesize', '131072');
        LogService.write('TS优化: format=mpegts');
      } else {
        // m3u8: 让 mpv 自动识别，不过度干预
        await native.setProperty('demuxer-lavf-format', 'auto');
        // HLS 直播不需要强制 seekable，让 mpv 根据 playlist 决定
        await native.setProperty('demuxer-lavf-analyzeduration', '1.0');
        await native.setProperty('demuxer-lavf-probesize', '262144');
        LogService.write('m3u8优化: format=auto, analyzeduration=1s');
      }

      // 通用流畅参数
      await native.setProperty('cache', 'yes');
      await native.setProperty('demuxer-max-bytes', '64M');
      await native.setProperty('demuxer-max-back-bytes', '32M');
      await native.setProperty('demuxer-readahead-secs', '10');
      // 移除 vd-queue，某些流会因此卡住
      // await native.setProperty('vd-queue-enable', 'yes');
      await native.setProperty('vd-lavc-threads', '4');
      await native.setProperty('vd-lavc-skiploopfilter', 'nonref');
      await native.setProperty('video-sync', 'audio');
      await native.setProperty('framedrop', 'decoder');
      await native.setProperty('opengl-glfinish', 'yes');

      final hwdec = config.useHwdec ? 'auto-safe' : 'no';
      await native.setProperty('hwdec', hwdec);

      await native.setProperty('audio-channels', 'stereo');
      await native.setProperty('volume-normalize', 'no');
      await native.setProperty('audio-buffer', '0.2');

      await native.setProperty('network-timeout', '10');
      await native.setProperty('reconnect', 'yes');
      await native.setProperty('reconnect-stream-error', 'yes');
      await native.setProperty('reconnect-on-network-error', 'yes');
      await native.setProperty('reconnect-delay-max', '5');
      await native.setProperty('demuxer-hysteresis-secs', '5');
    } catch (e) {
      LogService.write('mpv优化部分失败: $e');
    }
  }

  Future<void> _initPlayer(String url, {bool isReconnect = false}) async {
    if (_isDisposed) return;
    if (_isSwitching && !isReconnect) return;

    _cancelReconnect();
    _clearSubscriptions();
    _cancelTrackCheck();
    _resetTrackState();
    _currentFormat = _detectFormat(url);

    if (!isReconnect) {
      setState(() {
        _isLoading = true;
        _isFailed = false;
      });
    }

    final config = _getChannelConfig(url);
    LogService.write('${isReconnect ? "重连" : "加载"}频道: ${_extractChannelName(url)} [${_fmtName(_currentFormat)}]');

    try {
      // 【关键修复】格式切换时重建 Player，避免解码器残留
      final needRecreate = _player != null && _currentFormat != _lastFormat && _lastFormat != _StreamFormat.unknown;
      if (_player == null || needRecreate) {
        if (_player != null) {
          LogService.write('格式切换 ${_fmtName(_lastFormat)}→${_fmtName(_currentFormat)}，重建 Player');
          try {
            await _player!.dispose();
          } catch (_) {}
          _player = null;
          _videoController = null;
        }
        _player = Player(
          configuration: const PlayerConfiguration(
            bufferSize: 64 * 1024 * 1024,
          ),
        );
        _videoController = VideoController(_player!);
      }
      _lastFormat = _currentFormat;

      await _player!.stop();
      await Future.delayed(const Duration(milliseconds: 200));
      await _applyMpvOptimizations(_player!, config);
      await _player!.setPlaylistMode(PlaylistMode.single);
      await _player!.setAudioDevice(AudioDevice.auto());
      await _player!.setVolume(100.0);
      await _player!.setAudioTrack(AudioTrack.auto());
      await _player!.setVideoTrack(VideoTrack.auto());

      await _player!.open(Media(url), play: true)
          .timeout(Duration(milliseconds: _switchTimeoutMs));

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
    _softRefreshing = false;
    _resetTrackState();
    _lastValidVideoParamsTime = null;
    _lastValidAudioParamsTime = null;

    config.onSuccess();

    _setupPlayerListeners();
    _startHeartbeat();
    _startSpeedMonitor();
    _startTrackCheck();
    _fadeInVideo();

    // 延迟强制选择轨道
    Future.delayed(const Duration(milliseconds: 800), () {
      if (_isDisposed || _player == null) return;
      _forceSelectTracks();
    });

    if (mounted) setState(() {});
    LogService.write('${isReconnect ? "重连" : "加载"}成功: $url [${_fmtName(_currentFormat)}]');
  }

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
    _cancelTrackCheck();
    _fadeOutVideo();
    _resetTrackState();

    final newFormat = _detectFormat(newUrl);
    _currentFormat = newFormat;

    setState(() {
      _isLoading = true;
      _isFailed = false;
    });

    final config = _getChannelConfig(newUrl);
    final timeout = newFormat == _StreamFormat.ts ? switchTimeoutMsTs : switchTimeoutMsM3u8;
    LogService.write('换台: ${_extractChannelName(newUrl)} [${_fmtName(newFormat)}]');

    int attempt = 0;
    while (!_isDisposed && !_switchCanceled && attempt < maxSwitchAttempts) {
      attempt++;
      LogService.write('换台尝试 #$attempt [${_fmtName(newFormat)}]');

      try {
        // 格式切换时重建 Player
        final needRecreate = _player != null && newFormat != _lastFormat && _lastFormat != _StreamFormat.unknown;
        if (_player == null || needRecreate) {
          if (_player != null) {
            LogService.write('换台格式切换 ${_fmtName(_lastFormat)}→${_fmtName(newFormat)}，重建 Player');
            try {
              await _player!.dispose();
            } catch (_) {}
            _player = null;
            _videoController = null;
          }
          _player = Player(
            configuration: const PlayerConfiguration(
              bufferSize: 64 * 1024 * 1024,
            ),
          );
          _videoController = VideoController(_player!);
        }
        _lastFormat = newFormat;

        await _player!.stop();
        await Future.delayed(const Duration(milliseconds: 200));
        await _applyMpvOptimizations(_player!, config);
        await _player!.setPlaylistMode(PlaylistMode.single);
        await _player!.setAudioDevice(AudioDevice.auto());
        await _player!.setVolume(100.0);
        await _player!.setAudioTrack(AudioTrack.auto());
        await _player!.setVideoTrack(VideoTrack.auto());
        await _player!.open(Media(newUrl), play: true)
            .timeout(Duration(milliseconds: timeout));

        if (_isDisposed || _switchCanceled) break;

        _currentUrl = newUrl;
        _isInitialized = true;
        _isLoading = false;
        _isFailed = false;
        _setupPlayerListeners();
        _startHeartbeat();
        _startSpeedMonitor();
        _startTrackCheck();
        _fadeInVideo();
        setState(() {});
        LogService.write('换台成功: $newUrl [${_fmtName(newFormat)}]');
        config.onSuccess();
        _isSwitching = false;
        return;

      } catch (e) {
        LogService.write('换台 #$attempt 失败 [${_fmtName(newFormat)}]: $e');
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

  void _resetTrackState() {
    _audioTrackSelected = false;
    _videoTrackSelected = false;
    _availableAudioTracks = [];
    _availableVideoTracks = [];
  }

  String _fmtName(_StreamFormat fmt) {
    switch (fmt) {
      case _StreamFormat.m3u8:
        return 'm3u8';
      case _StreamFormat.ts:
        return 'ts';
      default:
        return 'unknown';
    }
  }

  void _forceSelectTracks() {
    if (_player == null || _isDisposed) return;

    final currentAudio = _player!.state.track.audio;
    final currentVideo = _player!.state.track.video;
    LogService.write('强制检查轨道: 音频=${currentAudio.id}, 视频=${currentVideo.id}');

    if ((currentAudio.id == 'auto' || currentAudio.id == 'no') &&
        _availableAudioTracks.isNotEmpty) {
      final real = _availableAudioTracks.firstWhere(
        (t) => t.id != 'no' && t.id != 'auto',
        orElse: () => _availableAudioTracks.first,
      );
      if (real.id != 'no' && real.id != 'auto') {
        LogService.write('强制选择音频: ${real.id}');
        _player!.setAudioTrack(real);
        _audioTrackSelected = true;
      }
    }

    if ((currentVideo.id == 'auto' || currentVideo.id == 'no') &&
        _availableVideoTracks.isNotEmpty) {
      final real = _availableVideoTracks.firstWhere(
        (t) => t.id != 'no' && t.id != 'auto',
        orElse: () => _availableVideoTracks.first,
      );
      if (real.id != 'no' && real.id != 'auto') {
        LogService.write('强制选择视频: ${real.id}');
        _player!.setVideoTrack(real);
        _videoTrackSelected = true;
      }
    }
  }

  void _startTrackCheck() {
    _cancelTrackCheck();
    int checkCount = 0;
    _trackCheckTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      checkCount++;
      if (_isDisposed || _player == null) {
        timer.cancel();
        return;
      }

      final currentVideo = _player!.state.track.video;
      final currentAudio = _player!.state.track.audio;
      LogService.write('轨道检查 #$checkCount: 视频=${currentVideo.id}, 音频=${currentAudio.id}');

      if ((currentVideo.id == 'auto' || currentVideo.id == 'no') &&
          _availableVideoTracks.isNotEmpty) {
        final realTrack = _availableVideoTracks.firstWhere(
          (t) => t.id != 'no' && t.id != 'auto',
          orElse: () => _availableVideoTracks.first,
        );
        if (realTrack.id != 'no' && realTrack.id != 'auto') {
          LogService.write('轨道检查: 重新选择视频轨道 ${realTrack.id}');
          _player!.setVideoTrack(realTrack);
        }
      }

      if ((currentAudio.id == 'auto' || currentAudio.id == 'no') &&
          _availableAudioTracks.isNotEmpty) {
        final realTrack = _availableAudioTracks.firstWhere(
          (t) => t.id != 'no' && t.id != 'auto',
          orElse: () => _availableAudioTracks.first,
        );
        if (realTrack.id != 'no' && realTrack.id != 'auto') {
          LogService.write('轨道检查: 重新选择音频轨道 ${realTrack.id}');
          _player!.setAudioTrack(realTrack);
        }
      }

      if (checkCount >= 5) {
        timer.cancel();
        LogService.write('轨道检查结束');
      }
    });
  }

  void _cancelTrackCheck() {
    _trackCheckTimer?.cancel();
    _trackCheckTimer = null;
  }

  void _setupPlayerListeners() {
    _clearSubscriptions();
    if (_player == null) return;

    // 1. 错误流
    _subscriptions.add(_player!.stream.error.listen((error) {
      if (error.isNotEmpty && !_isSwitching && !_isReconnecting && !_softRefreshing) {
        LogService.write('Player error: $error');
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

    // 5. 缓冲位置
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

    // 7. completed 流
    _subscriptions.add(_player!.stream.completed.listen((completed) {
      if (completed) {
        LogService.write('completed=true（PlaylistMode.single 已自动循环）');
      }
    }));

    // 8. 日志流
    _subscriptions.add(_player!.stream.log.listen((_) {
      _lastPositionUpdate = DateTime.now();
    }));

    // 9. 音视频轨道监听
    _subscriptions.add(_player!.stream.tracks.listen((tracks) {
      final audios = tracks.audio;
      if (audios.isNotEmpty && audios != _availableAudioTracks) {
        _availableAudioTracks = audios;
        LogService.write('检测到 ${audios.length} 个音频轨道');
        for (final t in audios) {
          LogService.write('  音轨: id=${t.id}, title=${t.title}, lang=${t.language}');
        }
        final realAudio = audios.firstWhere(
          (t) => t.id != 'no' && t.id != 'auto',
          orElse: () => AudioTrack.no(),
        );
        if (realAudio.id != 'no' && !_audioTrackSelected) {
          LogService.write('自动选择音频轨道: ${realAudio.id}');
          _player!.setAudioTrack(realAudio);
          _audioTrackSelected = true;
        }
      }

      final videos = tracks.video;
      if (videos.isNotEmpty && videos != _availableVideoTracks) {
        _availableVideoTracks = videos;
        LogService.write('检测到 ${videos.length} 个视频轨道');
        for (final t in videos) {
          LogService.write('  视频轨: id=${t.id}, title=${t.title}, lang=${t.language}');
        }
        final realVideo = videos.firstWhere(
          (t) => t.id != 'no' && t.id != 'auto',
          orElse: () => VideoTrack.no(),
        );
        if (realVideo.id != 'no' && !_videoTrackSelected) {
          LogService.write('自动选择视频轨道: ${realVideo.id}');
          _player!.setVideoTrack(realVideo);
          _videoTrackSelected = true;
        }
      }
    }));

    // 10. 当前轨道监听
    _subscriptions.add(_player!.stream.track.listen((track) {
      final audio = track.audio;
      final video = track.video;
      LogService.write('当前轨道: 音频=${audio.id}, 视频=${video.id}');

      if ((audio.id == 'no' || audio.id == 'auto') && _availableAudioTracks.isNotEmpty) {
        final firstReal = _availableAudioTracks.firstWhere(
          (t) => t.id != 'no' && t.id != 'auto',
          orElse: () => _availableAudioTracks.first,
        );
        if (firstReal.id != 'no' && firstReal.id != 'auto') {
          LogService.write('重新选择音频轨道: ${firstReal.id}');
          _player!.setAudioTrack(firstReal);
        }
      }

      if ((video.id == 'no' || video.id == 'auto') && _availableVideoTracks.isNotEmpty) {
        final firstReal = _availableVideoTracks.firstWhere(
          (t) => t.id != 'no' && t.id != 'auto',
          orElse: () => _availableVideoTracks.first,
        );
        if (firstReal.id != 'no' && firstReal.id != 'auto') {
          LogService.write('重新选择视频轨道: ${firstReal.id}');
          _player!.setVideoTrack(firstReal);
        }
      }
    }));

    // 11. 音频参数监听
    _subscriptions.add(_player!.stream.audioParams.listen((params) {
      if (params != null && params.sampleRate != null && params.sampleRate! > 0) {
        _lastValidAudioParamsTime = DateTime.now();
        LogService.write('音频参数: rate=${params.sampleRate}, ch=${params.channels}');
      } else {
        LogService.write('音频参数: null');
      }
    }));

    // 12. 视频参数监听（关键修复：要求 pixelformat != null）
    _subscriptions.add(_player!.stream.videoParams.listen((params) {
      if (params != null &&
          params.w != null &&
          params.h != null &&
          params.pixelformat != null) {
        _lastValidVideoParamsTime = DateTime.now();
        LogService.write('视频参数: ${params.w}x${params.h}, pixelformat=${params.pixelformat}');
      } else {
        LogService.write('视频参数: 无效 (pixelformat=${params?.pixelformat})');
      }
    }));
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _lastPositionUpdate = DateTime.now();
    _lastBufferUpdate = DateTime.now();
    _heartbeatPlaying = false;
    _lastValidVideoParamsTime = null;
    _lastValidAudioParamsTime = null;

    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: heartbeatIntervalSec),
      (_) {
        if (_player == null || _isDisposed || _isSwitching || _isReconnecting || _softRefreshing) return;

        final now = DateTime.now();
        final positionStall = now.difference(_lastPositionUpdate);
        final bufferStall = now.difference(_lastBufferUpdate);

        // 视频参数无效超 5 秒：TS 软刷新，m3u8 重连
        if (_lastValidVideoParamsTime != null) {
          final vStall = now.difference(_lastValidVideoParamsTime!);
          if (vStall > const Duration(seconds: paramsNullTimeoutSec)) {
            if (_currentFormat == _StreamFormat.ts) {
              LogService.write('视频参数无效超 ${vStall.inSeconds}s，执行 TS 软刷新');
              _performSoftRefresh();
            } else {
              LogService.write('视频参数无效超 ${vStall.inSeconds}s，判定源问题');
              _handleConnectionLost();
            }
            return;
          }
        }

        // 音频参数无效超 5 秒，尝试重选音轨
        if (_lastValidAudioParamsTime != null && _availableAudioTracks.isNotEmpty) {
          final aStall = now.difference(_lastValidAudioParamsTime!);
          if (aStall > const Duration(seconds: paramsNullTimeoutSec)) {
            LogService.write('音频参数无效超 ${aStall.inSeconds}s，尝试重选音轨');
            _forceSelectTracks();
          }
        }

        if (_heartbeatPlaying) {
          _lastPositionUpdate = now;
          _lastBufferUpdate = now;

          if (_currentFormat == _StreamFormat.ts &&
              positionStall > const Duration(seconds: softRefreshStallSec) &&
              bufferStall > const Duration(seconds: softRefreshStallSec)) {
            LogService.write('TS软刷新: playing=true 但 position停${positionStall.inSeconds}s');
            _performSoftRefresh();
          }
          return;
        }

        if (positionStall > const Duration(seconds: maxStallSec) &&
            bufferStall > const Duration(seconds: maxStallSec)) {
          LogService.write('心跳: position停${positionStall.inSeconds}s, buffer停${bufferStall.inSeconds}s，断线');
          _handleConnectionLost();
        }
      },
    );
  }

  Future<void> _performSoftRefresh() async {
    if (_isDisposed || _isSwitching || _isReconnecting || _softRefreshing) return;
    _softRefreshing = true;

    LogService.write('执行 TS 软刷新: $_currentUrl');
    try {
      await _player!.stop();
      await Future.delayed(const Duration(milliseconds: 300));
      await _player!.open(Media(_currentUrl), play: true)
          .timeout(Duration(milliseconds: _switchTimeoutMs));
      _resetTrackState();
      _lastValidVideoParamsTime = null;
      _lastValidAudioParamsTime = null;
      _startTrackCheck();
      _lastPositionUpdate = DateTime.now();
      _lastBufferUpdate = DateTime.now();
      LogService.write('TS 软刷新成功');
    } catch (e) {
      LogService.write('TS 软刷新失败: $e');
      _handleConnectionLost();
    } finally {
      _softRefreshing = false;
    }
  }

  void _handleConnectionLost() {
    if (_isDisposed || _isSwitching || _isReconnecting) return;
    LogService.write('连接丢失，启动重连 [${_fmtName(_currentFormat)}]');
    _startReconnect(_currentUrl);
  }

  void _startReconnect(String url) {
    if (_isDisposed || _isSwitching || _isReconnecting) return;

    _isReconnecting = true;
    _reconnectAttempt = 0;
    _cancelAllTimers();
    _clearSubscriptions();
    _cancelTrackCheck();
    _fadeOutVideo();
    _resetTrackState();

    LogService.write('启动断线重连 [${_fmtName(_currentFormat)}]');
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
      // 【竞态条件修复】检查是否还在重连状态，且没有正在换台
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
        await Future.delayed(const Duration(milliseconds: 200));
        await _applyMpvOptimizations(_player!, config);
        await _player!.setPlaylistMode(PlaylistMode.single);
        await _player!.setAudioDevice(AudioDevice.auto());
        await _player!.setVolume(100.0);
        await _player!.setAudioTrack(AudioTrack.auto());
        await _player!.setVideoTrack(VideoTrack.auto());
        await _player!.open(Media(url), play: true)
            .timeout(Duration(milliseconds: _switchTimeoutMs));

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
    _trackCheckTimer?.cancel();
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
