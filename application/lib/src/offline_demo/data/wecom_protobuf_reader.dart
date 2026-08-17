import 'dart:convert';
import 'dart:typed_data';

class WeComProtoField {
  const WeComProtoField({required this.number, this.varint, this.bytes});

  final int number;
  final int? varint;
  final Uint8List? bytes;
}

List<WeComProtoField> readWeComProtoFields(Uint8List bytes) {
  final fields = <WeComProtoField>[];
  var offset = 0;
  while (offset < bytes.length) {
    if (bytes[offset] == 0) {
      if (bytes.sublist(offset).any((byte) => byte != 0)) {
        throw const FormatException('Invalid protobuf zero tag');
      }
      break;
    }
    final tag = _readVarint(bytes, offset);
    offset = tag.nextOffset;
    final number = tag.value >> 3;
    final wireType = tag.value & 7;
    if (number < 1) {
      throw const FormatException('Invalid protobuf field number');
    }
    switch (wireType) {
      case 0:
        final value = _readVarint(bytes, offset);
        offset = value.nextOffset;
        fields.add(WeComProtoField(number: number, varint: value.value));
      case 1:
        offset = _skipFixed(bytes, offset, 8);
        fields.add(WeComProtoField(number: number));
      case 2:
        final length = _readVarint(bytes, offset);
        offset = length.nextOffset;
        final end = offset + length.value;
        if (length.value < 0 || end > bytes.length) {
          throw const FormatException('Protobuf length exceeds buffer');
        }
        fields.add(
          WeComProtoField(
            number: number,
            bytes: Uint8List.sublistView(bytes, offset, end),
          ),
        );
        offset = end;
      case 5:
        offset = _skipFixed(bytes, offset, 4);
        fields.add(WeComProtoField(number: number));
      default:
        throw FormatException('Unsupported protobuf wire type $wireType');
    }
  }
  return fields;
}

int? firstWeComProtoVarint(List<WeComProtoField> fields, int number) {
  for (final field in fields) {
    if (field.number == number && field.varint != null) {
      return field.varint;
    }
  }
  return null;
}

Uint8List? firstWeComProtoBytes(List<WeComProtoField> fields, int number) {
  for (final field in fields) {
    if (field.number == number && field.bytes != null) {
      return field.bytes;
    }
  }
  return null;
}

String decodeWeComNestedText(Uint8List bytes, [int depth = 0]) {
  if (depth < 4) {
    try {
      final fields = readWeComProtoFields(bytes);
      if (fields.length == 1 &&
          fields.single.number == 1 &&
          fields.single.bytes != null) {
        return decodeWeComNestedText(fields.single.bytes!, depth + 1);
      }
    } on FormatException {
      // The terminal UTF-8 payload is not itself a protobuf message.
    }
  }
  var end = bytes.length;
  while (end > 0 && bytes[end - 1] == 0) {
    end--;
  }
  return utf8.decode(bytes.sublist(0, end));
}

_Varint _readVarint(Uint8List bytes, int offset) {
  var value = 0;
  var shift = 0;
  while (offset < bytes.length && shift <= 63) {
    final byte = bytes[offset++];
    value |= (byte & 0x7f) << shift;
    if (byte & 0x80 == 0) {
      return _Varint(value, offset);
    }
    shift += 7;
  }
  throw const FormatException('Invalid protobuf varint');
}

int _skipFixed(Uint8List bytes, int offset, int length) {
  final end = offset + length;
  if (end > bytes.length) {
    throw const FormatException('Protobuf fixed field exceeds buffer');
  }
  return end;
}

class _Varint {
  const _Varint(this.value, this.nextOffset);

  final int value;
  final int nextOffset;
}
