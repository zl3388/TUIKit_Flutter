import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_database_decryptor.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _publicTestKey = '79fbb424f3035e57c6d4cde3a6981de3';
const _encryptedSha256 =
    'd8b26b9ed9987f39c8cfd200ce8c7a20802a37fa852173c02e427606c945c72a';
const _decryptedSha256 =
    '4abc4f053409a193c109576999f3deca4a213806aac6f82cecd9f72de36c4ca4';
const _salt = '86dbbb39ecd0da3e6e11df85f7a3da47';

void main() {
  late Directory temporaryDirectory;
  late File encryptedInput;
  late File decryptedOutput;
  late WxSQLite3DatabaseDecryptor decryptor;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_wecom_decrypt_');
    encryptedInput = File(
      p.join('test', 'fixtures', 'offline_demo', 'encrypted_journal.db'),
    );
    decryptedOutput = File(
      p.join(temporaryDirectory.path, 'decrypted_journal.db'),
    );
    decryptor = WxSQLite3DatabaseDecryptor();
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('decrypts the approved wxSQLite3 vector without changing its source',
      () async {
    expect(await _hash(encryptedInput), _encryptedSha256);
    expect(await decryptor.readSaltHex(encryptedInput), _salt);

    await decryptor.decrypt(
      input: encryptedInput,
      output: decryptedOutput,
      rawKeyHex: _publicTestKey,
    );

    expect(await _hash(encryptedInput), _encryptedSha256);
    expect(await _hash(decryptedOutput), _decryptedSha256);
    final database = await databaseFactoryFfi.openDatabase(
      decryptedOutput.path,
      options: OpenDatabaseOptions(
        readOnly: true,
        singleInstance: false,
      ),
    );
    addTearDown(database.close);
    expect(await database.rawQuery('PRAGMA integrity_check'), [
      {'integrity_check': 'ok'}
    ]);
  });

  test('wrong key leaves no decrypted or partial file', () async {
    await expectLater(
      decryptor.decrypt(
        input: encryptedInput,
        output: decryptedOutput,
        rawKeyHex: '79fbb424f3035e57c6d4cde3a6981de2',
      ),
      throwsA(
        isA<WxSQLite3DecryptException>().having(
          (error) => error.code,
          'code',
          WxSQLite3DecryptIssueCode.keyValidationFailed,
        ),
      ),
    );

    expect(await decryptedOutput.exists(), isFalse);
    expect(await _partialFiles(temporaryDirectory), isEmpty);
  });

  test('invalid key format fails before creating output', () async {
    await expectLater(
      decryptor.decrypt(
        input: encryptedInput,
        output: decryptedOutput,
        rawKeyHex: 'not-a-key',
      ),
      throwsA(
        isA<WxSQLite3DecryptException>().having(
          (error) => error.code,
          'code',
          WxSQLite3DecryptIssueCode.invalidKeyFormat,
        ),
      ),
    );

    expect(await decryptedOutput.exists(), isFalse);
    expect(await _partialFiles(temporaryDirectory), isEmpty);
  });

  test('refuses to overwrite an existing output', () async {
    await decryptedOutput.writeAsString('keep', flush: true);

    await expectLater(
      decryptor.decrypt(
        input: encryptedInput,
        output: decryptedOutput,
        rawKeyHex: _publicTestKey,
      ),
      throwsA(
        isA<WxSQLite3DecryptException>().having(
          (error) => error.code,
          'code',
          WxSQLite3DecryptIssueCode.outputAlreadyExists,
        ),
      ),
    );

    expect(await decryptedOutput.readAsString(), 'keep');
    expect(await _partialFiles(temporaryDirectory), isEmpty);
  });

  test('refuses to decrypt over its input file', () async {
    final sourceBefore = await _hash(encryptedInput);

    await expectLater(
      decryptor.decrypt(
        input: encryptedInput,
        output: encryptedInput,
        rawKeyHex: _publicTestKey,
      ),
      throwsA(
        isA<WxSQLite3DecryptException>().having(
          (error) => error.code,
          'code',
          WxSQLite3DecryptIssueCode.overlappingPaths,
        ),
      ),
    );

    expect(await _hash(encryptedInput), sourceBefore);
  });
}

Future<String> _hash(File file) async {
  return (await sha256.bind(file.openRead()).first).toString();
}

Future<List<FileSystemEntity>> _partialFiles(Directory directory) {
  return directory
      .list()
      .where(
        (entity) => p
            .basename(entity.path)
            .startsWith('.decrypted_journal.db.decrypt-'),
      )
      .toList();
}
