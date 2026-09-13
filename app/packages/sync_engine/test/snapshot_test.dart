import 'dart:convert';

import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

void main() {
  test('decodes the versioned server snapshot shape including tombstones', () {
    final decoded = SnapshotResponse.fromJsonString(
      jsonEncode(<String, Object?>{
        'schema_version': 1,
        'products': [
          <String, Object?>{
            'id': _activeProductId,
            'barcode': '089686010947',
            'sku': null,
            'name': 'Active product',
            'description': null,
            'unit': 'pcs',
            'category': 'food',
            'min_stock': 24,
            'version': 3,
            'updated_at': '2026-09-13T10:00:00Z',
            'updated_by_device_id': _deviceId,
            'deleted_at': null,
            'created_at': '2026-09-13T09:00:00Z',
          },
          <String, Object?>{
            'id': _deletedProductId,
            'barcode': null,
            'sku': null,
            'name': 'Deleted product',
            'description': null,
            'unit': 'pcs',
            'category': null,
            'min_stock': null,
            'version': 4,
            'updated_at': '2026-09-13T10:01:00Z',
            'updated_by_device_id': _deviceId,
            'deleted_at': '2026-09-13T10:01:00Z',
            'created_at': '2026-09-13T09:00:00Z',
          },
        ],
        'movements': [
          <String, Object?>{
            'id': _movementId,
            'product_id': _activeProductId,
            'delta': -3,
            'kind': 'issue',
            'note': null,
            'occurred_at': '2026-09-13T09:41:02Z',
            'raw_occurred_at': '2026-09-13T09:41:02Z',
            'clock_offset_ms': 0,
            'counted_qty': null,
            'reverses_id': null,
            'device_id': _deviceId,
            'server_created_at': '2026-09-13T10:03:01Z',
          },
        ],
        'balances': [
          <String, Object?>{
            'product_id': _activeProductId,
            'qty': -3,
            'last_movement_at': '2026-09-13T09:41:02Z',
          },
          <String, Object?>{
            'product_id': _deletedProductId,
            'qty': 0,
            'last_movement_at': null,
          },
        ],
        'tombstones': [
          <String, Object?>{
            'id': _deletedProductId,
            'version': 4,
            'deleted_at': '2026-09-13T10:01:00Z',
            'updated_at': '2026-09-13T10:01:00Z',
            'updated_by_device_id': _deviceId,
          },
        ],
        'cursor': 1482,
        'server_time': '2026-09-13T10:02:15Z',
      }),
    );

    expect(decoded.products, hasLength(2));
    expect(decoded.products.last.deletedAt, DateTime.utc(2026, 9, 13, 10, 1));
    expect(decoded.movements.single.delta, -3);
    expect(decoded.balances.first.qty, -3);
    expect(decoded.tombstones.single.id, _deletedProductId);
    expect(decoded.cursor, 1482);
    expect(decoded.serverTime, DateTime.utc(2026, 9, 13, 10, 2, 15));
  });

  test('rejects unknown fields and unsupported snapshot schema versions', () {
    final response = <String, Object?>{
      'schema_version': snapshotSchemaVersion,
      'products': <Object?>[],
      'movements': <Object?>[],
      'balances': <Object?>[],
      'tombstones': <Object?>[],
      'cursor': 0,
      'server_time': '2026-09-13T10:02:15Z',
    };

    response['unexpected'] = true;
    expect(
      () => SnapshotResponse.fromJsonString(jsonEncode(response)),
      throwsA(isA<SyncProtocolException>()),
    );

    response.remove('unexpected');
    response['schema_version'] = 2;
    expect(
      () => SnapshotResponse.fromJsonString(jsonEncode(response)),
      throwsA(isA<UnsupportedSchemaVersionException>()),
    );
  });
}

const _deviceId = '0192f200-0000-7000-8000-000000000001';
const _activeProductId = '0192e1aa-0000-7000-8000-000000000001';
const _deletedProductId = '0192e1aa-0000-7000-8000-000000000002';
const _movementId = '0192e1aa-0000-7000-8000-000000000003';
