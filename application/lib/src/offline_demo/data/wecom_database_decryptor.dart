import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';

enum WxSQLite3DecryptIssueCode {
  inputMissing,
  overlappingPaths,
  outputAlreadyExists,
  invalidKeyFormat,
  invalidEncryptedInput,
  keyValidationFailed,
  ioFailure,
}

class WxSQLite3DecryptException implements Exception {
  const WxSQLite3DecryptException(
    this.code,
    this.message, {
    this.cause,
  });

  final WxSQLite3DecryptIssueCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'WxSQLite3DecryptException.${code.name}: $message';
}

class WxSQLite3DatabaseDecryptor {
  static const pageSize = 4096;
  static const _blockSize = 16;
  static const _sqliteHeader = <int>[
    0x53,
    0x51,
    0x4c,
    0x69,
    0x74,
    0x65,
    0x20,
    0x66,
    0x6f,
    0x72,
    0x6d,
    0x61,
    0x74,
    0x20,
    0x33,
    0x00,
  ];
  static const _keySalt = <int>[0x73, 0x41, 0x6c, 0x54];

  Future<String> readSaltHex(File input) async {
    if (!await input.exists()) {
      throw const WxSQLite3DecryptException(
        WxSQLite3DecryptIssueCode.inputMissing,
        'Encrypted database does not exist',
      );
    }
    try {
      final bytes = await input.openRead(0, _blockSize).fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      if (bytes.length != _blockSize) {
        throw const WxSQLite3DecryptException(
          WxSQLite3DecryptIssueCode.invalidEncryptedInput,
          'Encrypted database is shorter than its salt header',
        );
      }
      return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    } on WxSQLite3DecryptException {
      rethrow;
    } catch (error) {
      throw WxSQLite3DecryptException(
        WxSQLite3DecryptIssueCode.ioFailure,
        'Could not read the encrypted database salt',
        cause: error,
      );
    }
  }

  Future<void> decrypt({
    required File input,
    required File output,
    required String rawKeyHex,
  }) async {
    final inputPath = p.normalize(p.absolute(input.path));
    final outputPath = p.normalize(p.absolute(output.path));
    if (p.equals(inputPath, outputPath)) {
      throw const WxSQLite3DecryptException(
        WxSQLite3DecryptIssueCode.overlappingPaths,
        'Input and output files must be different',
      );
    }
    if (!await input.exists()) {
      throw const WxSQLite3DecryptException(
        WxSQLite3DecryptIssueCode.inputMissing,
        'Encrypted database does not exist',
      );
    }
    if (await output.exists()) {
      throw const WxSQLite3DecryptException(
        WxSQLite3DecryptIssueCode.outputAlreadyExists,
        'Decrypted output already exists',
      );
    }

    final rawKey = _parseRawKey(rawKeyHex);
    final temporary = File(_temporaryPath(outputPath));
    RandomAccessFile? inputHandle;
    RandomAccessFile? outputHandle;
    var committed = false;

    try {
      final length = await input.length();
      if (length < pageSize || length % pageSize != 0) {
        throw const WxSQLite3DecryptException(
          WxSQLite3DecryptIssueCode.invalidEncryptedInput,
          'Encrypted database must contain complete 4096-byte pages',
        );
      }

      inputHandle = await input.open(mode: FileMode.read);
      outputHandle = await temporary.open(mode: FileMode.write);
      final pageCount = length ~/ pageSize;
      for (var index = 0; index < pageCount; index++) {
        final encryptedPage = await inputHandle.read(pageSize);
        if (encryptedPage.length != pageSize) {
          throw const WxSQLite3DecryptException(
            WxSQLite3DecryptIssueCode.invalidEncryptedInput,
            'Encrypted database ended before a complete page was read',
          );
        }
        final decryptedPage = _decryptPage(
          encryptedPage,
          index + 1,
          rawKey,
        );
        await outputHandle.writeFrom(decryptedPage);
      }

      await outputHandle.flush();
      await outputHandle.close();
      outputHandle = null;
      await inputHandle.close();
      inputHandle = null;
      await temporary.rename(outputPath);
      committed = true;
    } on WxSQLite3DecryptException {
      rethrow;
    } catch (error) {
      throw WxSQLite3DecryptException(
        WxSQLite3DecryptIssueCode.ioFailure,
        'Could not decrypt the database',
        cause: error,
      );
    } finally {
      rawKey.fillRange(0, rawKey.length, 0);
      try {
        await outputHandle?.close();
      } finally {
        try {
          await inputHandle?.close();
        } finally {
          if (!committed && await temporary.exists()) {
            await temporary.delete();
          }
        }
      }
    }
  }

