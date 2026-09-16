import 'dart:convert';
import 'dart:typed_data';

import 'wecom_protobuf_reader.dart';

class WeComSystemCardContent {
  const WeComSystemCardContent({
    required this.cardType,
    required this.title,
    required this.buttonText,
  });

  final int? cardType;
  final String title;
  final String buttonText;
}

class WeComCallContent {
  const WeComCallContent({
    required this.mediaCode,
    required this.callType,
    required this.statusText,
    required this.durationSeconds,
    required this.userIds,
  });

  final int? mediaCode;
  final int? callType;
  final String statusText;
  final int durationSeconds;
  final List<int> userIds;
}

class WeComStatusNoticeContent {
  const WeComStatusNoticeContent({
    required this.title,
    required this.peerUserId,
    required this.sendTime,
    required this.isMissedVoice,
  });

  final String title;
  final int? peerUserId;
  final int? sendTime;
  final bool isMissedVoice;
}

class WeComGroupCallNoticeContent {
  const WeComGroupCallNoticeContent({
    required this.kind,
    required this.title,
    required this.isMissed,
    required this.durationSeconds,
  });

  final int? kind;
  final String title;
  final bool isMissed;
  final int durationSeconds;
}

class WeComMeetingCardContent {
  const WeComMeetingCardContent({
    required this.title,
    required this.organizerId,
  });

  final String title;
  final int? organizerId;
}

class WeComQuoteReference {
  const WeComQuoteReference({
    required this.parentSendTime,
    required this.parentAppInfo,
  });

  final int parentSendTime;
  final String parentAppInfo;
}

class WeComRevokeContent {
  const WeComRevokeContent({required this.snippet});

  final String? snippet;
}

WeComSystemCardContent decodeWeComSystemCard(Uint8List content) {
  final fields = _readAdvancedFields(content);
  final cardBytes = firstWeComProtoBytes(fields, 1);
  final card = cardBytes == null
      ? const <WeComProtoField>[]
      : readWeComProtoFields(cardBytes);
  return WeComSystemCardContent(
    cardType: firstWeComProtoVarint(fields, 2),
    title: _string(card, 1),
    buttonText: _string(card, 4),
  );
}

WeComCallContent decodeWeComCall(Uint8List content) {
  final fields = _readAdvancedFields(content);
  final statusText = _string(fields, 3);
  return WeComCallContent(
    mediaCode: firstWeComProtoVarint(fields, 1),
    callType: firstWeComProtoVarint(fields, 2),
    statusText: statusText,
    durationSeconds:
        firstWeComProtoVarint(fields, 20) ?? _durationFromStatus(statusText),
    userIds: fields
        .where((field) => field.number == 21 && field.varint != null)
        .map((field) => field.varint!)
        .toList(growable: false),
  );
}

WeComStatusNoticeContent decodeWeComStatusNotice(Uint8List content) {
  final fields = _readAdvancedFields(content);
  final cardBytes = firstWeComProtoBytes(fields, 2);
  if (cardBytes != null) {
    final card = readWeComProtoFields(cardBytes);
    final title = _string(card, 1);
    return WeComStatusNoticeContent(
      title: title,
      peerUserId:
          firstWeComProtoVarint(card, 4) ?? firstWeComProtoVarint(card, 7),
      sendTime:
          firstWeComProtoVarint(fields, 3) ?? firstWeComProtoVarint(card, 5),
      isMissedVoice: title.contains('未接语音通话'),
    );
  }
  final missBytes = firstWeComProtoBytes(fields, 6);
  final miss = missBytes == null
      ? const <WeComProtoField>[]
      : readWeComProtoFields(missBytes);
  final title = _string(miss, 1);
  return WeComStatusNoticeContent(
    title: title,
    peerUserId: firstWeComProtoVarint(miss, 3),
    sendTime: firstWeComProtoVarint(fields, 3),
    isMissedVoice: title.contains('未接语音通话'),
  );
}

