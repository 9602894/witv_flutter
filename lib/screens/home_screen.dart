import 'package:flutter/material.dart';
import '../services/log_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _logMessage = '等待点击...';

  @override
  void initState() {
    super.initState();
    // 写入日志
    LogService.write('HomeScreen 初始化');
  }

  Future<void> _testLog() async {
    await LogService.write('用户点击了测试按钮');
    setState(() {
      _logMessage = '日志已写入，请检查文件';
    });
    // 也显示一个弹窗
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('日志测试'),
        content: const Text('日志已写入，请查看文件：\n/storage/emulated/0/Android/data/com.whyun.witv/files/witv_log.txt'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Witv 测试模式')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('日志路径：/storage/emulated/0/Android/data/com.whyun.witv/files/witv_log.txt'),
            const SizedBox(height: 20),
            Text(_logMessage, style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 30),
            ElevatedButton(
              onPressed: _testLog,
              child: const Text('写入测试日志'),
            ),
          ],
        ),
      ),
    );
  }
}
