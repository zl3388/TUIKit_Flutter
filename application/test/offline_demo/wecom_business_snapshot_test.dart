import 'dart:convert';
import 'dart:io';

import 'package:application/src/offline_demo/bootstrap/offline_bootstrap.dart';
import 'package:application/src/offline_demo/data/wecom_active_dataset_runtime.dart';
import 'package:application/src/offline_demo/data/wecom_conversation_repository.dart';
import 'package:application/src/offline_demo/data/wecom_database_package.dart';
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

      final source = await _copyPackageSource(
        samples: samples,
        destination: Directory(p.join(temporaryDirectory.path, 'source')),
        contract: contract,
      );
      final configFile = await File(
        p.join(samples.path, 'sample_Config.cfg'),
      ).copy(p.join(source.path, 'Config.cfg'));
      final wecomRoot = Directory(p.join(temporaryDirectory.path, 'wecom'));
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
        await WeComActiveDatasetResolver(
          destinationRoot: wecomRoot,
          packageImporter: importer,
          databaseFactory: databaseFactoryFfi,
          overlayDatabase: overlay,
        ).ensureInitialDataset(imported.datasetId, configFile: configFile);
      } finally {
        await overlay.close();
      }

      final environment = await OfflineBootstrap.create(
        factory: databaseFactoryFfi,
        mediaRootDirectory: Directory(
          p.join(temporaryDirectory.path, 'media'),
        ),
        wecomRootDirectory: wecomRoot,
        wecomContract: contract,
      );
      addTearDown(environment.close);

      final actual = await _businessSnapshot(
        environment: environment,
        samples: samples,
      );

      expect(actual, expected);
    },
    skip: samples.existsSync()
        ? false
        : 'Requires .local/offline-demo/db_spec/samples',
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
