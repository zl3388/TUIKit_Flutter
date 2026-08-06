import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'wecom_overlay_schema.dart';

class WeComOverlayDatabase {
  WeComOverlayDatabase._(this.connection, this.path);

  static const fileName = 'overlay.db';

  final Database connection;
  final String path;

  static Future<WeComOverlayDatabase> open({
    DatabaseFactory? factory,
    String? databasePath,
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
          await database.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (database, version) =>
            WeComOverlaySchema.createCurrent(database),
      ),
    );

    return WeComOverlayDatabase._(db, resolvedPath);
  }

  Future<void> close() => connection.close();
}
