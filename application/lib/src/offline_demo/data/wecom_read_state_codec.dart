import 'dart:typed_data';

class WeComReadState {
  const WeComReadState({
    required this.readerIds,
    required this.field2Ids,
  });

  final List<int> readerIds;
  final List<int> field2Ids;
}

WeComReadState decodeWeComReadState(Uint8List bytes) {
  final readerIds = <int>[];
  final field2Ids = <int>[];
  var offset = 0;
  while (offset < bytes.length) {
    final tag = _readVarint(bytes, offset);
    offset = tag.nextOffset;
    if (tag.value == 0) {
      throw const FormatException('ReadStatePb contains an invalid zero tag.');
    }
    final fieldNumber = tag.value >> 3;
    final wireType = tag.value & 0x07;
    if ((fieldNumber != 1 && fieldNumber != 2) || wireType != 0) {
      throw FormatException(
        'Unsupported ReadStatePb field $fieldNumber with wire type $wireType.',
      );
    }
    final value = _readVarint(bytes, offset);
    offset = value.nextOffset;
    (fieldNumber == 1 ? readerIds : field2Ids).add(value.value);
  }
  return WeComReadState(
    readerIds: List.unmodifiable(readerIds),
    field2Ids: List.unmodifiable(field2Ids),
  );
}

({int value, int nextOffset}) _readVarint(Uint8List bytes, int offset) {
  var value = 0;
  for (var shift = 0; shift < 70; shift += 7) {
    if (offset >= bytes.length) {
      throw const FormatException('Truncated ReadStatePb varint.');
    }
    final byte = bytes[offset++];
    value |= (byte & 0x7f) << shift;
    if ((byte & 0x80) == 0) {
      return (value: value, nextOffset: offset);
    }
  }
  throw const FormatException('ReadStatePb varint is too long.');
}
