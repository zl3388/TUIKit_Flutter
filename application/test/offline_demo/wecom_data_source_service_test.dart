import 'dart:convert';
import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_active_dataset_runtime.dart';
import 'package:application/src/offline_demo/data/wecom_data_source_service.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_incremental_merge_planner.dart';
import 'package:application/src/offline_demo/data/wecom_incremental_migration_service.dart';
import 'package:application/src/offline_demo/data/wecom_identity_repository.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:application/src/offline_demo/data/wecom_source_directory_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'wecom_identity_test_fixture.dart';

void main() {
  late Directory root;
  late Directory destination;
  late WeComPackageContract contract;
  late WeComOverlayDatabase overlay;
  late WeComDatabasePackageImporter importer;
  late WeComActiveDatasetResolver datasetResolver;
  late WeComIncrementalMigrationService migrationService;
  late _MemoryDefaultKeyStore keyStore;
  late WeComDataSourceService service;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tui_wecom_source_');
    destination = await Directory(p.join(root.path, 'managed')).create();
    contract = WeComPackageContract(
      formatVersion: 1,
      scope: 'data source service test',
      databases: identityDatabaseContracts(),
    );
    importer = WeComDatabasePackageImporter(
      contract: contract,
      databaseFactory: databaseFactoryFfi,
    );
    overlay = await WeComOverlayDatabase.open(
      factory: databaseFactoryFfi,
      databasePath: p.join(destination.path, WeComOverlayDatabase.fileName),
    );
    datasetResolver = WeComActiveDatasetResolver(
      destinationRoot: destination,
      packageImporter: importer,
      databaseFactory: databaseFactoryFfi,
      overlayDatabase: overlay,
    );
    keyStore = _MemoryDefaultKeyStore();
    migrationService = WeComIncrementalMigrationService(
      overlayDatabase: overlay,
      planner: WeComIncrementalMergePlanner(
        contract: contract,
        databaseFactory: databaseFactoryFfi,
      ),
      identityResolver: WeComIdentityResolver(databaseFactoryFfi),
    );
    service = WeComDataSourceService(
      destinationRoot: destination,
      packageImporter: importer,
      datasetResolver: datasetResolver,
      migrationService: migrationService,
      overlayDatabase: overlay,
      defaultKeyStore: keyStore,
      selectionStore: FileWeComSourceSelectionStore(
        File(p.join(destination.path, 'data_source.json')),
      ),
    );
  });

  tearDown(() async {
    await overlay.close();
    await root.delete(recursive: true);
  });

  test('accepts an account root or its Data directory and activates once',
      () async {
    final account = await _createAccount(root, 'account-a', name: 'Before');

    final prepared = await service.prepare(account);
    final result = await service.activate(prepared);
    final refreshed = await service.prepare(Directory(p.join(
      account.path,
      'Data',
    )));
    final unchanged = await service.activate(refreshed);

    expect(result.status, WeComDataSourceActivationStatus.activated);
    expect(unchanged.status, WeComDataSourceActivationStatus.unchanged);
    expect(result.identity.corporationId, testCorporationId);
    final saved = await service.loadSelectedSource();
    expect(saved!.selectedPath, p.join(account.path, 'Data'));
    expect(saved.datasetId, prepared.package.datasetId);
  });

  test('rejects a directory that is neither an account root nor Data',
      () async {
    final unrelated = await Directory(p.join(root.path, 'unrelated')).create();

    await expectLater(
      service.prepare(unrelated),
      throwsA(
        isA<WeComDataSourceException>().having(
          (error) => error.code,
          'code',
          WeComDataSourceIssueCode.invalidSourceDirectory,
        ),
      ),
    );
  });

  test(
      'requires explicit corporation selection when Config cannot disambiguate',
      () async {
    final account = await _createAccount(
      root,
      'ambiguous',
      name: 'First',
      writeConfig: false,
    );
    await addIdentityCandidate(
      Directory(p.join(account.path, 'Data')),
      corporationId: 200,
      userId: 2,
      name: 'Second',
    );

    final prepared = await service.prepare(account);
    expect(
      prepared.identityResolution.status,
      WeComIdentityResolutionStatus.ambiguousNoConfig,
    );
    await expectLater(
      service.activate(prepared),
      throwsA(
        isA<WeComDataSourceException>().having(
          (error) => error.code,
          'code',
          WeComDataSourceIssueCode.corporationSelectionRequired,
        ),
      ),
    );

    final activated = await service.activate(
      prepared,
      selectedCorporationId: 200,
    );
    expect(activated.identity.userId, 2);
  });

  test('migrates a new snapshot for the same identity', () async {
    final before = await _createAccount(root, 'before', name: 'Before');
    final after = await _createAccount(root, 'after', name: 'After');
    final oldPrepared = await service.prepare(before);
    await service.activate(oldPrepared);

    final newPrepared = await service.prepare(after);
    final result = await service.activate(newPrepared);

    expect(result.status, WeComDataSourceActivationStatus.migrated);
    final latest = (await overlay.connection.query(
      WeComOverlaySchema.datasetActivationsTable,
      orderBy: 'activation_id DESC',
      limit: 1,
    ))
        .single;
    expect(latest['dataset_id'], newPrepared.package.datasetId);
    expect(latest['merge_id'], isNotNull);

    final switchedBack = await service.activate(oldPrepared);
    expect(switchedBack.status, WeComDataSourceActivationStatus.switched);
    final backActivation = (await overlay.connection.query(
      WeComOverlaySchema.datasetActivationsTable,
      orderBy: 'activation_id DESC',
      limit: 1,
    ))
        .single;
    expect(backActivation['dataset_id'], oldPrepared.package.datasetId);
    expect(backActivation['merge_id'], isNull);
  });

  test('switches a different identity without creating a merge attempt',
      () async {
    final first = await _createAccount(root, 'first', name: 'First');
    final second = await _createAccount(
      root,
      'second',
      name: 'First changed',
      writeConfig: false,
    );
    await addIdentityCandidate(
      Directory(p.join(second.path, 'Data')),
      corporationId: 200,
      userId: 2,
      name: 'Second',
    );
    await service.activate(await service.prepare(first));

    final prepared = await service.prepare(second);
    final result = await service.activate(
      prepared,
      selectedCorporationId: 200,
    );

    expect(result.status, WeComDataSourceActivationStatus.switched);
    expect(result.identity.scope.corporationId, 200);
    expect(
      await _countRows(overlay, WeComOverlaySchema.mergeAttemptsTable),
      0,
    );
    final latest = (await overlay.connection.query(
      WeComOverlaySchema.datasetActivationsTable,
      orderBy: 'activation_id DESC',
      limit: 1,
    ))
        .single;
    expect(latest['merge_id'], isNull);
    expect(latest['current_user_id'], 2);
  });

  test('stores a remembered key outside data source metadata', () async {
    const rawKey = '79fbb424f3035e57c6d4cde3a6981de3';
    final account = await _createAccount(root, 'account-key', name: 'Key');
    final prepared = await service.prepare(account);

    await service.activate(prepared, defaultRawKeyToSave: rawKey);

    expect(await keyStore.read(), rawKey);
    final metadata = await File(
      p.join(destination.path, 'data_source.json'),
    ).readAsString();
    expect(metadata, isNot(contains(rawKey)));
    await service.clearDefaultRawKey();
    expect(await service.hasDefaultRawKey(), isFalse);
  });

  test('persists a source locator and resolves it again for refresh', () async {
    const locator = 'content://documents/tree/account-a';
    final account = await _createAccount(root, 'located', name: 'Located');
    final prepared = await service.prepare(account, sourceLocator: locator);
    await service.activate(prepared);
    final directoryResolver = _RecordingDirectoryResolver(account);
    final refreshingService = WeComDataSourceService(
      destinationRoot: destination,
      packageImporter: importer,
      datasetResolver: datasetResolver,
      migrationService: migrationService,
      overlayDatabase: overlay,
      defaultKeyStore: keyStore,
      selectionStore: FileWeComSourceSelectionStore(
        File(p.join(destination.path, 'data_source.json')),
      ),
      sourceDirectoryResolver: directoryResolver,
    );

    final refreshed = await refreshingService.prepareSaved();

    expect(directoryResolver.requestedLocators, [locator]);
    expect(refreshed.sourceLocator, locator);
    expect(
        (await refreshingService.loadSelectedSource())!.sourceLocator, locator);
    final metadata = jsonDecode(
      await File(p.join(destination.path, 'data_source.json')).readAsString(),
    ) as Map<String, dynamic>;
    expect(metadata['format_version'], 2);
    expect(metadata['source_locator'], locator);
  });

  test('reads version 1 source metadata as a filesystem locator', () {
    final source = WeComSavedDataSource.fromJson({
      'format_version': 1,
      'selected_path': '/source/account',
      'data_path': '/source/account/Data',
      'dataset_id': List.filled(64, 'a').join(),
      'current_corp_id': 1,
      'current_user_id': 2,
      'updated_at_micros': 3,
    });

    expect(source.sourceLocator, '/source/account');
  });
}

Future<int> _countRows(WeComOverlayDatabase overlay, String table) async {
  return Sqflite.firstIntValue(
        await overlay.connection.rawQuery('SELECT COUNT(*) FROM $table'),
      ) ??
      0;
}

Future<Directory> _createAccount(
  Directory root,
  String directoryName, {
  required String name,
  bool writeConfig = true,
}) async {
  final account = await Directory(p.join(root.path, directoryName)).create();
  final data = await Directory(p.join(account.path, 'Data')).create();
  await createIdentityDatabases(data, contactName: name);
  if (writeConfig) {
    await File(p.join(account.path, 'Config.cfg')).writeAsString(
      jsonEncode({
        'config': {'LoginCompanyId': '$testCorporationId'},
      }),
    );
  }
  return account;
}

class _MemoryDefaultKeyStore implements WeComDefaultKeyStore {
  String? value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String rawKeyHex) async => value = rawKeyHex;
}

class _RecordingDirectoryResolver implements WeComSourceDirectoryResolver {
  _RecordingDirectoryResolver(this.directory);

  final Directory directory;
  final requestedLocators = <String>[];

  @override
  Future<Directory> resolve(String locator) async {
    requestedLocators.add(locator);
    return directory;
  }
}
