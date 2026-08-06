import 'package:sqflite/sqflite.dart';

abstract final class WeComOverlaySchema {
  static const version = 1;

  static const operationsTable = 'overlay_operations';
  static const targetIndex = 'idx_overlay_operations_target';
  static const noUpdateTrigger = 'trg_overlay_operations_no_update';
  static const noDeleteTrigger = 'trg_overlay_operations_no_delete';

  static const expectedTables = <String>[operationsTable];
  static const expectedIndexes = <String>[targetIndex];
  static const expectedTriggers = <String>[
    noDeleteTrigger,
    noUpdateTrigger,
  ];

  static const createStatements = <String>[
    '''
CREATE TABLE overlay_operations (
  revision_id INTEGER PRIMARY KEY,
  dataset_id TEXT NOT NULL
    CHECK (
      length(dataset_id) = 64 AND
      dataset_id NOT GLOB '*[^0-9a-f]*'
    ),
  database_name TEXT NOT NULL CHECK (length(database_name) > 0),
  table_name TEXT NOT NULL CHECK (length(table_name) > 0),
  row_key_json TEXT NOT NULL CHECK (length(row_key_json) > 0),
  operation TEXT NOT NULL CHECK (operation IN ('upsert', 'tombstone')),
  values_json TEXT,
  base_row_sha256 TEXT
    CHECK (
      base_row_sha256 IS NULL OR (
        length(base_row_sha256) = 64 AND
        base_row_sha256 NOT GLOB '*[^0-9a-f]*'
      )
    ),
  reverts_revision_id INTEGER
    REFERENCES overlay_operations(revision_id) ON DELETE RESTRICT,
  created_at_micros INTEGER NOT NULL CHECK (created_at_micros > 0),
  CHECK (
    (operation = 'upsert' AND values_json IS NOT NULL) OR
    (operation = 'tombstone' AND values_json IS NULL)
  ),
  CHECK (
    reverts_revision_id IS NULL OR
    reverts_revision_id < revision_id
  )
)
''',
    '''
CREATE INDEX idx_overlay_operations_target
ON overlay_operations (
  dataset_id,
  database_name,
  table_name,
  row_key_json,
  revision_id
)
''',
    '''
CREATE TRIGGER trg_overlay_operations_no_update
BEFORE UPDATE ON overlay_operations
BEGIN
  SELECT RAISE(ABORT, 'overlay operations are append-only');
END
''',
    '''
CREATE TRIGGER trg_overlay_operations_no_delete
BEFORE DELETE ON overlay_operations
BEGIN
  SELECT RAISE(ABORT, 'overlay operations are append-only');
END
''',
  ];

  static Future<void> createCurrent(Database db) async {
    final batch = db.batch();
    for (final statement in createStatements) {
      batch.execute(statement);
    }
    await batch.commit(noResult: true);
  }
}
