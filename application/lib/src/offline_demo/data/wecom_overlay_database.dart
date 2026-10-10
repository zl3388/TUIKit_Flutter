import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'wecom_overlay_schema.dart';

class WeComOverlayDatabase {
  WeComOverlayDatabase._(this.connection, this.path, this.sceneId,
      {bool ownsConnection = true})
      : _ownsConnection = ownsConnection;

  static const fileName = 'overlay.db';

  final Database connection;
  final String path;
  final String sceneId;
  final bool _ownsConnection;

  WeComOverlayDatabase forScene(String sceneId) =>
      WeComOverlayDatabase._(connection, path, sceneId, ownsConnection: false);

  static Future<WeComOverlayDatabase> open({
    DatabaseFactory? factory,
    String? databasePath,
    String? sceneId,
  }) async {
    final resolvedFactory = factory ?? databaseFactory;
    final resolvedPath =
        databasePath ?? p.join(await getDatabasesPath(), fileName);
    final db = await resolvedFactory.openDatabase(
      resolvedPath,
      options: OpenDatabaseOptions(
        version: WeComOverlaySchema.version,
        singleInstance: true,
        onConfigure: (database) async {
          final oldVersion = await database.getVersion();
          // SQLite cannot drop the v5/v6 self-referencing event table with
          // immediate RESTRICT foreign keys enabled during its rebuild.
          await database.execute(
            'PRAGMA foreign_keys = ${oldVersion == 5 || oldVersion == 6 ? 'OFF' : 'ON'}',
          );
        },
        onCreate: (database, version) =>
            WeComOverlaySchema.createCurrent(database),
        onUpgrade: WeComOverlaySchema.upgrade,
        onOpen: (database) async {
          await database.execute('PRAGMA foreign_keys = ON');
          final violations =
              await database.rawQuery('PRAGMA foreign_key_check');
          if (violations.isNotEmpty) {
            throw StateError('Overlay foreign key check failed after upgrade.');
          }
        },
      ),
    );

    final activations = await db.query(
      WeComOverlaySchema.datasetActivationsTable,
      columns: ['scene_id'],
      orderBy: 'activation_id DESC',
      limit: 1,
    );
    return WeComOverlayDatabase._(
      db,
      resolvedPath,
      sceneId ?? (activations.firstOrNull?['scene_id'] as String? ?? 'default'),
    );
  }

  Future<void> close() async {
    if (_ownsConnection) await connection.close();
  }
}
