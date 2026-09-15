import 'package:sqflite/sqflite.dart';

abstract final class WeComOverlaySchema {
  static const version = 4;

  static const operationsTable = 'overlay_operations';
  static const mergeAttemptsTable = 'overlay_merge_attempts';
  static const mergeConflictsTable = 'overlay_merge_conflicts';
  static const datasetActivationsTable = 'overlay_dataset_activations';

  static const targetIndex = 'idx_overlay_operations_target';
  static const mergeIdentityIndex = 'idx_overlay_merge_attempts_identity';
  static const conflictAttemptIndex = 'idx_overlay_merge_conflicts_attempt';

  static const noUpdateTrigger = 'trg_overlay_operations_no_update';
  static const noDeleteTrigger = 'trg_overlay_operations_no_delete';
  static const identityRequiredTrigger =
      'trg_overlay_operations_identity_required';
  static const mergeAttemptNoUpdateTrigger =
      'trg_overlay_merge_attempts_no_update';
  static const mergeAttemptNoDeleteTrigger =
      'trg_overlay_merge_attempts_no_delete';
  static const mergeAttemptIdentityRequiredTrigger =
      'trg_overlay_merge_attempts_identity_required';
  static const mergeConflictNoUpdateTrigger =
      'trg_overlay_merge_conflicts_no_update';
  static const mergeConflictNoDeleteTrigger =
      'trg_overlay_merge_conflicts_no_delete';
  static const activationNoUpdateTrigger =
      'trg_overlay_dataset_activations_no_update';
  static const activationNoDeleteTrigger =
      'trg_overlay_dataset_activations_no_delete';

  static const expectedTables = <String>[
    datasetActivationsTable,
    mergeAttemptsTable,
    mergeConflictsTable,
    operationsTable,
  ];
  static const expectedIndexes = <String>[
    mergeIdentityIndex,
    conflictAttemptIndex,
    targetIndex,
  ];
  static const expectedTriggers = <String>[
    activationNoDeleteTrigger,
    activationNoUpdateTrigger,
    mergeAttemptIdentityRequiredTrigger,
    mergeAttemptNoDeleteTrigger,
    mergeAttemptNoUpdateTrigger,
    mergeConflictNoDeleteTrigger,
    mergeConflictNoUpdateTrigger,
    identityRequiredTrigger,
    noDeleteTrigger,
    noUpdateTrigger,
  ];

