import '../data/local_media_store.dart';
import '../data/offline_database.dart';
import '../domain/repositories.dart';
import '../state/offline_demo_store.dart';

class OfflineEnvironment {
  const OfflineEnvironment({
    required this.database,
    required this.mediaStore,
    required this.repositories,
    required this.store,
  });

  final OfflineDatabase database;
  final LocalMediaStore mediaStore;
  final OfflineRepositoryBundle repositories;
  final OfflineDemoStore store;
}

abstract final class OfflineBootstrap {
  static Future<OfflineEnvironment> create() async {
    final database = await OfflineDatabase.open();
    try {
      final mediaStore = await LocalMediaStore.initialize();
      final repositories = OfflineRepositoryBundle(database);
      final store = OfflineDemoStore(repositories);
      await store.load();
      return OfflineEnvironment(
        database: database,
        mediaStore: mediaStore,
        repositories: repositories,
        store: store,
      );
    } catch (_) {
      await database.close();
      rethrow;
    }
  }
}
