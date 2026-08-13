import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../data/local_media_store.dart';
import '../data/offline_database.dart';
import '../data/wecom_active_dataset_runtime.dart';
import '../data/wecom_contact_repository.dart';
import '../data/wecom_database_package.dart';
import '../data/wecom_overlay_database.dart';
import '../domain/repositories.dart';
import '../state/offline_demo_store.dart';

class OfflineEnvironment {
  OfflineEnvironment({
    required this.database,
    required this.mediaStore,
    required this.repositories,
    required this.store,
    required this.wecomOverlayDatabase,
    this.wecomRuntime,
  });

  final OfflineDatabase database;
  final LocalMediaStore mediaStore;
  final OfflineRepositoryBundle repositories;
  final OfflineDemoStore store;
  final WeComOverlayDatabase wecomOverlayDatabase;
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
        await database.close();
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
    String? databasePath,
    Directory? mediaRootDirectory,
    Directory? wecomRootDirectory,
    WeComPackageContract? wecomContract,
  }) async {
    final resolvedFactory = factory ?? databaseFactory;
    final database = await OfflineDatabase.open(
      factory: resolvedFactory,
      databasePath: databasePath,
    );
    WeComOverlayDatabase? overlayDatabase;
    WeComActiveDatasetRuntime? runtime;
    try {
      final mediaStore = mediaRootDirectory == null
          ? await LocalMediaStore.initialize()
          : await LocalMediaStore.forRoot(mediaRootDirectory);
      final wecomRoot = wecomRootDirectory ?? await _defaultWeComRoot();
      await wecomRoot.create(recursive: true);
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
      try {
        runtime = await resolver.openActive();
        contactRepository = WeComContactRepository(runtime.directory);
      } on WeComActiveDatasetException catch (error) {
        if (error.code != WeComActiveDatasetIssueCode.noActiveDataset) {
          rethrow;
        }
        contactRepository = const UnavailableContactRepository();
      }

      final repositories = OfflineRepositoryBundle(
        database,
        contactRepository: contactRepository,
      );
      final store = OfflineDemoStore(repositories);
      await store.load();
      return OfflineEnvironment(
        database: database,
        mediaStore: mediaStore,
        repositories: repositories,
        store: store,
        wecomOverlayDatabase: overlayDatabase,
        wecomRuntime: runtime,
      );
    } catch (_) {
      try {
        await runtime?.close();
      } finally {
        try {
          await overlayDatabase?.close();
        } finally {
          await database.close();
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