  static const version1CreateStatements = <String>[
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

  static const version2CreateStatements = <String>[
    '''
CREATE TABLE overlay_merge_attempts (
  merge_id INTEGER PRIMARY KEY,
  old_dataset_id TEXT NOT NULL
    CHECK (
      length(old_dataset_id) = 64 AND
      old_dataset_id NOT GLOB '*[^0-9a-f]*'
    ),
  new_dataset_id TEXT NOT NULL
    CHECK (
      length(new_dataset_id) = 64 AND
      new_dataset_id NOT GLOB '*[^0-9a-f]*'
    ),
  source_revision_count INTEGER NOT NULL
    CHECK (source_revision_count >= 0),
  status TEXT NOT NULL CHECK (status IN ('applied', 'conflicted')),
  first_applied_revision_id INTEGER
    REFERENCES overlay_operations(revision_id) ON DELETE RESTRICT,
  last_applied_revision_id INTEGER
    REFERENCES overlay_operations(revision_id) ON DELETE RESTRICT,
  conflict_count INTEGER NOT NULL CHECK (conflict_count >= 0),
  created_at_micros INTEGER NOT NULL CHECK (created_at_micros > 0),
  CHECK (old_dataset_id <> new_dataset_id),
  CHECK (
    (status = 'applied' AND conflict_count = 0) OR
    (status = 'conflicted' AND conflict_count > 0)
  ),
  CHECK (
    (
      first_applied_revision_id IS NULL AND
      last_applied_revision_id IS NULL
    ) OR (
      first_applied_revision_id IS NOT NULL AND
      last_applied_revision_id IS NOT NULL AND
      first_applied_revision_id <= last_applied_revision_id
    )
  ),
  CHECK (
    status = 'applied' OR (
      first_applied_revision_id IS NULL AND
      last_applied_revision_id IS NULL
    )
  )
)
''',
    '''
CREATE UNIQUE INDEX idx_overlay_merge_attempts_identity
ON overlay_merge_attempts (
  old_dataset_id,
  new_dataset_id,
  source_revision_count
)
''',
    '''
CREATE TABLE overlay_merge_conflicts (
  conflict_id INTEGER PRIMARY KEY,
  merge_id INTEGER NOT NULL
    REFERENCES overlay_merge_attempts(merge_id) ON DELETE RESTRICT,
  database_name TEXT NOT NULL CHECK (length(database_name) > 0),
  table_name TEXT NOT NULL CHECK (length(table_name) > 0),
  row_key_json TEXT NOT NULL CHECK (length(row_key_json) > 0),
  kind TEXT NOT NULL CHECK (
    kind IN (
      'baseFingerprintMismatch',
      'concurrentInsert',
      'remoteDelete',
      'localDeleteRemoteUpdate',
      'localReplaceRemoteUpdate',
      'fieldUpdate'
    )
  ),
  source_revision_ids_json TEXT NOT NULL
    CHECK (length(source_revision_ids_json) > 0),
  conflicting_columns_json TEXT NOT NULL
    CHECK (length(conflicting_columns_json) > 0),
  old_base_row_sha256 TEXT NOT NULL
    CHECK (
      length(old_base_row_sha256) = 64 AND
      old_base_row_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
  new_base_row_sha256 TEXT NOT NULL
    CHECK (
      length(new_base_row_sha256) = 64 AND
      new_base_row_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
  created_at_micros INTEGER NOT NULL CHECK (created_at_micros > 0)
)
''',
    '''
CREATE INDEX idx_overlay_merge_conflicts_attempt
ON overlay_merge_conflicts (merge_id, conflict_id)
''',
    '''
CREATE TABLE overlay_dataset_activations (
  activation_id INTEGER PRIMARY KEY,
  previous_dataset_id TEXT
    CHECK (
      previous_dataset_id IS NULL OR (
        length(previous_dataset_id) = 64 AND
        previous_dataset_id NOT GLOB '*[^0-9a-f]*'
      )
    ),
  dataset_id TEXT NOT NULL
    CHECK (
      length(dataset_id) = 64 AND
      dataset_id NOT GLOB '*[^0-9a-f]*'
    ),
  merge_id INTEGER UNIQUE
    REFERENCES overlay_merge_attempts(merge_id) ON DELETE RESTRICT,
  created_at_micros INTEGER NOT NULL CHECK (created_at_micros > 0),
  CHECK (
    (previous_dataset_id IS NULL AND merge_id IS NULL) OR (
      previous_dataset_id IS NOT NULL AND
      merge_id IS NOT NULL AND
      previous_dataset_id <> dataset_id
    )
  )
)
''',
    '''
CREATE TRIGGER trg_overlay_merge_attempts_no_update
BEFORE UPDATE ON overlay_merge_attempts
BEGIN
  SELECT RAISE(ABORT, 'overlay merge attempts are append-only');
END
''',
    '''
CREATE TRIGGER trg_overlay_merge_attempts_no_delete
BEFORE DELETE ON overlay_merge_attempts
BEGIN
  SELECT RAISE(ABORT, 'overlay merge attempts are append-only');
END
''',
    '''
CREATE TRIGGER trg_overlay_merge_conflicts_no_update
BEFORE UPDATE ON overlay_merge_conflicts
BEGIN
  SELECT RAISE(ABORT, 'overlay merge conflicts are append-only');
END
''',
    '''
CREATE TRIGGER trg_overlay_merge_conflicts_no_delete
BEFORE DELETE ON overlay_merge_conflicts
BEGIN
  SELECT RAISE(ABORT, 'overlay merge conflicts are append-only');
END
''',
    '''
CREATE TRIGGER trg_overlay_dataset_activations_no_update
BEFORE UPDATE ON overlay_dataset_activations
BEGIN
  SELECT RAISE(ABORT, 'overlay dataset activations are append-only');
END
''',
    '''
CREATE TRIGGER trg_overlay_dataset_activations_no_delete
BEFORE DELETE ON overlay_dataset_activations
BEGIN
  SELECT RAISE(ABORT, 'overlay dataset activations are append-only');
END
''',
  ];

  static const version3UpgradeStatements = <String>[
    'DROP TRIGGER IF EXISTS trg_overlay_dataset_activations_no_update',
    'DROP TRIGGER IF EXISTS trg_overlay_dataset_activations_no_delete',
    '''
ALTER TABLE overlay_dataset_activations
RENAME TO overlay_dataset_activations_v2
''',
    '''
CREATE TABLE overlay_dataset_activations (
  activation_id INTEGER PRIMARY KEY,
  previous_dataset_id TEXT
    CHECK (
      previous_dataset_id IS NULL OR (
        length(previous_dataset_id) = 64 AND
        previous_dataset_id NOT GLOB '*[^0-9a-f]*'
      )
    ),
  dataset_id TEXT NOT NULL
    CHECK (
      length(dataset_id) = 64 AND
      dataset_id NOT GLOB '*[^0-9a-f]*'
    ),
  merge_id INTEGER UNIQUE
    REFERENCES overlay_merge_attempts(merge_id) ON DELETE RESTRICT,
  current_corp_id INTEGER CHECK (current_corp_id > 0),
  current_user_id INTEGER CHECK (current_user_id > 0),
  created_at_micros INTEGER NOT NULL CHECK (created_at_micros > 0),
  CHECK (
    (current_corp_id IS NULL AND current_user_id IS NULL) OR
    (current_corp_id IS NOT NULL AND current_user_id IS NOT NULL)
  ),
  CHECK (
    (previous_dataset_id IS NULL AND merge_id IS NULL) OR
    (
      previous_dataset_id IS NOT NULL AND
      (
        (merge_id IS NOT NULL AND previous_dataset_id <> dataset_id) OR
        (merge_id IS NULL AND previous_dataset_id = dataset_id)
      )
    )
  )
)
''',
    '''
INSERT INTO overlay_dataset_activations (
  activation_id,
  previous_dataset_id,
  dataset_id,
  merge_id,
  current_corp_id,
  current_user_id,
  created_at_micros
)
SELECT
  activation_id,
  previous_dataset_id,
  dataset_id,
  merge_id,
  NULL,
  NULL,
  created_at_micros
FROM overlay_dataset_activations_v2
''',
    'DROP TABLE overlay_dataset_activations_v2',
    '''
CREATE TRIGGER trg_overlay_dataset_activations_no_update
BEFORE UPDATE ON overlay_dataset_activations
BEGIN
  SELECT RAISE(ABORT, 'dataset activations are append-only');
END
''',
    '''
CREATE TRIGGER trg_overlay_dataset_activations_no_delete
BEFORE DELETE ON overlay_dataset_activations
BEGIN
  SELECT RAISE(ABORT, 'dataset activations are append-only');
END
''',
  ];

  static const version4UpgradeStatements = <String>[
    'DROP TRIGGER IF EXISTS trg_overlay_operations_no_update',
    'DROP TRIGGER IF EXISTS trg_overlay_merge_attempts_no_update',
    '''
ALTER TABLE overlay_operations
ADD COLUMN identity_corp_id INTEGER CHECK (identity_corp_id > 0)
''',
    '''
ALTER TABLE overlay_operations
ADD COLUMN identity_user_id INTEGER CHECK (identity_user_id > 0)
''',
    '''
UPDATE overlay_operations
SET
  identity_corp_id = (
    SELECT MIN(current_corp_id)
    FROM overlay_dataset_activations
    WHERE dataset_id = overlay_operations.dataset_id
      AND current_corp_id IS NOT NULL
      AND current_user_id IS NOT NULL
  ),
  identity_user_id = (
    SELECT MIN(current_user_id)
    FROM overlay_dataset_activations
    WHERE dataset_id = overlay_operations.dataset_id
      AND current_corp_id IS NOT NULL
      AND current_user_id IS NOT NULL
  )
WHERE 1 = (
  SELECT COUNT(DISTINCT current_corp_id || ':' || current_user_id)
  FROM overlay_dataset_activations
  WHERE dataset_id = overlay_operations.dataset_id
    AND current_corp_id IS NOT NULL
    AND current_user_id IS NOT NULL
)
''',
    'DROP INDEX idx_overlay_operations_target',
    '''
CREATE INDEX idx_overlay_operations_target
ON overlay_operations (
  dataset_id,
  identity_corp_id,
  identity_user_id,
  database_name,
  table_name,
  row_key_json,
  revision_id
)
''',
    '''
ALTER TABLE overlay_merge_attempts
ADD COLUMN identity_corp_id INTEGER CHECK (identity_corp_id > 0)
''',
    '''
ALTER TABLE overlay_merge_attempts
ADD COLUMN identity_user_id INTEGER CHECK (identity_user_id > 0)
''',
    '''
UPDATE overlay_merge_attempts
SET
  identity_corp_id = (
    SELECT current_corp_id
    FROM overlay_dataset_activations
    WHERE merge_id = overlay_merge_attempts.merge_id
    LIMIT 1
  ),
  identity_user_id = (
    SELECT current_user_id
    FROM overlay_dataset_activations
    WHERE merge_id = overlay_merge_attempts.merge_id
    LIMIT 1
  )
WHERE EXISTS (
  SELECT 1
  FROM overlay_dataset_activations
  WHERE merge_id = overlay_merge_attempts.merge_id
    AND current_corp_id IS NOT NULL
    AND current_user_id IS NOT NULL
)
''',
    '''
UPDATE overlay_merge_attempts
SET
  identity_corp_id = (
    SELECT MIN(current_corp_id)
    FROM overlay_dataset_activations
    WHERE dataset_id = overlay_merge_attempts.old_dataset_id
      AND current_corp_id IS NOT NULL
      AND current_user_id IS NOT NULL
  ),
  identity_user_id = (
    SELECT MIN(current_user_id)
    FROM overlay_dataset_activations
    WHERE dataset_id = overlay_merge_attempts.old_dataset_id
      AND current_corp_id IS NOT NULL
      AND current_user_id IS NOT NULL
  )
WHERE identity_corp_id IS NULL
  AND 1 = (
    SELECT COUNT(DISTINCT current_corp_id || ':' || current_user_id)
    FROM overlay_dataset_activations
    WHERE dataset_id = overlay_merge_attempts.old_dataset_id
      AND current_corp_id IS NOT NULL
      AND current_user_id IS NOT NULL
  )
''',
    'DROP INDEX idx_overlay_merge_attempts_identity',
    '''
CREATE UNIQUE INDEX idx_overlay_merge_attempts_identity
ON overlay_merge_attempts (
  identity_corp_id,
  identity_user_id,
  old_dataset_id,
  new_dataset_id,
  source_revision_count
)
''',
    '''
CREATE TRIGGER trg_overlay_operations_identity_required
BEFORE INSERT ON overlay_operations
WHEN NEW.identity_corp_id IS NULL OR NEW.identity_user_id IS NULL
BEGIN
  SELECT RAISE(ABORT, 'overlay operations require an identity');
END
''',
    '''
CREATE TRIGGER trg_overlay_merge_attempts_identity_required
BEFORE INSERT ON overlay_merge_attempts
WHEN NEW.identity_corp_id IS NULL OR NEW.identity_user_id IS NULL
BEGIN
  SELECT RAISE(ABORT, 'overlay merge attempts require an identity');
END
''',
    '''
CREATE TRIGGER trg_overlay_operations_no_update
BEFORE UPDATE ON overlay_operations
BEGIN
  SELECT RAISE(ABORT, 'overlay operations are append-only');
END
''',
    '''
CREATE TRIGGER trg_overlay_merge_attempts_no_update
BEFORE UPDATE ON overlay_merge_attempts
BEGIN
  SELECT RAISE(ABORT, 'overlay merge attempts are append-only');
END
''',
  ];

  static const createStatements = <String>[
    ...version1CreateStatements,
    ...version2CreateStatements,
    ...version3UpgradeStatements,
    ...version4UpgradeStatements,
  ];

  static Future<void> createCurrent(Database db) {
    return _execute(db, createStatements);
  }

  static Future<void> createVersion1(Database db) {
    return _execute(db, version1CreateStatements);
  }

  static Future<void> upgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) {
    if (newVersion == version && oldVersion == 1) {
      return _execute(db, [
        ...version2CreateStatements,
        ...version3UpgradeStatements,
        ...version4UpgradeStatements,
      ]);
    }
    if (newVersion == version && oldVersion == 2) {
      return _execute(db, [
        ...version3UpgradeStatements,
        ...version4UpgradeStatements,
      ]);
    }
    if (newVersion == version && oldVersion == 3) {
      return _execute(db, version4UpgradeStatements);
    }
    throw StateError(
      'Unsupported overlay schema upgrade: $oldVersion -> $newVersion',
    );
  }

  static Future<void> _execute(
    Database db,
    List<String> statements,
  ) async {
    final batch = db.batch();
    for (final statement in statements) {
      batch.execute(statement);
    }
    await batch.commit(noResult: true);
  }
}
