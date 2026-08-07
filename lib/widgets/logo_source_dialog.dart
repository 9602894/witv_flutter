import 'package:flutter/material.dart';
import '../services/logo_service.dart';

class _SourceItem {
  final LogoSource source;
  bool enabled;
  _SourceItem({required this.source, this.enabled = false});
}

class LogoSourceSettingDialog extends StatefulWidget {
  final bool isFirstTime;
  const LogoSourceSettingDialog({super.key, this.isFirstTime = false});

  @override
  State<LogoSourceSettingDialog> createState() => _LogoSourceSettingDialogState();

  static Future<void> show(BuildContext context, {bool isFirstTime = false}) async {
    return showDialog(
      context: context,
      barrierDismissible: !isFirstTime,
      barrierColor: Colors.black.withOpacity(0.6),
      useSafeArea: false,
      builder: (_) => _DialogWrapper(isFirstTime: isFirstTime),
    );
  }
}

/// 外层包装：控制弹窗大小、位置、背景，确保非全屏、半透明
class _DialogWrapper extends StatelessWidget {
  final bool isFirstTime;
  const _DialogWrapper({required this.isFirstTime});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: size.width * 0.5,
          height: size.height * 0.5,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.75),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: LogoSourceSettingDialog(isFirstTime: isFirstTime),
          ),
        ),
      ),
    );
  }
}

class _LogoSourceSettingDialogState extends State<LogoSourceSettingDialog> {
  final List<_SourceItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final enabled = await LogoService().getEnabledSources();

    final allSources = LogoSource.values.toList();
    final ordered = <_SourceItem>[];

    for (final s in enabled) {
      ordered.add(_SourceItem(source: s, enabled: true));
      allSources.remove(s);
    }
    for (final s in allSources) {
      ordered.add(_SourceItem(source: s, enabled: false));
    }

    setState(() {
      _items.addAll(ordered);
      _loading = false;
    });
  }

  Future<void> _save() async {
    final enabled = _items.where((i) => i.enabled).map((i) => i.source).toList();
    if (enabled.isEmpty) {
      _showSnackBar('请至少选择一个台标来源');
      return;
    }

    await LogoService().setEnabledSources(enabled);

    if (mounted) {
      Navigator.of(context).pop();
      _showSnackBar('台标设置已保存（优先级: ${enabled.map((s) => s.displayName).join(' > ')}）');
    }
  }

  void _showSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _moveUp(int index) {
    if (index <= 0) return;
    setState(() {
      final temp = _items[index];
      _items[index] = _items[index - 1];
      _items[index - 1] = temp;
    });
  }

  void _moveDown(int index) {
    if (index >= _items.length - 1) return;
    setState(() {
      final temp = _items[index];
      _items[index] = _items[index + 1];
      _items[index + 1] = temp;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 标题
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            widget.isFirstTime ? '请选择台标来源' : '台标来源设置',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
        // 内容
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.isFirstTime)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text(
                      '尚未配置台标来源，请选择一种或多种方式获取频道台标。\n可勾选多个来源并调整优先级，程序会按顺序尝试获取。',
                      style: TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                  ),
                ..._buildSourceList(),
                const SizedBox(height: 8),
                const Text(
                  '提示：数字越小优先级越高。获取台标时按 1→2→3 顺序尝试，第一个成功即返回。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        // 按钮
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (!widget.isFirstTime)
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消', style: TextStyle(color: Colors.white70)),
                ),
              ElevatedButton(
                onPressed: _save,
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _buildSourceList() {
    final list = <Widget>[];
    for (int i = 0; i < _items.length; i++) {
      final item = _items[i];
      final realPriority = item.enabled
          ? _items.where((x) => x.enabled).toList().indexOf(item) + 1
          : null;

      list.add(
        Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          color: item.enabled
              ? Colors.blue.withOpacity(0.15)
              : Colors.white.withOpacity(0.05),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: item.enabled ? Colors.blue : Colors.grey[600],
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      item.enabled ? '$realPriority' : '-',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Checkbox(
                  value: item.enabled,
                  onChanged: (v) => setState(() => item.enabled = v ?? false),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.source.displayName,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: item.enabled ? Colors.white : Colors.grey[400],
                        ),
                      ),
                      Text(
                        item.source.description,
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  tooltip: '上移',
                  onPressed: i > 0 ? () => _moveUp(i) : null,
                  color: Colors.blue[300],
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_downward, size: 18),
                  tooltip: '下移',
                  onPressed: i < _items.length - 1 ? () => _moveDown(i) : null,
                  color: Colors.blue[300],
                ),
              ],
            ),
          ),
        ),
      );
    }
    return list;
  }
}
