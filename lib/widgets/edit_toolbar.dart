import 'package:flutter/material.dart';

class EditToolbar extends StatelessWidget {
  final bool isEditMode;
  final VoidCallback onExit;
  final double subWeight;
  final ValueChanged<double> onSubWeightChange;
  final double groupWeight;
  final ValueChanged<double> onGroupWeightChange;

  const EditToolbar({
    Key? key,
    required this.isEditMode,
    required this.onExit,
    required this.subWeight,
    required this.onSubWeightChange,
    required this.groupWeight,
    required this.onGroupWeightChange,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (!isEditMode) return SizedBox.shrink();
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: Colors.black.withOpacity(0.7),
        padding: EdgeInsets.all(8),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('订阅宽度:', style: TextStyle(color: Colors.white)),
                Slider(
                  value: subWeight,
                  min: 0.05,
                  max: 0.8,
                  onChanged: onSubWeightChange,
                ),
                Text('${(subWeight * 100).toInt()}%', style: TextStyle(color: Colors.white)),
                SizedBox(width: 20),
                Text('分组宽度:', style: TextStyle(color: Colors.white)),
                Slider(
                  value: groupWeight,
                  min: 0.05,
                  max: 0.8,
                  onChanged: onGroupWeightChange,
                ),
                Text('${(groupWeight * 100).toInt()}%', style: TextStyle(color: Colors.white)),
              ],
            ),
            ElevatedButton(onPressed: onExit, child: Text('退出编辑模式')),
          ],
        ),
      ),
    );
  }
}
