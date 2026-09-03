import 'dart:convert';
import 'dart:io';

import 'package:application/src/offline_demo/bootstrap/offline_bootstrap.dart';
import 'package:application/src/offline_demo/data/wecom_active_dataset_runtime.dart';
import 'package:application/src/offline_demo/data/wecom_conversation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
import 'package:application/src/offline_demo/data/wecom_database_package_exporter.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_command_service.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_database.dart';
import 'package:application/src/offline_demo/data/wecom_overlay_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final samples = Directory(
    p.join(
      Directory.current.parent.path,
      '.local',
      'offline-demo',
      'db_spec',
      'samples',
    ),
  );

  setUpAll(sqfliteFfiInit);

  test(
    'matches the packaged WeCom business projection snapshot',
    () async {
      final contract = WeComPackageContract.fromJsonString(
        await File(
          p.join(
            Directory.current.path,
            'assets',
            'offline_demo',
            'wecom_schema_contract.json',
          ),
        ).readAsString(),
      );
      final expected = jsonDecode(
        await File(
          p.join(
            Directory.current.path,
            'test',
            'offline_demo',
            'fixtures',
            'wecom_business_snapshot.json',
          ),
        ).readAsString(),
      );
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'tui_wecom_business_snapshot_',
      );
      addTearDown(() async {
        if (await temporaryDirectory.exists()) {
          await temporaryDirectory.delete(recursive: true);
        }
      });

      final setup = await _importSamplesAndOpen(
        samples: samples,
        temporaryDirectory: temporaryDirectory,
        contract: contract,
      );
      addTearDown(setup.environment.close);

      final actual = await _businessSnapshot(
        environment: setup.environment,
        samples: samples,
      );

      expect(actual, expected);
    },
    skip: samples.existsSync()
        ? false
        : 'Requires .local/offline-demo/db_spec/samples',
  );

  test(
    'round-trips certified writes through SQL and production repositories',
    () async {
      final contract = WeComPackageContract.fromJsonString(
        await File(
          p.join(
            Directory.current.path,
            'assets',
            'offline_demo',
            'wecom_schema_contract.json',
          ),
        ).readAsString(),
      );
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'tui_wecom_business_round_trip_',
      );
      addTearDown(() async {
        if (await temporaryDirectory.exists()) {
          await temporaryDirectory.delete(recursive: true);
        }
      });
      final setup = await _importSamplesAndOpen(
        samples: samples,
        temporaryDirectory: temporaryDirectory,
        contract: contract,
      );
      addTearDown(setup.environment.close);
      final environment = setup.environment;
      final profile = environment.store.profile!;
      final contactCandidates = environment.store.contacts
          .where((contact) => contact.id != profile.id)
          .take(2)
          .toList(growable: false);
      expect(contactCandidates, hasLength(2));
      final updatedContact = contactCandidates[0];
      final deletedContact = contactCandidates[1];
      final conversation = environment.store.conversations.firstWhere(
        (candidate) => !candidate.isPinned && !candidate.isMuted,
      );
      const updatedDisplayName = 'Round-trip contact';
      final commands = WeComOverlayCommandService(
        overlayDatabase: environment.wecomOverlayDatabase,
        contract: contract,
      );

      await commands.upsert(
        datasetId: setup.imported.datasetId,
        databaseName: 'user.db',
        tableName: 'user_table',
        rowKey: {'id': int.parse(updatedContact.id)},
        values: const {'real_name': '', 'name': updatedDisplayName},
      );
      await commands.tombstone(
        datasetId: setup.imported.datasetId,
        databaseName: 'user.db',
        tableName: 'user_table',
        rowKey: {'id': int.parse(deletedContact.id)},
      );
      await environment.repositories.conversations.setPinned(
        conversation.id,
        true,
      );
      await environment.repositories.conversations.setMuted(
        conversation.id,
        true,
      );

      final operationCount = await _overlayOperationCount(environment);
      expect(operationCount, 4);
      final exported = await WeComDatabasePackageExporter(
        contract: contract,
        databaseFactory: databaseFactoryFfi,
      ).export(
        basePackage: setup.imported,
        overlayDatabase: environment.wecomOverlayDatabase,
        destinationDirectory: Directory(
          p.join(temporaryDirectory.path, 'compatible-copy'),
        ),
      );
      expect(exported.appliedRevisionCount, 4);
      expect(exported.datasetId, isNot(setup.imported.datasetId));
      expect(exported.files, hasLength(contract.databases.length));
      expect(await _overlayOperationCount(environment), operationCount);

      await _expectReferenceSqlProjection(
        exported: exported,
        updatedContactId: updatedContact.id,
        deletedContactId: deletedContact.id,
        updatedDisplayName: updatedDisplayName,
        conversationId: conversation.id,
      );

      final roundTripRoot = Directory(
        p.join(temporaryDirectory.path, 'round-trip'),
      );
      final importer = WeComDatabasePackageImporter(
        contract: contract,
        databaseFactory: databaseFactoryFfi,
      );
      final reimported = await importer.importPackage(
        sourceDirectory: exported.directory,
        destinationRoot: roundTripRoot,
      );
      expect(reimported.datasetId, exported.datasetId);
      final roundTripEnvironment = await _activateAndOpen(
        imported: reimported,
        destinationRoot: roundTripRoot,
        mediaRoot: Directory(p.join(temporaryDirectory.path, 'round-media')),
        configFile: File(p.join(samples.path, 'sample_Config.cfg')),
        contract: contract,
      );
      addTearDown(roundTripEnvironment.close);

      final roundTripContacts = roundTripEnvironment.store.contacts;
      expect(
        roundTripContacts
            .singleWhere(
              (contact) => contact.id == updatedContact.id,
            )
            .displayName,
        updatedDisplayName,
      );
      expect(
        roundTripContacts.any((contact) => contact.id == deletedContact.id),
        isFalse,
      );
      final roundTripConversation =
          roundTripEnvironment.store.conversations.singleWhere(
        (candidate) => candidate.id == conversation.id,
      );
      expect(roundTripConversation.isPinned, isTrue);
      expect(roundTripConversation.isMuted, isTrue);
      expect(await _overlayOperationCount(roundTripEnvironment), 0);
    },
    skip: samples.existsSync()
        ? false
        : 'Requires .local/offline-demo/db_spec/samples',
  );
}

