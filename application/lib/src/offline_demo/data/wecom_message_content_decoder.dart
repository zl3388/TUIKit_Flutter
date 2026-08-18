import 'dart:convert';
import 'dart:typed_data';

import 'wecom_protobuf_reader.dart';

class WeComDecodedMessageContent {
  const WeComDecodedMessageContent({required this.kind, required this.text});

  final String kind;
  final String text;
}

WeComDecodedMessageContent decodeWeComMessageContent(
  int contentType,
  Uint8List? content,
) {
  if (content == null) {
    return _placeholder(contentType);
  }
  return switch (contentType) {
    2 => _decoded('text', _textOrPlaceholder(decodeWeComTextMessage(content))),
    4 => _decodeRichImage(content),
    6 => _decodeLocation(content),
    7 => _decodeSimpleImage(content),
    14 => _decodeEmoji(content),
    15 => _decodeFile(content),
    16 => _decodeVoice(content),
    20 => _decodeFile(content),
    22 || 23 => _decodeVideo(content),
    40 => _decodeCall(content),
    123 => _decodeMixed(content),
    1001 || 1002 || 1011 => _decodeRawText(content),
    _ => const WeComDecodedMessageContent(
        kind: 'unsupported',
        text: '[非文本消息]',
      ),
  };
}

String decodeWeComTextMessage(Uint8List content) {
  final buffer = StringBuffer();
  for (final field in readWeComProtoFields(content)) {
    if (field.number != 1 || field.bytes == null) {
      continue;
    }
    final item = readWeComProtoFields(field.bytes!);
    final itemType = firstWeComProtoVarint(item, 1);
    if (itemType != 0 && itemType != 3) {
      continue;
    }
    final payload = firstWeComProtoBytes(item, 2);
    if (payload != null) {
      buffer.write(decodeWeComNestedText(payload));
    }
  }
  return buffer.toString();
}

WeComDecodedMessageContent _decodeRichImage(Uint8List content) {
  final fields = readWeComProtoFields(content);
  final imageCount = fields.where((field) => field.number == 1).length;
  return _labeled(
    'image',
    '图片',
    [
      if (imageCount > 1) '$imageCount 张',
      _string(fields, 2),
    ],
  );
}

WeComDecodedMessageContent _decodeLocation(Uint8List content) {
  final fields = readWeComProtoFields(content);
  final address = _string(fields, 3);
  return _labeled(
    'location',
    '位置',
    [address.isNotEmpty ? address : _string(fields, 4)],
  );
}

WeComDecodedMessageContent _decodeSimpleImage(Uint8List content) {
  final fields = readWeComProtoFields(content);
  return _labeled(
    'image',
    '图片',
    [
      _string(fields, 2),
      _dimensions(fields, 5, 6),
      _fileSize(firstWeComProtoVarint(fields, 4)),
    ],
  );
}

WeComDecodedMessageContent _decodeEmoji(Uint8List content) {
  final fields = readWeComProtoFields(content);
  return _labeled('emoji', '表情', [_dimensions(fields, 5, 6)]);
}

WeComDecodedMessageContent _decodeFile(Uint8List content) {
  final fields = readWeComProtoFields(content);
  return _labeled(
    'file',
    '文件',
    [_string(fields, 2), _fileSize(firstWeComProtoVarint(fields, 4))],
  );
}

WeComDecodedMessageContent _decodeVoice(Uint8List content) {
  final fields = readWeComProtoFields(content);
  return _labeled(
    'voice',
    '语音',
    [_duration(firstWeComProtoVarint(fields, 7))],
  );
}

WeComDecodedMessageContent _decodeVideo(Uint8List content) {
  final fields = readWeComProtoFields(content);
  return _labeled(
    'video',
    '视频',
    [
      _duration(firstWeComProtoVarint(fields, 4)),
      _dimensions(fields, 5, 6),
      _fileSize(firstWeComProtoVarint(fields, 3)),
    ],
  );
}

WeComDecodedMessageContent _decodeCall(Uint8List content) {
  final fields = readWeComProtoFields(content);
  return _labeled(
    'call',
    '通话',
    [_string(fields, 3), _duration(firstWeComProtoVarint(fields, 20))],
  );
}

WeComDecodedMessageContent _decodeMixed(Uint8List content) {
  final details = <String>[];
  final fields = readWeComProtoFields(content);
  for (final field in fields) {
    if (field.number != 1 || field.bytes == null) {
      continue;
    }
    final item = readWeComProtoFields(field.bytes!);
    switch (firstWeComProtoVarint(item, 5)) {
      case 2:
        final caption = firstWeComProtoBytes(item, 101);
        if (caption != null) {
          details.add(decodeWeComTextMessage(caption));
        }
      case 14:
        final attachment = firstWeComProtoBytes(item, 103);
        if (attachment != null) {
          final attachmentFields = readWeComProtoFields(attachment);
          details.add(_string(attachmentFields, 2));
        }
    }
  }
  return _labeled('mixed', '图文消息', details);
}

WeComDecodedMessageContent _decodeRawText(Uint8List content) {
  return _decoded('text', _textOrPlaceholder(utf8.decode(content)));
}

WeComDecodedMessageContent _placeholder(int contentType) {
  return switch (contentType) {
    2 || 1001 || 1002 || 1011 => _decoded('text', '[文本消息]'),
    4 || 7 => _decoded('image', '[图片]'),
    6 => _decoded('location', '[位置]'),
    14 => _decoded('emoji', '[表情]'),
    15 || 20 => _decoded('file', '[文件]'),
    16 => _decoded('voice', '[语音]'),
    22 || 23 => _decoded('video', '[视频]'),
    40 => _decoded('call', '[通话]'),
    123 => _decoded('mixed', '[图文消息]'),
    _ => _decoded('unsupported', '[非文本消息]'),
  };
}

WeComDecodedMessageContent _labeled(
  String kind,
  String label,
  Iterable<String> values,
) {
  final details = values.where((value) => value.trim().isNotEmpty).toList();
  return _decoded(
    kind,
    details.isEmpty ? '[$label]' : '[$label] ${details.join(' · ')}',
  );
}

WeComDecodedMessageContent _decoded(String kind, String text) {
  return WeComDecodedMessageContent(kind: kind, text: text);
}

String _textOrPlaceholder(String text) => text.isEmpty ? '[文本消息]' : text;

String _string(List<WeComProtoField> fields, int number) {
  final bytes = firstWeComProtoBytes(fields, number);
  return bytes == null ? '' : utf8.decode(bytes).trim();
}

String _dimensions(
  List<WeComProtoField> fields,
  int widthField,
  int heightField,
) {
  final width = firstWeComProtoVarint(fields, widthField) ?? 0;
  final height = firstWeComProtoVarint(fields, heightField) ?? 0;
  return width > 0 && height > 0 ? '$width×$height' : '';
}

String _duration(int? seconds) =>
    seconds != null && seconds > 0 ? '$seconds 秒' : '';

String _fileSize(int? bytes) {
  if (bytes == null || bytes <= 0) {
    return '';
  }
  const unit = 1024;
  if (bytes >= unit * unit * unit) {
    return '${(bytes / (unit * unit * unit)).toStringAsFixed(1)} GB';
  }
  if (bytes >= unit * unit) {
    return '${(bytes / (unit * unit)).toStringAsFixed(1)} MB';
  }
  if (bytes >= unit) {
    return '${(bytes / unit).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}
