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

  test(
    'certifies current empty, boundary, and coexisting-version samples',
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
        'tui_wecom_compatibility_boundary_',
      );
      addTearDown(() async {
        if (await temporaryDirectory.exists()) {
          await temporaryDirectory.delete(recursive: true);
        }
      });
      final source = await _copyPackageSource(
        samples: samples,
        destination: Directory(p.join(temporaryDirectory.path, 'source')),
        contract: contract,
      );

      expect(
        contract.databases
            .where((database) => database.allowEmpty)
            .map((database) => database.fileName),
        unorderedEquals(['group_collect.db', 'group_meeting.db']),
      );
      for (final database in contract.databases) {
        final isEmpty =
            await File(p.join(source.path, database.fileName)).length() == 0;
        expect(
          isEmpty,
          database.allowEmpty,
          reason: '${database.fileName} empty-file contract differs',
        );
      }

      const coexistingVersionTables = {
        'company.db': [
          'circle_corp_app_v1',
          'circle_corp_app_v2',
          'circle_corp_app_v4',
          'corp_app_v5',
          'corp_app_v7',
        ],
        'crm.db': [
          'party_table',
          'party_table_v2',
          'party_table_v3',
          'party_table_v9',
        ],
      };
      for (final entry in coexistingVersionTables.entries) {
        final actualTables = contract.databases
            .singleWhere((database) => database.fileName == entry.key)
            .tables
            .keys;
        expect(actualTables, containsAll(entry.value));
      }

      final imported = await WeComDatabasePackageImporter(
        contract: contract,
        databaseFactory: databaseFactoryFfi,
      ).importPackage(
        sourceDirectory: source,
        destinationRoot: Directory(
          p.join(temporaryDirectory.path, 'destination'),
        ),
      );
      expect(
        imported.files.values
            .where((file) => file.isEmptyPlaceholder)
            .map((file) => file.fileName),
        unorderedEquals(['group_collect.db', 'group_meeting.db']),
      );

      for (final databaseContract
          in contract.databases.where((database) => !database.allowEmpty)) {
        final database = await imported.openReadOnly(
          databaseContract.fileName,
          factory: databaseFactoryFfi,
        );
        try {
          for (final pragma in ['user_version', 'application_id']) {
            final rows = await database.rawQuery('PRAGMA $pragma');
            expect(
              rows.single.values.single,
              0,
              reason: '${databaseContract.fileName} PRAGMA $pragma differs',
            );
          }
        } finally {
          await database.close();
        }
      }

      final positiveBoundaryQueries = {
        'user.db': 'SELECT '
            '(SELECT COUNT(*) FROM user_table '
            "WHERE real_name = '' AND name <> '' "
            'AND COALESCE('
            "NULLIF(real_name, ''), NULLIF(name, ''), NULLIF(account, ''), ''"
            ') = name) AS fallback_names, '
            '(SELECT COUNT(*) FROM user_table WHERE id > 2147483647) '
            'AS wide_ids, '
            '(SELECT COUNT(*) FROM user_table AS users '
            'WHERE NOT EXISTS (SELECT 1 FROM user_dept_tableV2 AS memberships '
            'WHERE memberships.user_id = users.id)) AS no_department, '
            '(SELECT COUNT(*) FROM dept_tree_table '
            'WHERE first_child_id = 4294967295 '
            'OR next_sibling_id = 4294967295) AS sentinel_links',
        'session.db': 'SELECT '
            '(SELECT COUNT(*) FROM conversation_table '
            "WHERE id IN ('FILEASSIST', 'ANNOUNCE', 'MAIL', 'APPROVAL')) "
            'AS system_conversations, '
            '(SELECT COUNT(*) FROM conversation_table WHERE id LIKE '
            "'S:%') AS single_conversations, "
            '(SELECT COUNT(*) FROM unread_conversation_table '
            'WHERE unread_count = 0) AS read_rows, '
            '(SELECT COUNT(*) FROM unread_conversation_table '
            'WHERE unread_count > 1) AS multiple_unread_rows',
        'message.db': 'SELECT '
            '(SELECT COUNT(*) FROM message_table WHERE content IS NULL) '
            'AS null_content, '
            '(SELECT COUNT(*) FROM message_table '
            "WHERE typeof(content) IN ('text', 'blob') AND length(content) = 0) "
            'AS empty_content, '
            '(SELECT COUNT(*) FROM message_table WHERE typeof(content) = '
            "'blob') AS blob_content, "
            '(SELECT COUNT(*) FROM message_table WHERE content_type = 0) '
            'AS unsupported_content',
      };
      for (final entry in positiveBoundaryQueries.entries) {
        final database = await imported.openReadOnly(
          entry.key,
          factory: databaseFactoryFfi,
        );
        try {
          final counts = (await database.rawQuery(entry.value)).single;
          for (final count in counts.entries) {
            expect(
              count.value,
              greaterThan(0),
              reason: '${entry.key} boundary ${count.key} is missing',
            );
          }
        } finally {
          await database.close();
        }
      }

      final oneUnreadDatabase = await databaseFactoryFfi.openDatabase(
        p.join(samples.path, 'Data-Sample3', 'session.db'),
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      try {
        final rows = await oneUnreadDatabase.rawQuery(
          'SELECT COUNT(*) AS count FROM unread_conversation_table '
          'WHERE unread_count = 1',
        );
        expect(rows.single['count'], greaterThan(0));
      } finally {
        await oneUnreadDatabase.close();
      }
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
  final organizationUnits = store.organizationUnits;
  final contacts = store.contacts;
  final conversations = store.conversations;
  final conversationTypes = <String, int>{};
  final messageKinds = <String, int>{};
  var messageCount = 0;
  var messagesWithEmptySenders = 0;
  var groupCount = 0;
  var groupMemberCount = 0;
  var groupAdminCount = 0;
  var groupNicknameCount = 0;
  var groupIdFallbackNameCount = 0;
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
    if (conversation.type == 'group') {
      groupCount++;
      final members = await environment.repositories.conversations.listMembers(
        conversation.id,
      );
      groupMemberCount += members.length;
      groupAdminCount += members.where((member) => member.isAdmin).length;
      groupNicknameCount +=
          members.where((member) => member.nickname != null).length;
      groupIdFallbackNameCount +=
          members.where((member) => member.displayName == member.userId).length;
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
      'departments':
          contacts.where((contact) => contact.departmentName != null).length,
      'jobs': contacts.where((contact) => contact.jobTitle != null).length,
    },
    'organizationUnits': {
      'count': organizationUnits.length,
      'roots': organizationUnits.where((unit) => unit.parentId == null).length,
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
    'groups': {
      'count': groupCount,
      'members': groupMemberCount,
      'admins': groupAdminCount,
      'nicknames': groupNicknameCount,
      'idFallbackNames': groupIdFallbackNameCount,
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
