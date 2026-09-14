import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/stoksync_database.dart';

const _legacyProductId = 'product-legacy';
const _legacyMovementId = 'movement-legacy-stocktake';
const _legacyOperationId = 'operation-legacy-conflict';
const _legacyNow = 1_789_287_734_000;

void main() {
  group('StokSyncDatabase migrations', () {
    test(
      'upgrades every previous schema version without losing local state',
      () async {
        for (final legacyVersion in [1, 2, 3, 4, 5]) {
          await _assertUpgradeFrom(legacyVersion);
        }
      },
    );

    test(
      'fresh databases use the current schema and migration metadata',
      () async {
        final database = StokSyncDatabase(NativeDatabase.memory());
        addTearDown(database.close);

        final version = await database
            .customSelect('PRAGMA user_version')
            .getSingle();

        expect(version.data.values.single, 6);
        expect(
          await database.select(database.syncState).getSingle(),
          isNotNull,
        );
      },
    );
  });
}

Future<void> _assertUpgradeFrom(int legacyVersion) async {
  final directory = await Directory.systemTemp.createTemp(
    'stoksync-drift-migration-$legacyVersion-',
  );
  final databaseFile = File(
    '${directory.path}${Platform.pathSeparator}replica.sqlite',
  );
  StokSyncDatabase? database;

  try {
    database = StokSyncDatabase(
      NativeDatabase(
        databaseFile,
        setup: (rawDatabase) {
          _createLegacySchema(rawDatabase, legacyVersion);
        },
      ),
    );

    final schemaVersion = await database
        .customSelect('PRAGMA user_version')
        .getSingle();
    expect(schemaVersion.data.values.single, 6);

    final product = await (database.select(
      database.products,
    )..where((row) => row.id.equals(_legacyProductId))).getSingle();
    expect(product.name, 'Legacy stock item');
    expect(product.barcode, 'legacy-barcode');
    expect(product.version, 4);
    expect(product.syncStatus, 'synced');

    final movement = await (database.select(
      database.stockMovements,
    )..where((row) => row.id.equals(_legacyMovementId))).getSingle();
    expect(movement.delta, 7);
    expect(movement.kind, 'stocktake');
    expect(movement.countedQty, 7);
    expect(movement.syncStatus, 'pending');

    final balance = await (database.select(
      database.productBalances,
    )..where((row) => row.productId.equals(_legacyProductId))).getSingle();
    expect(balance.qty, 7);

    final pending = await database
        .select(database.pendingOperations)
        .getSingle();
    expect(pending.opId, 'operation-legacy-stocktake');
    expect(pending.baseVersion, 4);
    expect(
      pending.basePayload,
      legacyVersion >= 4 ? '{"name":"Legacy stock item"}' : isNull,
    );

    final syncState = await database.select(database.syncState).getSingle();
    expect(syncState.cursor, 42);
    expect(syncState.bootstrapped, isTrue);
    expect(syncState.serverClockOffsetMs, -125);
    expect(syncState.status, legacyVersion >= 3 ? 'blocked' : 'idle');

    final conflict = await database.select(database.conflicts).getSingle();
    expect(conflict.opId, _legacyOperationId);
    expect(conflict.reason, 'barcode_conflict');
    expect(conflict.resolutionStatus, 'unresolved');

    final barcodeIndex = await database
        .customSelect(
          "SELECT sql FROM sqlite_master WHERE type = 'index' "
          "AND name = 'products_active_barcode_unique'",
        )
        .getSingle();
    expect(barcodeIndex.data['sql'], contains("sync_status <> 'conflict'"));

    // Version 5 changed this index so the rejected barcode contender can stay
    // local beside the canonical active product.
    await database
        .into(database.products)
        .insert(
          ProductsCompanion.insert(
            id: 'product-barcode-contender',
            barcode: const Value('legacy-barcode'),
            name: 'Rejected duplicate',
            updatedBy: 'device-legacy',
            updatedAt: Value(
              DateTime.fromMillisecondsSinceEpoch(_legacyNow, isUtc: true),
            ),
            createdAt: Value(
              DateTime.fromMillisecondsSinceEpoch(_legacyNow, isUtc: true),
            ),
            syncStatus: const Value('conflict'),
          ),
        );
    expect(
      await (database.select(
        database.products,
      )..where((row) => row.barcode.equals('legacy-barcode'))).get(),
      hasLength(3),
    );

    await expectLater(
      database
          .into(database.products)
          .insert(
            ProductsCompanion.insert(
              id: 'product-active-duplicate',
              barcode: const Value('legacy-barcode'),
              name: 'Active duplicate',
              updatedBy: 'device-legacy',
            ),
          ),
      throwsA(isA<Exception>()),
    );

    // Version 6 permits only the narrow pending-stocktake reconciliation
    // update; all other ledger fields remain immutable and deletions remain
    // forbidden.
    await database.customStatement(
      "UPDATE stock_movements SET delta = 8, sync_status = 'synced' "
      "WHERE id = '$_legacyMovementId'",
    );
    await database.customStatement(
      "UPDATE product_balances SET qty = 8 WHERE product_id = '$_legacyProductId'",
    );
    final reconciledMovement = await (database.select(
      database.stockMovements,
    )..where((row) => row.id.equals(_legacyMovementId))).getSingle();
    expect(reconciledMovement.delta, 8);
    expect(reconciledMovement.syncStatus, 'synced');

    await expectLater(
      database.customStatement(
        "UPDATE stock_movements SET delta = 9 WHERE id = '$_legacyMovementId'",
      ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      database.customStatement(
        "DELETE FROM stock_movements WHERE id = '$_legacyMovementId'",
      ),
      throwsA(isA<Exception>()),
    );
  } finally {
    await database?.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

void _createLegacySchema(dynamic database, int schemaVersion) {
  database.execute('PRAGMA foreign_keys = ON');
  database.execute('''
    CREATE TABLE products (
      id TEXT NOT NULL PRIMARY KEY,
      barcode TEXT,
      sku TEXT,
      name TEXT NOT NULL,
      description TEXT,
      unit TEXT NOT NULL DEFAULT 'pcs',
      category TEXT,
      min_stock INTEGER,
      version INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_by TEXT NOT NULL,
      deleted_at INTEGER,
      created_at INTEGER NOT NULL DEFAULT CURRENT_TIMESTAMP,
      sync_status TEXT NOT NULL DEFAULT 'pending',
      CHECK (length(trim(name)) > 0),
      CHECK (length(trim(unit)) > 0),
      CHECK (version >= 0)
    )
  ''');
  database.execute('''
    CREATE TABLE stock_movements (
      id TEXT NOT NULL PRIMARY KEY,
      product_id TEXT NOT NULL REFERENCES products (id),
      delta INTEGER NOT NULL,
      kind TEXT NOT NULL,
      note TEXT,
      occurred_at INTEGER NOT NULL,
      raw_occurred_at INTEGER NOT NULL,
      clock_offset_ms INTEGER NOT NULL DEFAULT 0,
      counted_qty INTEGER,
      reverses_id TEXT REFERENCES stock_movements (id),
      device_id TEXT NOT NULL,
      server_created_at INTEGER,
      sync_status TEXT NOT NULL DEFAULT 'pending',
      CHECK (delta <> 0),
      CHECK (kind IN ('receive', 'issue', 'adjust', 'stocktake')),
      CHECK ((kind = 'stocktake' AND counted_qty IS NOT NULL) OR
        (kind <> 'stocktake' AND counted_qty IS NULL)),
      CHECK (reverses_id IS NULL OR kind = 'adjust')
    )
  ''');
  database.execute('''
    CREATE TABLE product_balances (
      product_id TEXT NOT NULL PRIMARY KEY REFERENCES products (id),
      qty INTEGER NOT NULL DEFAULT 0,
      last_movement_at INTEGER,
      updated_at INTEGER NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  ''');

  final basePayloadColumn = schemaVersion >= 4 ? ', base_payload TEXT' : '';
  database.execute('''
    CREATE TABLE pending_ops (
      op_id TEXT NOT NULL PRIMARY KEY,
      local_seq INTEGER NOT NULL UNIQUE,
      entity TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      op TEXT NOT NULL,
      payload TEXT NOT NULL$basePayloadColumn,
      base_version INTEGER,
      attempts INTEGER NOT NULL DEFAULT 0,
      next_attempt_at INTEGER NOT NULL DEFAULT CURRENT_TIMESTAMP,
      last_error TEXT,
      status TEXT NOT NULL DEFAULT 'queued',
      CHECK (local_seq > 0),
      CHECK (attempts >= 0),
      CHECK (length(trim(entity)) > 0),
      CHECK (length(trim(entity_id)) > 0),
      CHECK (length(trim(op)) > 0)
    )
  ''');

  final statusColumn = schemaVersion >= 3
      ? ', status TEXT NOT NULL DEFAULT \'idle\''
      : '';
  final serverOffsetColumn = schemaVersion >= 3
      ? ', server_clock_offset_ms INTEGER NOT NULL DEFAULT 0'
      : ', server_clock_offset_ms INTEGER NOT NULL DEFAULT 0';
  database.execute('''
    CREATE TABLE sync_state (
      id INTEGER NOT NULL PRIMARY KEY DEFAULT 1,
      cursor INTEGER NOT NULL DEFAULT 0,
      bootstrapped INTEGER NOT NULL DEFAULT 0,
      last_sync_at INTEGER,
      last_error TEXT$statusColumn$serverOffsetColumn,
      CHECK (id = 1),
      CHECK (cursor >= 0)
    )
  ''');
  database.execute('''
    CREATE TABLE conflicts (
      op_id TEXT NOT NULL PRIMARY KEY,
      entity TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      local_payload TEXT NOT NULL,
      base_payload TEXT,
      server_payload TEXT,
      reason TEXT NOT NULL,
      created_at INTEGER NOT NULL DEFAULT CURRENT_TIMESTAMP,
      resolution_status TEXT NOT NULL DEFAULT 'unresolved',
      CHECK (length(trim(entity)) > 0),
      CHECK (length(trim(entity_id)) > 0),
      CHECK (length(trim(reason)) > 0)
    )
  ''');

  database.execute('''
    CREATE UNIQUE INDEX products_active_barcode_unique
      ON products (barcode)
      WHERE barcode IS NOT NULL AND deleted_at IS NULL
  ''');
  if (schemaVersion >= 2) {
    database.execute('''
      CREATE TRIGGER stock_movements_prevent_domain_update
      BEFORE UPDATE OF id, product_id, delta, kind, note, occurred_at,
        raw_occurred_at, clock_offset_ms, counted_qty, reverses_id, device_id
      ON stock_movements
      BEGIN
        SELECT RAISE(ABORT, 'stock movement ledger fields are immutable');
      END
    ''');
  }

  database.execute('''
    INSERT INTO products (
      id, barcode, name, unit, version, updated_at, updated_by, created_at,
      sync_status
    ) VALUES (
      '$_legacyProductId', 'legacy-barcode', 'Legacy stock item', 'pcs', 4,
      $_legacyNow, 'device-legacy', $_legacyNow, 'synced'
    )
  ''');
  database.execute('''
    INSERT INTO products (
      id, barcode, name, unit, version, updated_at, updated_by, deleted_at,
      created_at, sync_status
    ) VALUES (
      'product-legacy-tombstone', 'legacy-barcode', 'Deleted legacy item',
      'pcs', 2, $_legacyNow, 'device-legacy', $_legacyNow, $_legacyNow, 'synced'
    )
  ''');
  database.execute('''
    INSERT INTO stock_movements (
      id, product_id, delta, kind, occurred_at, raw_occurred_at,
      clock_offset_ms, counted_qty, device_id, server_created_at, sync_status
    ) VALUES (
      '$_legacyMovementId', '$_legacyProductId', 7, 'stocktake', $_legacyNow,
      $_legacyNow, -125, 7, 'device-legacy', $_legacyNow, 'pending'
    )
  ''');
  database.execute('''
    INSERT INTO product_balances (
      product_id, qty, last_movement_at, updated_at
    ) VALUES ('$_legacyProductId', 7, $_legacyNow, $_legacyNow)
  ''');
  final pendingColumns = schemaVersion >= 4
      ? 'op_id, local_seq, entity, entity_id, op, payload, base_payload, '
            'base_version, next_attempt_at, status'
      : 'op_id, local_seq, entity, entity_id, op, payload, base_version, '
            'next_attempt_at, status';
  final pendingValues = schemaVersion >= 4
      ? "'operation-legacy-stocktake', 1, 'stock_movement', "
            "'$_legacyMovementId', 'add_movement', '{\"id\":\"$_legacyMovementId\"}', "
            "'{\"name\":\"Legacy stock item\"}', 4, $_legacyNow, 'queued'"
      : "'operation-legacy-stocktake', 1, 'stock_movement', "
            "'$_legacyMovementId', 'add_movement', '{\"id\":\"$_legacyMovementId\"}', "
            "4, $_legacyNow, 'queued'";
  database.execute(
    'INSERT INTO pending_ops ($pendingColumns) VALUES ($pendingValues)',
  );
  final syncStateColumns = schemaVersion >= 3
      ? 'id, cursor, bootstrapped, last_sync_at, last_error, status, '
            'server_clock_offset_ms'
      : 'id, cursor, bootstrapped, last_sync_at, last_error, '
            'server_clock_offset_ms';
  final syncStateValues = schemaVersion >= 3
      ? "1, 42, 1, $_legacyNow, 'legacy blocked', 'blocked', -125"
      : "1, 42, 1, $_legacyNow, 'legacy blocked', -125";
  database.execute(
    'INSERT INTO sync_state ($syncStateColumns) VALUES ($syncStateValues)',
  );
  database.execute('''
    INSERT INTO conflicts (
      op_id, entity, entity_id, local_payload, base_payload, server_payload,
      reason, created_at, resolution_status
    ) VALUES (
      '$_legacyOperationId', 'product', '$_legacyProductId',
      '{"barcode":"legacy-barcode"}', '{"barcode":"legacy-barcode"}',
      '{"id":"$_legacyProductId"}', 'barcode_conflict', $_legacyNow, 'unresolved'
    )
  ''');

  database.execute('PRAGMA user_version = $schemaVersion');
}
