import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'offline_schema.dart';
import 'offline_seed.dart';

class OfflineDatabase {
  OfflineDatabase._(this.connection, this.path);

  static const fileName = 'tui_offline_demo.db';

  final Database connection;
  final String path;

  static Future<OfflineDatabase> open({
    DatabaseFactory? factory,
    String? databasePath,
  }) async {
    final resolvedFactory = factory ?? databaseFactory;
    final resolvedPath =
        databasePath ?? p.join(await getDatabasesPath(), fileName);
    final db = await resolvedFactory.openDatabase(
      resolvedPath,
      options: OpenDatabaseOptions(
        version: OfflineSchema.version,
        singleInstance: true,
        onConfigure: (database) async {
          await database.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (database, version) => OfflineSchema.createV1(database),
        onUpgrade: OfflineSchema.migrate,
      ),
    );

    try {
      await OfflineSeed.ensureSeeded(db);
      return OfflineDatabase._(db, resolvedPath);
    } catch (_) {
      await db.close();
      rethrow;
    }
  }

  Future<void> close() => connection.close();
}
