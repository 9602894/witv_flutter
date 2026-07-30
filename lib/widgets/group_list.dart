import 'package:flutter/material.dart';

class GroupList extends StatelessWidget {
  final List<String> groups;
  final String? selectedGroup;
  final ValueChanged<String> onSelect;

  const GroupList({
    Key? key,
    required this.groups,
    this.selectedGroup,
    required this.onSelect,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        final isSelected = group == selectedGroup;
        return ListTile(
          selected: isSelected,
          selectedTileColor: Colors.blue.withOpacity(0.3),
          title: Text(group),
          onTap: () => onSelect(group),
        );
      },
    );
  }
}
