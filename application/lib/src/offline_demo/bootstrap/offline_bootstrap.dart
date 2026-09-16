import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../data/local_media_store.dart';
import '../data/system_attachment_opener.dart';
import '../data/wecom_activity_repository.dart';
import '../data/wecom_active_dataset_runtime.dart';
import '../data/wecom_contact_repository.dart';
import '../data/wecom_database_package.dart';
import '../data/wecom_local_simulation_repository.dart';
import '../data/wecom_offline_conversation_repository.dart';
import '../data/wecom_overlay_command_service.dart';
import '../data/wecom_overlay_database.dart';
import '../domain/repositories.dart';
import '../state/admin_access_controller.dart';
import '../state/offline_demo_store.dart';

class OfflineEnvironment {
  OfflineEnvironment({
    required this.mediaStore,
    required this.repositories,
    required this.store,
    required this.adminAccess,
    required this.wecomOverlayDatabase,
    required this.wecomDatasetResolver,
    this.wecomRuntime,
  });

  final LocalMediaStore mediaStore;
  final OfflineRepositoryBundle repositories;
  final OfflineDemoStore store;
  final AdminAccessController adminAccess;
  final WeComOverlayDatabase wecomOverlayDatabase;
  final WeComActiveDatasetResolver wecomDatasetResolver;
  final WeComActiveDatasetRuntime? wecomRuntime;

  bool _closed = false;

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      await wecomRuntime?.close();
    } finally {
      try {
        await wecomOverlayDatabase.close();
      } finally {
        adminAccess.dispose();
      }
    }
  }
}

abstract final class OfflineBootstrap {
  static const _wecomRootName = 'offline_demo_wecom';
  static const _contractAsset =
      'assets/offline_demo/wecom_schema_contract.json';

  static Future<OfflineEnvironment> create({
    DatabaseFactory? factory,
    Directory? mediaRootDirectory,
    Directory? wecomRootDirectory,
    WeComPackageContract? wecomContract,
    AdminCredentialStore? adminCredentialStore,
    String adminBuildPin = const String.fromEnvironment('ADMIN_PIN'),
  }) async {
    final resolvedFactory = factory ?? databaseFactory;
    WeComOverlayDatabase? overlayDatabase;
    WeComActiveDatasetRuntime? runtime;
    AdminAccessController? adminAccess;
    try {
      final mediaStore = mediaRootDirectory == null
          ? await LocalMediaStore.initialize()
          : await LocalMediaStore.forRoot(mediaRootDirectory);
      final wecomRoot = wecomRootDirectory ?? await _defaultWeComRoot();
      await wecomRoot.create(recursive: true);
      adminAccess = AdminAccessController(
        credentialStore: adminCredentialStore ??
            FileAdminCredentialStore(
              File(p.join(wecomRoot.path, 'admin_access.json')),
            ),
        buildPin: adminBuildPin,
      );
      await adminAccess.initialize();
      final contract = wecomContract ??
          WeComPackageContract.fromJsonString(
            await rootBundle.loadString(_contractAsset),
          );
      overlayDatabase = await WeComOverlayDatabase.open(
        factory: resolvedFactory,
        databasePath: p.join(
          wecomRoot.path,
          WeComOverlayDatabase.fileName,
        ),
      );
      final resolver = WeComActiveDatasetResolver(
        destinationRoot: wecomRoot,
        packageImporter: WeComDatabasePackageImporter(
          contract: contract,
          databaseFactory: resolvedFactory,
        ),
        databaseFactory: resolvedFactory,
        overlayDatabase: overlayDatabase,
      );

      ContactRepository contactRepository;
      IdentityRepository identityRepository;
      ConversationRepository conversationRepository;
      ActivityRepository activityRepository;
      try {
        runtime = await resolver.openActive();
        contactRepository = WeComContactRepository(
          runtime.directory,
          currentCorporationId: runtime.identity.identity.corporationId,
        );
        identityRepository = runtime.identity;
        conversationRepository = WeComOfflineConversationRepository(
          datasetId: runtime.datasetId,
          currentUserId: runtime.identity.identity.userId,
          conversations: runtime.conversations,
          messages: runtime.messages,
          contacts: contactRepository,
          commands: WeComOverlayCommandService(
            overlayDatabase: overlayDatabase,
            contract: contract,
            identityScope: runtime.identity.identity.scope,
          ),
          media: runtime.media,
          simulation: WeComLocalSimulationRepository(
            overlayDatabase: overlayDatabase,
            identityScope: runtime.identity.identity.scope,
          ),
        );
        activityRepository = WeComActivityRepository(
          currentUserId: runtime.identity.identity.userId,
          messages: runtime.messages,
          contacts: contactRepository,
        );
      } on WeComActiveDatasetException catch (error) {
        if (error.code != WeComActiveDatasetIssueCode.noActiveDataset &&
            error.code != WeComActiveDatasetIssueCode.identityRequired) {
          rethrow;
        }
        contactRepository = const UnavailableContactRepository();
        identityRepository = const UnavailableIdentityRepository();
        conversationRepository = const UnavailableConversationRepository();
        activityRepository = const UnavailableActivityRepository();
      }

      final repositories = OfflineRepositoryBundle(
        identityRepository: identityRepository,
        contactRepository: contactRepository,
        conversationRepository: conversationRepository,
        activityRepository: activityRepository,
        attachmentOpener: const SystemAttachmentOpener(),
      );
      final store = OfflineDemoStore(repositories);
      await store.load();
      return OfflineEnvironment(
        mediaStore: mediaStore,
        repositories: repositories,
        store: store,
        adminAccess: adminAccess,
        wecomOverlayDatabase: overlayDatabase,
        wecomDatasetResolver: resolver,
        wecomRuntime: runtime,
      );
    } catch (_) {
      try {
        await runtime?.close();
      } finally {
        try {
          await overlayDatabase?.close();
        } finally {
          adminAccess?.dispose();
        }
      }
      rethrow;
    }
  }

  static Future<Directory> _defaultWeComRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, _wecomRootName));
  }
}