  Uint8List _decryptPage(
    Uint8List encryptedPage,
    int pageNumber,
    Uint8List rawKey,
  ) {
    final pageKey = _derivePageKey(rawKey, pageNumber);
    final iv = _derivePageIv(pageNumber);
    try {
      if (pageNumber == 1) {
        final expectedHeaderFragment = encryptedPage.sublist(16, 24);
        encryptedPage.setRange(16, 24, encryptedPage.sublist(8, 16));
        final decrypted = _decryptBlocks(
          encryptedPage,
          offset: 16,
          key: pageKey,
          iv: iv,
        );
        for (var index = 0; index < expectedHeaderFragment.length; index++) {
          if (decrypted[16 + index] != expectedHeaderFragment[index]) {
            throw const WxSQLite3DecryptException(
              WxSQLite3DecryptIssueCode.keyValidationFailed,
              'The raw key did not validate the first database page',
            );
          }
        }
        decrypted.setRange(0, _sqliteHeader.length, _sqliteHeader);
        return decrypted;
      }
      return _decryptBlocks(
        encryptedPage,
        offset: 0,
        key: pageKey,
        iv: iv,
      );
    } finally {
      pageKey.fillRange(0, pageKey.length, 0);
      iv.fillRange(0, iv.length, 0);
    }
  }

  Uint8List _decryptBlocks(
    Uint8List input, {
    required int offset,
    required Uint8List key,
    required Uint8List iv,
  }) {
    final output = Uint8List(input.length);
    if (offset > 0) {
      output.setRange(0, offset, input);
    }
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));
    for (var blockOffset = offset;
        blockOffset < input.length;
        blockOffset += cipher.blockSize) {
      cipher.processBlock(input, blockOffset, output, blockOffset);
    }
    return output;
  }

  Uint8List _derivePageKey(Uint8List rawKey, int pageNumber) {
    final material = Uint8List(rawKey.length + 8)..setAll(0, rawKey);
    try {
      final data = ByteData.view(material.buffer);
      data.setUint32(rawKey.length, pageNumber, Endian.little);
      material.setAll(rawKey.length + 4, _keySalt);
      return Uint8List.fromList(md5.convert(material).bytes);
    } finally {
      material.fillRange(0, material.length, 0);
    }
  }

  Uint8List _derivePageIv(int pageNumber) {
    var state = pageNumber + 1;
    final seed = Uint8List(_blockSize);
    final data = ByteData.view(seed.buffer);
    for (var offset = 0; offset < seed.length; offset += 4) {
      final quotient = state ~/ 52774;
      state = 40692 * (state - 52774 * quotient) - 3791 * quotient;
      if (state < 0) {
        state += 2147483399;
      }
      data.setUint32(offset, state, Endian.little);
    }
    try {
      return Uint8List.fromList(md5.convert(seed).bytes);
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  Uint8List _parseRawKey(String rawKeyHex) {
    if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(rawKeyHex)) {
      throw const WxSQLite3DecryptException(
        WxSQLite3DecryptIssueCode.invalidKeyFormat,
        'Raw key must be exactly 32 hexadecimal characters',
      );
    }
    return Uint8List.fromList([
      for (var offset = 0; offset < rawKeyHex.length; offset += 2)
        int.parse(rawKeyHex.substring(offset, offset + 2), radix: 16),
    ]);
  }

  String _temporaryPath(String outputPath) {
    final random = Random.secure().nextInt(1 << 32);
    final suffix = DateTime.now().toUtc().microsecondsSinceEpoch;
    return p.join(
      p.dirname(outputPath),
      '.${p.basename(outputPath)}.decrypt-$suffix-$random.partial',
    );
  }
}