WeComGroupCallNoticeContent decodeWeComGroupCallNotice(Uint8List content) {
  final fields = _readAdvancedFields(content);
  final kind = firstWeComProtoVarint(fields, 2);
  final title = _string(fields, 3);
  return WeComGroupCallNoticeContent(
    kind: kind,
    title: title,
    isMissed: kind == 3 || title.contains('未接听'),
    durationSeconds: _durationFromStatus(title),
  );
}

WeComMeetingCardContent decodeWeComMeetingCard(Uint8List content) {
  if (content.isEmpty) {
    return const WeComMeetingCardContent(title: '', organizerId: null);
  }
  final fields = _readAdvancedFields(content);
  final innerBytes = firstWeComProtoBytes(fields, 1);
  final inner = innerBytes == null
      ? const <WeComProtoField>[]
      : readWeComProtoFields(innerBytes);
  return WeComMeetingCardContent(
    title: _string(inner, 4),
    organizerId: firstWeComProtoVarint(inner, 5),
  );
}

WeComQuoteReference? decodeWeComQuoteReference(Uint8List? content) {
  if (content == null || content.isEmpty) {
    return null;
  }
  final fields = readWeComProtoFields(content);
  final quoteBytes = firstWeComProtoBytes(fields, 1002);
  if (quoteBytes == null) {
    return null;
  }
  final quote = readWeComProtoFields(quoteBytes);
  final cardBytes = firstWeComProtoBytes(quote, 1);
  if (cardBytes == null) {
    return null;
  }
  final card = readWeComProtoFields(cardBytes);
  final sendTime = firstWeComProtoVarint(card, 2);
  final appInfo = _string(quote, 2);
  if (sendTime == null || sendTime <= 0 || appInfo.isEmpty) {
    return null;
  }
  return WeComQuoteReference(
    parentSendTime: sendTime,
    parentAppInfo: appInfo,
  );
}

WeComRevokeContent decodeWeComRevokeContent(Uint8List? content) {
  if (content == null || content.isEmpty) {
    return const WeComRevokeContent(snippet: null);
  }
  final fields = readWeComProtoFields(content);
  final snippetBytes = firstWeComProtoBytes(fields, 8);
  if (snippetBytes == null) {
    return const WeComRevokeContent(snippet: null);
  }
  final direct = _printableUtf8(snippetBytes);
  if (direct != null) {
    return WeComRevokeContent(snippet: direct);
  }
  try {
    final level1 = readWeComProtoFields(snippetBytes);
    final level2Bytes = firstWeComProtoBytes(level1, 1);
    if (level2Bytes == null) {
      return const WeComRevokeContent(snippet: null);
    }
    final level2 = readWeComProtoFields(level2Bytes);
    final level3Bytes = firstWeComProtoBytes(level2, 2);
    if (level3Bytes == null) {
      return const WeComRevokeContent(snippet: null);
    }
    final level3 = readWeComProtoFields(level3Bytes);
    return WeComRevokeContent(
      snippet: _printableUtf8(firstWeComProtoBytes(level3, 1)),
    );
  } on FormatException {
    return const WeComRevokeContent(snippet: null);
  }
}

String _string(List<WeComProtoField> fields, int number) {
  return _printableUtf8(firstWeComProtoBytes(fields, number)) ?? '';
}

List<WeComProtoField> _readAdvancedFields(Uint8List content) {
  if (content.length == 1 && content.single == 0) {
    throw const FormatException('0x00 is not an advanced message payload');
  }
  return readWeComProtoFields(content);
}

String? _printableUtf8(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) {
    return null;
  }
  try {
    final value = utf8.decode(bytes);
    if (value.runes.any(
      (character) =>
          character < 32 &&
          character != 9 &&
          character != 10 &&
          character != 13,
    )) {
      return null;
    }
    return value;
  } on FormatException {
    return null;
  }
}

int _durationFromStatus(String text) {
  final match = RegExp(r'时长\s*(\d+):(\d+)').firstMatch(text);
  if (match == null) {
    return 0;
  }
  return int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!);
}