Future<
    ({
      WeComImportedPackage imported,
      OfflineEnvironment environment,
    })> _importSamplesAndOpen({
  required Directory samples,
  required Directory temporaryDirectory,
  required WeComPackageContract contract,
}) async {
  final source = await _copyPackageSource(
    samples: samples,
    destination: Directory(p.join(temporaryDirectory.path, 'source')),
    contract: contract,
  );
  final configFile = await File(
    p.join(samples.path, 'sample_Config.cfg'),
  ).copy(p.join(source.path, 'Config.cfg'));
  final destinationRoot = Directory(p.join(temporaryDirectory.path, 'wecom'));
  final importer = WeComDatabasePackageImporter(
    contract: contract,
    databaseFactory: databaseFactoryFfi,
  );
  final imported = await importer.importPackage(
    sourceDirectory: source,
    destinationRoot: destinationRoot,
  );
  final environment = await _activateAndOpen(
    imported: imported,
    destinationRoot: destinationRoot,
    mediaRoot: Directory(p.join(temporaryDirectory.path, 'media')),
    configFile: configFile,
    contract: contract,
  );
  return (imported: imported, environment: environment);
}

Future<OfflineEnvironment> _activateAndOpen({
  required WeComImportedPackage imported,
  required Directory destinationRoot,
  required Directory mediaRoot,
  required File configFile,
  required WeComPackageContract contract,
}) async {
  final importer = WeComDatabasePackageImporter(
    contract: contract,
    databaseFactory: databaseFactoryFfi,
  );
  final overlay = await WeComOverlayDatabase.open(
    factory: databaseFactoryFfi,
    databasePath: p.join(
      destinationRoot.path,
      WeComOverlayDatabase.fileName,
    ),
  );
  try {
    await WeComActiveDatasetResolver(
      destinationRoot: destinationRoot,
      packageImporter: importer,
      databaseFactory: databaseFactoryFfi,
      overlayDatabase: overlay,
    ).ensureInitialDataset(imported.datasetId, configFile: configFile);
  } finally {
    await overlay.close();
  }
  return OfflineBootstrap.create(
    factory: databaseFactoryFfi,
    mediaRootDirectory: mediaRoot,
    wecomRootDirectory: destinationRoot,
    wecomContract: contract,
  );
}

Future<Directory> _copyPackageSource({
  required Directory samples,
  required Directory destination,
  required WeComPackageContract contract,
}) async {
  await destination.create(recursive: true);
  for (final database in contract.databases) {
    await File(
      p.join(samples.path, 'sample_${database.fileName}'),
    ).copy(p.join(destination.path, database.fileName));
  }
  return destination;
}

