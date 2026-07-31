import 'package:flutter/material.dart';

class OfflineAvatar extends StatelessWidget {
  const OfflineAvatar({
    required this.id,
    required this.label,
    required this.size,
    this.icon,
    super.key,
  });

  final String id;
  final String label;
  final double size;
  final IconData? icon;

  static const _colors = <Color>[
    Color(0xFF0F766E),
    Color(0xFF2563EB),
    Color(0xFFB45309),
    Color(0xFFBE123C),
    Color(0xFF7C3AED),
  ];

  @override
  Widget build(BuildContext context) {
    final sum = id.codeUnits.fold<int>(0, (total, value) => total + value);
    final color = _colors[sum % _colors.length];
    final trimmedLabel = label.trim();
    final initial = trimmedLabel.isEmpty ? '?' : trimmedLabel.characters.first;
    return Semantics(
      label: '$label 的头像',
      child: CircleAvatar(
        radius: size / 2,
        backgroundColor: color,
        foregroundColor: Colors.white,
        child: icon == null
            ? Text(
                initial,
                style: TextStyle(
                  fontSize: size * 0.38,
                  fontWeight: FontWeight.w700,
                ),
              )
            : Icon(icon, size: size * 0.52),
      ),
    );
  }
}

class OfflineInfoTile extends StatelessWidget {
  const OfflineInfoTile({
    required this.icon,
    required this.label,
    required this.value,
    this.allowWrap = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool allowWrap;

  @override
  Widget build(BuildContext context) {
    final valueText = Text(
      value,
      textAlign: TextAlign.end,
      maxLines: allowWrap ? 3 : 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: Color(0xFF52616B)),
    );
    return Material(
      color: Colors.white,
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        trailing: allowWrap
            ? SizedBox(
                width: MediaQuery.sizeOf(context).width.clamp(160, 420) * 0.55,
                child: valueText,
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: valueText,
              ),
      ),
    );
  }
}

String twoDigits(int value) => value.toString().padLeft(2, '0');

String formatTime(DateTime value) {
  final local = value.toLocal();
  return '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}

String formatDate(DateTime value) {
  final local = value.toLocal();
  return '${twoDigits(local.month)}-${twoDigits(local.day)}';
}

String formatDateTime(DateTime value) =>
    '${formatDate(value)} ${formatTime(value)}';

String formatDuration(int seconds) {
  final minutes = seconds ~/ 60;
  final remainingSeconds = seconds % 60;
  return '$minutes:${twoDigits(remainingSeconds)}';
}
