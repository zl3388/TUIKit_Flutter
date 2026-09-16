import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:application/src/offline_demo/data/wecom_message_content_decoder.dart';
import 'package:application/src/offline_demo/data/wecom_message_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'wecom_message_test_fixture.dart';

void main() {
  late Directory temporaryDirectory;
  late Database messageDatabase;
  late Database lookupDatabase;
  late WeComMessageRepository repository;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'tui_wecom_messages_',
    );
    await createMessageDatabases(
      temporaryDirectory,
      conversationNumericId: 7,
      messages: [
        TestWeComMessage(
          messageId: 1,
          serverId: 101,
          sequence: 10,
          senderId: 2,
          conversationId: 'S:1_2',
          sendTime: 10,
          content: _bytes('0A09080012050A03E5868D'),
        ),
        TestWeComMessage(
          messageId: 2,
          serverId: 102,
          sequence: 20,
          senderId: 1,
          conversationId: 'S:1_2',
          sendTime: 20,
          flag: 131074,
          content: _bytes('0A0C080012080A06E5A5BDE79A84'),
          readState: _bytes('08ba99d9c38e808003'),
        ),
        TestWeComMessage(
          messageId: 3,
          serverId: 0,
          sequence: 30,
          senderId: 1,
          conversationId: 'S:1_2',
          sendTime: 30,
          flag: 131074,
          content: _bytes('0A09080012050A03E7AD89'),
          clientId: 'local-client-id',
          inRetryQueue: true,
        ),
        TestWeComMessage(
          messageId: 4,
          serverId: 104,
          sequence: 40,
          senderId: 2,
          conversationId: 'S:1_2',
          sendTime: 40,
          clientId: 'parent-client-id',
          content: _textMessage('父消息'),
        ),
        TestWeComMessage(
          messageId: 5,
          serverId: 105,
          sequence: 50,
          senderId: 1,
          conversationId: 'S:1_2',
          sendTime: 50,
          flag: 512,
          content: _textMessage('回复'),
          extraContent: _message([
            _bytesField(
              1002,
              _message([
                _bytesField(1, _message([_varintField(2, 40)])),
                _stringField(2, 'parent-client-id'),
              ]),
            ),
          ]),
        ),
        TestWeComMessage(
          messageId: 6,
          serverId: 106,
          sequence: 60,
          senderId: 1,
          conversationId: 'S:1_2',
          sendTime: 60,
          flag: 32,
          clientId: 'recalled-client-id',
          content: _textMessage('撤回原文'),
        ),
        TestWeComMessage(
          messageId: 7,
          serverId: 107,
          sequence: 70,
          senderId: 1,
          conversationId: 'S:1_2',
          sendTime: 70,
          flag: 512,
          content: _textMessage('父消息缺失'),
          extraContent: _message([
            _bytesField(
              1002,
              _message([
                _bytesField(1, _message([_varintField(2, 999)])),
                _stringField(2, 'missing-parent'),
              ]),
            ),
          ]),
        ),
        TestWeComMessage(
          messageId: 8,
          serverId: 108,
          sequence: 80,
          senderId: 1,
          conversationId: 'S:1_2',
          sendTime: 80,
          flag: 512,
          content: _textMessage('引用元数据缺失'),
        ),
        TestWeComMessage(
          messageId: 9,
          serverId: 109,
          sequence: 90,
          senderId: 1,
          conversationId: 'S:1_2',
          sendTime: 90,
          contentType: 31,
          flag: 512,
          content: _textMessage('非引用类型'),
        ),
      ],
      revokes: [
        TestWeComRevoke(
          conversationNumericId: 7,
          appInfo: 'recalled-client-id',
          sendTime: 60,
          payload: _message([_stringField(8, '撤回片段')]),
        ),
      ],
    );
    messageDatabase = await databaseFactoryFfi.openDatabase(
      p.join(temporaryDirectory.path, 'message.db'),
      options: OpenDatabaseOptions(singleInstance: false, readOnly: true),
    );
    lookupDatabase = await databaseFactoryFfi.openDatabase(
      p.join(temporaryDirectory.path, 'message_lookup.db'),
      options: OpenDatabaseOptions(singleInstance: false),
    );
    repository = WeComMessageRepository(
      messageDatabase: messageDatabase,
      lookupDatabase: lookupDatabase,
    );
  });

  tearDown(() async {
    await lookupDatabase.close();
    await messageDatabase.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('reads indexed messages in ascending sequence order', () async {
    final messages = await repository.listConversationMessages(7);

    expect(
      messages.map((message) => message.messageId),
      [1, 2, 3, 4, 5, 6, 7, 8, 9],
    );
    expect(messages.map((message) => message.sequence),
        [10, 20, 30, 40, 50, 60, 70, 80, 90]);
    expect(
      decodeWeComTextMessage(messages.first.content!),
      '再',
    );
    expect(
      decodeWeComTextMessage(messages[1].content!),
      '好的',
    );
    expect(messages[1].readStateContent, _bytes('08ba99d9c38e808003'));
    expect(messages[2].serverId, 0);
    expect(messages[2].hasClientTracking, isTrue);
    expect(messages[2].isInRetryQueue, isTrue);
  });

  test('ignores lookup rows whose message row no longer exists', () async {
    await lookupDatabase.insert('message_lookup_table', {
      'message_id': 999,
      'server_id': 999,
      'con_numeric_id': 7,
      'send_time': 30,
      'sequence': 30,
    });

    final messages = await repository.listConversationMessages(7);

    expect(
      messages.map((message) => message.messageId),
      [1, 2, 3, 4, 5, 6, 7, 8, 9],
    );
  });

  test('resolves quote parents and marks recalled rows read-only', () async {
    final messages = await repository.findMessagesById([5, 6, 7, 8, 9]);

    expect(messages[5]!.quotedMessage!.messageId, 4);
    expect(messages[5]!.quotedMessage!.isRecalled, isFalse);
    expect(messages[5]!.hasMissingQuotedMessage, isFalse);
    expect(messages[6]!.isRecalled, isTrue);
    expect(messages[6]!.recalledText, '撤回片段');
    expect(messages[7]!.quotedMessage, isNull);
    expect(messages[7]!.hasMissingQuotedMessage, isTrue);
    expect(messages[8]!.quotedMessage, isNull);
    expect(messages[8]!.hasMissingQuotedMessage, isTrue);
    expect(messages[9]!.quotedMessage, isNull);
    expect(messages[9]!.hasMissingQuotedMessage, isFalse);
  });

  test('decodes all confirmed text and emoji items only', () {
    final content = Uint8List.fromList([
      0x0a,
      0x09,
      0x08,
      0x00,
      0x12,
      0x05,
      0x0a,
      0x03,
      0xe5,
      0x86,
      0x8d,
      0x0a,
      0x0e,
      0x08,
      0x03,
      0x12,
      0x0a,
      0x0a,
      0x08,
      0x5b,
      0xe5,
      0xbe,
      0xae,
      0xe7,
      0xac,
      0x91,
      0x5d,
      0x0a,
      0x05,
      0x08,
      0x05,
      0x12,
      0x01,
      0x78,
    ]);

    expect(decodeWeComTextMessage(content), '再[微笑]');
  });

  test('maps confirmed extended types without exposing sensitive fields', () {
    final cases = <({int type, Uint8List content, String kind, String text})>[
      (
        type: 4,
        content: _message([
          _bytesField(1, const []),
          _bytesField(1, const []),
          _stringField(2, 'Group'),
        ]),
        kind: 'image',
        text: '[图片] 2 张 · Group',
      ),
      (
        type: 6,
        content: _message([
          _doubleField(1, 121.25),
          _doubleField(2, 31.35),
          _stringField(3, 'Test address'),
        ]),
        kind: 'location',
        text: '[位置] Test address',
      ),
      (
        type: 7,
        content: _message([
          _stringField(3, 'https://private.invalid/image'),
          _varintField(4, 2048),
          _varintField(5, 640),
          _varintField(6, 480),
          _stringField(100, r'C:\private\image.png'),
        ]),
        kind: 'image',
        text: '[图片] 640×480 · 2.0 KB',
      ),
      (
        type: 14,
        content: _message([
          _stringField(8, 'private-md5'),
          _varintField(5, 128),
          _varintField(6, 128),
        ]),
        kind: 'emoji',
        text: '[表情] 128×128',
      ),
      (
        type: 15,
        content: _message([
          _stringField(2, 'report.pdf'),
          _varintField(4, 2048),
          _stringField(13, 'private-p2p-key'),
        ]),
        kind: 'file',
        text: '[文件] report.pdf · 2.0 KB',
      ),
      (
        type: 16,
        content: _message([
          _stringField(2, 'voice.silk'),
          _varintField(7, 12),
        ]),
        kind: 'voice',
        text: '[语音] 12 秒',
      ),
      (
        type: 20,
        content: _message([
          _stringField(1, 'private-encrypted-content'),
          _stringField(2, 'archive.zip'),
          _varintField(4, 4096),
        ]),
        kind: 'file',
        text: '[文件] archive.zip · 4.0 KB',
      ),
      for (final type in const [22, 23])
        (
          type: type,
          content: _message([
            _stringField(1, '/private/video.mp4'),
            _varintField(3, 1024 * 1024),
            _varintField(4, 30),
            _varintField(5, 1920),
            _varintField(6, 1080),
            _stringField(7, 'https://private.invalid/video'),
          ]),
          kind: 'video',
          text: '[视频] 30 秒 · 1920×1080 · 1.0 MB',
        ),
      (
        type: 31,
        content: _message([
          _bytesField(
            1,
            _message([
              _stringField(1, '系统卡片'),
              _stringField(4, '阅读全文'),
              _stringField(5, 'https://private.invalid/system'),
            ]),
          ),
          _varintField(2, 2),
        ]),
        kind: 'system',
        text: '[系统消息] 系统卡片 · 阅读全文',
      ),
      (
        type: 40,
        content: _message([
          _stringField(3, '对方已取消'),
          _stringField(5, 'private-call-id'),
          _varintField(20, 33),
        ]),
        kind: 'call',
        text: '[通话] 对方已取消 · 33 秒',
      ),
      (
        type: 503,
        content: _message([
          _bytesField(
            2,
            _message([
              _stringField(1, '来自测试用户的未接语音通话'),
              _varintField(4, 2),
            ]),
          ),
        ]),
        kind: 'call',
        text: '[未接通话] 来自测试用户的未接语音通话',
      ),
      (
        type: 579,
        content: _message([
          _bytesField(
            1,
            _message([
              _stringField(4, '快速会议'),
              _varintField(5, 2),
            ]),
          ),
        ]),
        kind: 'meeting',
        text: '[会议] 快速会议',
      ),
      (
        type: 123,
        content: _message([
          _bytesField(
            1,
            _message([
              _varintField(5, 14),
              _bytesField(103, _message([_stringField(2, 'image.png')])),
            ]),
          ),
          _bytesField(
            1,
            _message([
              _varintField(5, 2),
              _bytesField(101, _textMessage('说明')),
            ]),
          ),
        ]),
        kind: 'mixed',
        text: '[图文消息] image.png · 说明',
      ),
      for (final type in const [1001, 1002, 1011])
        (
          type: type,
          content: Uint8List.fromList(utf8.encode('原始文本')),
          kind: 'text',
          text: '原始文本',
        ),
      (
        type: 1018,
        content: _message([
          _varintField(2, 3),
          _stringField(3, '语音通话未接听'),
        ]),
        kind: 'call',
        text: '[群通话] 语音通话未接听',
      ),
    ];

    for (final item in cases) {
      final decoded = decodeWeComMessageContent(item.type, item.content);
      expect(decoded.kind, item.kind, reason: 'content_type=${item.type}');
      expect(decoded.text, item.text, reason: 'content_type=${item.type}');
      expect(decoded.text, isNot(contains('private-')));
    }
    expect(
      decodeWeComMessageContent(999, Uint8List(0)).text,
      '[非文本消息]',
    );
    expect(
      () => decodeWeComMessageContent(7, Uint8List.fromList([0x1a, 0x02])),
      throwsFormatException,
    );
  });
}

Uint8List _bytes(String hex) {
  return Uint8List.fromList([
    for (var index = 0; index < hex.length; index += 2)
      int.parse(hex.substring(index, index + 2), radix: 16),
  ]);
}

Uint8List _message(List<List<int>> fields) {
  return Uint8List.fromList([for (final field in fields) ...field]);
}

List<int> _varintField(int number, int value) => [
      ..._varint(number << 3),
      ..._varint(value),
    ];

List<int> _bytesField(int number, List<int> value) => [
      ..._varint((number << 3) | 2),
      ..._varint(value.length),
      ...value,
    ];

List<int> _stringField(int number, String value) =>
    _bytesField(number, utf8.encode(value));

List<int> _doubleField(int number, double value) {
  final bytes = ByteData(8)..setFloat64(0, value, Endian.little);
  return [..._varint((number << 3) | 1), ...bytes.buffer.asUint8List()];
}

List<int> _textMessage(String text) => _message([
      _bytesField(
        1,
        _message([
          _varintField(1, 0),
          _bytesField(2, _message([_stringField(1, text)])),
        ]),
      ),
    ]);

List<int> _varint(int value) {
  final bytes = <int>[];
  do {
    var byte = value & 0x7f;
    value >>= 7;
    if (value != 0) {
      byte |= 0x80;
    }
    bytes.add(byte);
  } while (value != 0);
  return bytes;
}