Future<void> _expectReferenceSqlProjection({
  required WeComExportedPackage exported,
  required String updatedContactId,
  required String deletedContactId,
  required String updatedDisplayName,
  required String conversationId,
}) async {
  final userDatabase = await databaseFactoryFfi.openDatabase(
    exported.databaseFile('user.db').path,
    options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
  );
  try {
    final updatedRows = await userDatabase.rawQuery(
      'SELECT COALESCE('
      "NULLIF(real_name, ''), NULLIF(name, ''), NULLIF(account, ''), ''"
      ') AS display_name FROM user_table WHERE id = ?',
      [int.parse(updatedContactId)],
    );
    expect(updatedRows.single['display_name'], updatedDisplayName);
    final deletedRows = await userDatabase.rawQuery(
      'SELECT COUNT(*) AS count FROM user_table WHERE id = ?',
      [int.parse(deletedContactId)],
    );
    expect(deletedRows.single['count'], 0);
  } finally {
    await userDatabase.close();
  }

  final sessionDatabase = await databaseFactoryFfi.openDatabase(
    exported.databaseFile('session.db').path,
    options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
  );
  try {
    final rows = await sessionDatabase.rawQuery(
      'SELECT is_sticked, is_blocked '
      'FROM conversation_table WHERE id = ?',
      [conversationId],
    );
    expect(rows.single, {'is_sticked': 1, 'is_blocked': 1});
  } finally {
    await sessionDatabase.close();
  }
}

Future<int> _overlayOperationCount(OfflineEnvironment environment) async {
  final rows = await environment.wecomOverlayDatabase.connection.rawQuery(
    'SELECT COUNT(*) AS count FROM ${WeComOverlaySchema.operationsTable}',
  );
  return rows.single['count']! as int;
}

Future<Map<String, Object?>> _businessSnapshot({
  required OfflineEnvironment environment,
  required Directory samples,
}) async {
  final store = environment.store;
  final profile = store.profile!;
  final contacts = store.contacts;
  final conversations = store.conversations;
  final conversationTypes = <String, int>{};
  final messageKinds = <String, int>{};
  var messageCount = 0;
  var messagesWithEmptySenders = 0;
  for (final conversation in conversations) {
    conversationTypes.update(
      conversation.type,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    final messages = await environment.repositories.conversations.listMessages(
      conversation.id,
    );
    messageCount += messages.length;
    for (final message in messages) {
      messageKinds.update(
        message.kind,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      if (message.senderName.isEmpty) {
        messagesWithEmptySenders++;
      }
    }
  }

  final draftDatabase = await databaseFactoryFfi.openDatabase(
    p.join(samples.path, 'Data-Sample6', 'session.db'),
    options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
  );
  Map<String, String> drafts;
  try {
    drafts = await WeComConversationRepository(
      draftDatabase,
    ).listConversationDraftTexts();
  } finally {
    await draftDatabase.close();
  }
  final overlayOperations = await environment.wecomOverlayDatabase.connection
      .query(WeComOverlaySchema.operationsTable);

  return {
    'profile': {
      'displayNamePresent': profile.displayName.isNotEmpty,
      'titlePresent': profile.title.isNotEmpty,
      'departmentPresent': profile.department.isNotEmpty,
      'accountEmpty': (profile.account ?? '').isEmpty,
      'corporationNamePresent': (profile.corporationName ?? '').isNotEmpty,
      'phoneMasked': RegExp(r'^\d{3}\*{4}\d{4}$').hasMatch(profile.phone ?? ''),
      'emailPresent': profile.email != null,
      'currentUserInContacts': contacts.any(
        (contact) => contact.id == profile.id,
      ),
    },
    'contacts': {
      'count': contacts.length,
      'emptyDisplayNames':
          contacts.where((contact) => contact.displayName.isEmpty).length,
      'accounts': contacts.where((contact) => contact.account != null).length,
      'organizations':
          contacts.where((contact) => contact.organizationName != null).length,
      'jobs': contacts.where((contact) => contact.jobTitle != null).length,
    },
    'conversations': {
      'count': conversations.length,
      'types': conversationTypes,
      'unreadTotal': conversations.fold<int>(
        0,
        (total, conversation) => total + conversation.unreadCount,
      ),
      'pinned':
          conversations.where((conversation) => conversation.isPinned).length,
      'muted':
          conversations.where((conversation) => conversation.isMuted).length,
      'drafts': conversations
          .where((conversation) => conversation.draftText.isNotEmpty)
          .length,
    },
    'messages': {
      'count': messageCount,
      'kinds': messageKinds,
      'emptySenders': messagesWithEmptySenders,
    },
    'draft': {
      'count': drafts.length,
      'text': drafts.values.single,
    },
    'overlayOperations': overlayOperations.length,
  };
}
