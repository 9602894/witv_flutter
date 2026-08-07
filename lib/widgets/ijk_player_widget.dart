import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  MethodChannel? _channel;
  Timer? _speedTimer;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _startSpeedTimer();
  }

  @override
  void didUpdateWidget(covariant IjkPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 关键：URL 变化时不重建 PlatformView，直接发 setUrl 指令
    if (widget.url != oldWidget.url) {
      _setUrl(widget.url);
    }
  }

  void _startSpeedTimer() {
    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      widget.onSpeedUpdate?.call(0.0);
    });
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel('ijkplayer_view_$id');
    _channel?.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onError':
          if (mounted) setState(() => _isLoading = false);
          widget.onError?.call();
          break;
        case 'onInfo':
          final what = call.arguments['what'] as int?;
          // 首帧渲染（what == 3）时隐藏 loading
          if (what == 3 && mounted) {
            setState(() => _isLoading = false);
          }
          break;
      }
    });
    _setUrl(widget.url);
  }

  void _setUrl(String url) {
    if (mounted) setState(() => _isLoading = true);
    _channel?.invokeMethod('setUrl', {'url': url});
  }

  @override
  void dispose() {
    _speedTimer?.cancel();
    _channel?.invokeMethod('release');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 关键：去掉 ValueKey(widget.url)，不复建 PlatformView
    return Stack(
      fit: StackFit.expand,
      children: [
        AndroidView(
          viewType: 'ijkplayer_view',
          creationParams: {'url': widget.url},
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _onPlatformViewCreated,
        ),
        if (_isLoading)
          Container(
            color: Colors.black,
            child: const Center(
              child: SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          ),
      ],
    );
  }
}
