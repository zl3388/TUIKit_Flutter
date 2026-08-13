import 'dart:io';

import 'package:application/src/offline_demo/bootstrap/offline_bootstrap.dart';
import 'package:application/src/offline_demo/data/wecom_active_dataset_runtime.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'wecom_identity_test_fixture.dart';

void main() {
  late Directory temporaryDirectory;
  late Directory mediaRoot;
  late Directory wecomRoot;
  late String databasePath;
  late WeComPackageContract contract;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_offline_bootstrap_');
    mediaRoot = Directory(p.join(temporaryDirectory.path, 'media'));
    wecomRoot = Directory(p.join(temporaryDirectory.path, 'wecom'));
    databasePath = p.join(temporaryDirectory.path, 'offline.db');
    contract = _contract();
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('does not fall back to schema v2 contacts without an activation',
      () async {
    final environment = await OfflineBootstrap.create(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
      mediaRootDirectory: mediaRoot,
      wecomRootDirectory: wecomRoot,
      wecomContract: contract,
    );

    expect(environment.store.contactsAvailable, isFalse);
    expect(environment.store.identityAvailable, isFalse);
    expect(environment.store.profile, isNull);
    expect(environment.store.contacts, isEmpty);
    expect(environment.wecomRuntime, isNull);

    await environment.close();
    await environment.close();
  });

  test('loads the active merged directory and closes all databases', () async {
    final imported = await _importAndActivate(
      temporaryDirectory: temporaryDirectory,
      wecomRoot: wecomRoot,
      contract: contract,
    );

    final environment = await OfflineBootstrap.create(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
      mediaRootDirectory: mediaRoot,
      wecomRootDirectory: wecomRoot,
      wecomContract: contract,
    );

    expect(environment.store.contactsAvailable, isTrue);
    expect(environment.wecomRuntime?.datasetId, imported.datasetId);
    expect(environment.store.contacts, hasLength(1));
    expect(environment.store.contacts.single.id, '1');
    expect(environment.store.contacts.single.displayName, 'Overlay contact');
    expect(environment.store.contacts.single.account, 'contact.account');
    expect(environment.store.contacts.single.organizationName, 'Example Corp');
    expect(environment.store.contacts.single.jobTitle, 'Engineer');
    expect(environment.store.profile?.displayName, 'Base contact');
    expect(environment.store.profile?.corporationName, 'Example Corporation');
    expect(environment.store.profile?.department, 'Engineering');
    expect(environment.store.profile?.title, 'Developer');
    expect(environment.store.profile?.account, 'current');

    await environment.close();
    await environment.close();
  });

  test('propagates active package corruption and releases opened resources',
      () async {
    final imported = await _importAndActivate(
      temporaryDirectory: temporaryDirectory,
      wecomRoot: wecomRoot,
      contract: contract,
    );
    await imported.databaseFile('user.db').writeAsBytes(
      const [0],
      mode: FileMode.append,
      flush: true,
    );

    await expectLater(
      OfflineBootstrap.create(
        factory: databaseFactoryFfi,
        databasePath: databasePath,
        mediaRootDirectory: mediaRoot,
        wecomRootDirectory: wecomRoot,
        wecomContract: contract,
      ),
      throwsA(
        isA<WeComPackageException>().having(
          (error) => error.code,
          'code',
          WeComPackageIssueCode.existingPackageCorrupt,
        ),
      ),
    );
  });
}

Future<WeComImportedPackage> _importAndActivate({
  required Directory temporaryDirectory,
  required Directory wecomRoot,
  required WeComPackageContract contract,
}) async {
  final source = await Directory(
    p.join(temporaryDirectory.path, 'source'),
  ).create();
  await createIdentityDatabases(
    source,
    contactName: 'Base contact',
    externalCorporationName: 'Example Corp',
    externalJob: 'Engineer',
  );
  await _createSessionDatabase(source);

  final importer = WeComDatabasePackageImporter(
    contract: contract,
    databaseFactory: databaseFactoryFfi,
  );
  final imported = await importer.importPackage(
    sourceDirectory: source,
    destinationRoot: wecomRoot,
  );
  final overlay = await WeComOverlayDatabase.open(
    factory: databaseFactoryFfi,
    databasePath: p.join(wecomRoot.path, WeComOverlayDatabase.fileName),
  );
  try {
    final resolver = WeComActiveDatasetResolver(
      destinationRoot: wecomRoot,
      packageImporter: importer,
      databaseFactory: databaseFactoryFfi,
      overlayDatabase: overlay,
    );
    await resolver.ensureInitialDataset(imported.datasetId);
    await overlay.connection.insert(
      WeComOverlaySchema.operationsTable,
      {
        'dataset_id': imported.datasetId,
        'database_name': 'user.db',
        'table_name': 'user_table',
        'row_key_json': '{"id":1}',
        'operation': 'upsert',
        'values_json': '{"real_name":"Overlay contact"}',
        'created_at_micros': DateTime.now().toUtc().microsecondsSinceEpoch,
      },
    );
  } finally {
    await overlay.close();
  }
  return imported;
}

Future<void> _createSessionDatabase(Directory source) async {
  final database = await databaseFactoryFfi.openDatabase(
    p.join(source.path, 'session.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await database.execute(
    'CREATE TABLE runtime_marker (id INTEGER PRIMARY KEY NOT NULL)',
  );
  await database.insert('runtime_marker', {'id': 1});
  await database.close();
}

WeComPackageContract _contract() {
  return WeComPackageContract(
    formatVersion: 1,
    scope: 'offline bootstrap test',
    databases: [
      ...identityDatabaseContracts(),
      WeComDatabaseContract(
        fileName: 'session.db',
        allowEmpty: false,
        tables: {
          'runtime_marker': [
            testColumn(
              'id',
              'INTEGER',
              notNull: true,
              primaryKeyPosition: 1,
            ),
          ],
        },
        indexes: const {},
      ),
    ],
  );
}
