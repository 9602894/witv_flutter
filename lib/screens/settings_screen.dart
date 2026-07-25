// 在 SettingsScreen 中添加
Future<void> _exportLog() async {
  try {
    final file = await LogService.export();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('日志已导出到: ${file.path}')),
    );
    await LogService.write('日志导出成功');
  } catch (e, stack) {
    await LogService.writeCrashLog(e, stack);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('导出失败: $e')),
    );
  }
}

// 在 AppBar 的 actions 中添加
actions: [
  IconButton(icon: Icon(Icons.save), onPressed: _saveConfig),
  IconButton(icon: Icon(Icons.backup), onPressed: _backup),
  IconButton(icon: Icon(Icons.restore), onPressed: _restore),
  IconButton(icon: Icon(Icons.file_download), onPressed: _exportLog), // 新增
],
