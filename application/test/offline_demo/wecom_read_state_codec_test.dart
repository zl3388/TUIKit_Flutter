import 'dart:typed_data';

import 'package:application/src/offline_demo/data/wecom_read_state_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes the portable field 1 and field 2 vectors', () {
    final direct = decodeWeComReadState(
      _bytes('08ba99d9c38e808003'),
    );
    final group = decodeWeComReadState(
      _bytes('08baa3dac38e80800308f2dad9c38e808003'),
    );
    final serverAcknowledged = decodeWeComReadState(
      _bytes('10f2dad9c38e808003'),
    );

    expect(direct.readerIds, [1688853760330938]);
    expect(direct.field2Ids, isEmpty);
    expect(group.readerIds, [1688853760348602, 1688853760339314]);
    expect(serverAcknowledged.readerIds, isEmpty);
    expect(serverAcknowledged.field2Ids, [1688853760339314]);
  });

  test('accepts empty bytes and rejects the old zero placeholder', () {
    final empty = decodeWeComReadState(Uint8List(0));

    expect(empty.readerIds, isEmpty);
    expect(empty.field2Ids, isEmpty);
    expect(
      () => decodeWeComReadState(Uint8List.fromList([0])),
      throwsFormatException,
    );
  });

  test('rejects unknown fields, wrong wire types, and truncated varints', () {
    expect(
      () => decodeWeComReadState(Uint8List.fromList([0x18, 0x01])),
      throwsFormatException,
    );
    expect(
      () => decodeWeComReadState(Uint8List.fromList([0x0a, 0x00])),
      throwsFormatException,
    );
    expect(
      () => decodeWeComReadState(Uint8List.fromList([0x08, 0x80])),
      throwsFormatException,
    );
  });
}

Uint8List _bytes(String hex) => Uint8List.fromList([
      for (var index = 0; index < hex.length; index += 2)
        int.parse(hex.substring(index, index + 2), radix: 16),
    ]);
