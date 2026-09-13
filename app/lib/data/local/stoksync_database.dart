import 'package:drift/drift.dart';

part 'stoksync_database.g.dart';

/// The locally replicated product catalog.
class Products extends Table {
  @override
  Set<Column<Object>> get primaryKey => {id};

  TextColumn get id => text()();
  TextColumn get barcode => text().nullable()();
  TextColumn get sku => text().nullable()();
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();
  TextColumn get unit => text().withDefault(const Constant('pcs'))();
  TextColumn get category => text().nullable()();
  IntColumn get minStock => integer().nullable()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  TextColumn get updatedBy => text()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  TextColumn get syncStatus => text().withDefault(const Constant('pending'))();

  @override
  List<String> get customConstraints => [
    'CHECK (length(trim(name)) > 0)',
    'CHECK (length(trim(unit)) > 0)',
    'CHECK (version >= 0)',
  ];
}

/// Immutable, signed ledger rows from which balances can be rebuilt.
class StockMovements extends Table {
  @override
  Set<Column<Object>> get primaryKey => {id};

  TextColumn get id => text()();
  TextColumn get productId => text().references(Products, #id)();
  IntColumn get delta => integer()();
  TextColumn get kind => text()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get occurredAt => dateTime()();
  DateTimeColumn get rawOccurredAt => dateTime()();
  IntColumn get clockOffsetMs => integer().withDefault(const Constant(0))();
  IntColumn get countedQty => integer().nullable()();
  TextColumn get reversesId =>
      text().nullable().references(StockMovements, #id)();
  TextColumn get deviceId => text()();
  DateTimeColumn get serverCreatedAt => dateTime().nullable()();
  TextColumn get syncStatus => text().withDefault(const Constant('pending'))();

  @override
  List<String> get customConstraints => [
    'CHECK (delta <> 0)',
    "CHECK (kind IN ('receive', 'issue', 'adjust', 'stocktake'))",
    "CHECK ((kind = 'stocktake' AND counted_qty IS NOT NULL) OR "
        "(kind <> 'stocktake' AND counted_qty IS NULL))",
    "CHECK (reverses_id IS NULL OR kind = 'adjust')",
  ];
}

/// Rebuildable query projection of the immutable stock movement ledger.
class ProductBalances extends Table {
  @override
  Set<Column<Object>> get primaryKey => {productId};

  TextColumn get productId => text().references(Products, #id)();
  IntColumn get qty => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastMovementAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// Durable FIFO synchronization work, committed with its local domain mutation.
class PendingOperations extends Table {
  @override
  String get tableName => 'pending_ops';

  @override
  Set<Column<Object>> get primaryKey => {opId};

  TextColumn get opId => text()();
  IntColumn get localSeq => integer().unique()();
  TextColumn get entity => text()();
  TextColumn get entityId => text()();
  TextColumn get operation => text().named('op')();
  TextColumn get payload => text()();
  IntColumn get baseVersion => integer().nullable()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextAttemptAt =>
      dateTime().withDefault(currentDateAndTime)();
  TextColumn get lastError => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('queued'))();

  @override
  List<String> get customConstraints => [
    'CHECK (local_seq > 0)',
    'CHECK (attempts >= 0)',
    'CHECK (length(trim(entity)) > 0)',
    'CHECK (length(trim(entity_id)) > 0)',
    'CHECK (length(trim(op)) > 0)',
  ];
}

/// Singleton durable metadata for bootstrap progress and incremental pull state.
class SyncState extends Table {
  @override
  String get tableName => 'sync_state';

  @override
  Set<Column<Object>> get primaryKey => {id};

  IntColumn get id => integer().withDefault(const Constant(1))();
  IntColumn get cursor => integer().withDefault(const Constant(0))();
  BoolColumn get bootstrapped => boolean().withDefault(const Constant(false))();
  DateTimeColumn get lastSyncAt => dateTime().nullable()();
  TextColumn get lastError => text().nullable()();
  IntColumn get serverClockOffsetMs =>
      integer().withDefault(const Constant(0))();

  @override
  List<String> get customConstraints => [
    'CHECK (id = 1)',
    'CHECK (cursor >= 0)',
  ];
}

/// User-visible local intent retained for rejected or unresolved operations.
class Conflicts extends Table {
  @override
  Set<Column<Object>> get primaryKey => {opId};

  TextColumn get opId => text()();
  TextColumn get entity => text()();
  TextColumn get entityId => text()();
  TextColumn get localPayload => text()();
  TextColumn get basePayload => text().nullable()();
  TextColumn get serverPayload => text().nullable()();
  TextColumn get reason => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  TextColumn get resolutionStatus =>
      text().withDefault(const Constant('unresolved'))();

  @override
  List<String> get customConstraints => [
    'CHECK (length(trim(entity)) > 0)',
    'CHECK (length(trim(entity_id)) > 0)',
    'CHECK (length(trim(reason)) > 0)',
  ];
}

/// The local SQLite replica schema.
///
/// Schema version 1 establishes the complete local-first data model. Later
/// versions must add explicit migration steps in [migration.onUpgrade] rather
/// than replacing the database, preserving queued operations and audit data.
@DriftDatabase(
  tables: [
    Products,
    StockMovements,
    ProductBalances,
    PendingOperations,
    SyncState,
    Conflicts,
  ],
)
class StokSyncDatabase extends _$StokSyncDatabase {
  StokSyncDatabase(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await migrator.createAll();
      await _createIndexes();
      await _ensureSyncState();
    },
    onUpgrade: (migrator, from, to) async {
      // Version 1 is the initial schema. Keep this hook explicit so each
      // subsequent schema version adds a data-preserving upgrade step here.
      await _createIndexes();
      await _ensureSyncState();
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  Future<void> _createIndexes() async {
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS products_active_barcode_unique '
      'ON products (barcode) '
      'WHERE barcode IS NOT NULL AND deleted_at IS NULL',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS products_active_name_index '
      'ON products (deleted_at, name)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS stock_movements_product_occurred_at_index '
      'ON stock_movements (product_id, occurred_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS pending_ops_due_index '
      'ON pending_ops (status, next_attempt_at, local_seq)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS conflicts_unresolved_index '
      'ON conflicts (resolution_status, created_at)',
    );
  }

  Future<void> _ensureSyncState() {
    return customStatement(
      'INSERT OR IGNORE INTO sync_state '
      '(id, cursor, bootstrapped, server_clock_offset_ms) VALUES (1, 0, 0, 0)',
    );
  }
}
