import 'dart:io';

import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_identity_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'wecom_identity_test_fixture.dart';

void main() {
  late Directory temporaryDirectory;
  late Directory sourceDirectory;
  late WeComDatabasePackageImporter importer;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('tui_wecom_identity_');
    sourceDirectory = await Directory(
      p.join(temporaryDirectory.path, 'source'),
    ).create();
    importer = WeComDatabasePackageImporter(
      contract: WeComPackageContract(
        formatVersion: 1,
        scope: 'identity repository test',
        databases: identityDatabaseContracts(),
      ),
      databaseFactory: databaseFactoryFfi,
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('resolves a single candidate and reads its profile', () async {
    await createIdentityDatabases(
      sourceDirectory,
      contactName: 'Current User',
    );
    final package =
        await _import(importer, sourceDirectory, temporaryDirectory);
    final resolution = await WeComIdentityResolver(databaseFactoryFfi).resolve(
      package: package,
    );

    expect(resolution.status, WeComIdentityResolutionStatus.resolved);
    expect(resolution.selected?.corporationId, testCorporationId);
    expect(resolution.selected?.userId, testCurrentUserId);

    final userDatabase = await package.openReadOnly(
      'user.db',
      factory: databaseFactoryFfi,
    );
    addTearDown(userDatabase.close);
    final profile = await WeComCurrentIdentityRepository(
      userDatabase,
      resolution.selected!,
    ).currentProfile();
    expect(profile.displayName, 'Current User');
    expect(profile.account, 'current');
    expect(profile.corporationName, 'Example Corporation');
    expect(profile.department, 'Engineering');
    expect(profile.title, 'Developer');
    expect(profile.phone, '13800000000');
    expect(profile.email, 'current@example.test');
  });

  test('never chooses the first corporation when config is unavailable',
      () async {
    await createIdentityDatabases(sourceDirectory, contactName: 'First User');
    await addIdentityCandidate(
      sourceDirectory,
      corporationId: 200,
      userId: 2,
      name: 'Second User',
    );
    final package =
        await _import(importer, sourceDirectory, temporaryDirectory);
    final resolver = WeComIdentityResolver(databaseFactoryFfi);

    final missingConfig = await resolver.resolve(package: package);
    expect(
      missingConfig.status,
      WeComIdentityResolutionStatus.ambiguousNoConfig,
    );
    expect(missingConfig.selected, isNull);

    final unknownConfig = File(p.join(temporaryDirectory.path, 'Config.cfg'));
    await unknownConfig.writeAsString(
      '{"config":{"LoginCompanyId":"999"}}',
    );
    final noMatch = await resolver.resolve(
      package: package,
      configFile: unknownConfig,
    );
    expect(noMatch.status, WeComIdentityResolutionStatus.ambiguousNoMatch);
    expect(noMatch.selected, isNull);
  });

  test('config and explicit selection resolve a validated corporation pair',
      () async {
    await createIdentityDatabases(sourceDirectory, contactName: 'First User');
    await addIdentityCandidate(
      sourceDirectory,
      corporationId: 200,
      userId: 2,
      name: 'Second User',
    );
    final package =
        await _import(importer, sourceDirectory, temporaryDirectory);
    final config = File(p.join(temporaryDirectory.path, 'Config.cfg'));
    await config.writeAsString('{"config":{"LoginCompanyId":"200"}}');
    final resolver = WeComIdentityResolver(databaseFactoryFfi);

    final configured = await resolver.resolve(
      package: package,
      configFile: config,
    );
    expect(configured.selected?.corporationId, 200);
    expect(configured.selected?.userId, 2);

    final explicit = await resolver.resolve(
      package: package,
      configFile: config,
      selectedCorporationId: testCorporationId,
    );
    expect(explicit.selected?.corporationId, testCorporationId);
    expect(explicit.selected?.userId, testCurrentUserId);

    await expectLater(
      resolver.resolve(package: package, selectedCorporationId: 999),
      throwsA(
        isA<WeComIdentityException>().having(
          (error) => error.code,
          'code',
          WeComIdentityIssueCode.invalidExplicitSelection,
        ),
      ),
    );
  });

  test('rejects an explicit corporation when no candidate exists', () async {
    await createIdentityDatabases(sourceDirectory, contactName: 'Current User');
    final company = await databaseFactoryFfi.openDatabase(
      p.join(sourceDirectory.path, 'company.db'),
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await company.delete('self_corp_list_table');
    await company.close();
    final package =
        await _import(importer, sourceDirectory, temporaryDirectory);

    await expectLater(
      WeComIdentityResolver(databaseFactoryFfi).resolve(
        package: package,
        selectedCorporationId: testCorporationId,
      ),
      throwsA(
        isA<WeComIdentityException>().having(
          (error) => error.code,
          'code',
          WeComIdentityIssueCode.invalidExplicitSelection,
        ),
      ),
    );
  });
}

Future<WeComImportedPackage> _import(
  WeComDatabasePackageImporter importer,
  Directory source,
  Directory root,
) {
  return importer.importPackage(
    sourceDirectory: source,
    destinationRoot: Directory(p.join(root.path, 'imports')),
  );
}
