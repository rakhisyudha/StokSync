import 'dart:convert';

import 'errors.dart';

/// The wire schema supported by `GET /v1/snapshot`.
const int snapshotSchemaVersion = 1;

final RegExp _snapshotUuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final RegExp _snapshotRfc3339UtcPattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$',
);

/// A canonical product row in a full-replica bootstrap response.
final class SnapshotProduct {
  const SnapshotProduct({
    required this.id,
    required this.name,
    required this.unit,
    required this.version,
    required this.updatedAt,
    required this.updatedByDeviceId,
    required this.createdAt,
    this.barcode,
    this.sku,
    this.description,
    this.category,
    this.minStock,
    this.deletedAt,
  });

  final String id;
  final String? barcode;
  final String? sku;
  final String name;
  final String? description;
  final String unit;
  final String? category;
  final int? minStock;
  final int version;
  final DateTime updatedAt;
  final String updatedByDeviceId;
  final DateTime? deletedAt;
  final DateTime createdAt;

  Map<String, Object?> toJson() {
    _validateSnapshotUuid(id, 'products.id');
    _validateSnapshotRequiredText(name, 'products.name');
    _validateSnapshotRequiredText(unit, 'products.unit');
    _validateSnapshotInt64(version, 'products.version');
    if (version < 0) {
      throw _snapshotInvalid('products.version', 'must not be negative');
    }
    if (minStock != null) {
      _validateSnapshotInt32(minStock!, 'products.min_stock');
      if (minStock! < 0) {
        throw _snapshotInvalid('products.min_stock', 'must not be negative');
      }
    }
    _validateSnapshotTimestamp(updatedAt, 'products.updated_at');
    _validateSnapshotUuid(updatedByDeviceId, 'products.updated_by_device_id');
    if (deletedAt != null) {
      _validateSnapshotTimestamp(deletedAt!, 'products.deleted_at');
    }
    _validateSnapshotTimestamp(createdAt, 'products.created_at');
    return <String, Object?>{
      'id': id,
      'barcode': barcode,
      'sku': sku,
      'name': name,
      'description': description,
      'unit': unit,
      'category': category,
      'min_stock': minStock,
      'version': version,
      'updated_at': _snapshotTimestamp(updatedAt, 'products.updated_at'),
      'updated_by_device_id': updatedByDeviceId,
      'deleted_at': deletedAt == null
          ? null
          : _snapshotTimestamp(deletedAt!, 'products.deleted_at'),
      'created_at': _snapshotTimestamp(createdAt, 'products.created_at'),
    };
  }

  static SnapshotProduct fromJson(Object? value) {
    final map = _snapshotObject(value, 'product');
    _snapshotCheckKeys(
      map,
      const {
        'id',
        'barcode',
        'sku',
        'name',
        'description',
        'unit',
        'category',
        'min_stock',
        'version',
        'updated_at',
        'updated_by_device_id',
        'deleted_at',
        'created_at',
      },
      const {
        'id',
        'barcode',
        'sku',
        'name',
        'description',
        'unit',
        'category',
        'min_stock',
        'version',
        'updated_at',
        'updated_by_device_id',
        'deleted_at',
        'created_at',
      },
      'product',
    );
    final product = SnapshotProduct(
      id: _snapshotUuid(map['id'], 'products.id'),
      barcode: _snapshotOptionalString(map['barcode'], 'products.barcode'),
      sku: _snapshotOptionalString(map['sku'], 'products.sku'),
      name: _snapshotRequiredString(map['name'], 'products.name'),
      description: _snapshotOptionalString(
        map['description'],
        'products.description',
      ),
      unit: _snapshotRequiredString(map['unit'], 'products.unit'),
      category: _snapshotOptionalString(map['category'], 'products.category'),
      minStock: _snapshotOptionalInt(map['min_stock'], 'products.min_stock'),
      version: _snapshotInt(map['version'], 'products.version'),
      updatedAt: _snapshotDateTime(map['updated_at'], 'products.updated_at'),
      updatedByDeviceId: _snapshotUuid(
        map['updated_by_device_id'],
        'products.updated_by_device_id',
      ),
      deletedAt: _snapshotOptionalDateTime(
        map['deleted_at'],
        'products.deleted_at',
      ),
      createdAt: _snapshotDateTime(map['created_at'], 'products.created_at'),
    );
    product.toJson();
    return product;
  }
}

/// An immutable canonical ledger row in a full-replica bootstrap response.
final class SnapshotMovement {
  const SnapshotMovement({
    required this.id,
    required this.productId,
    required this.delta,
    required this.kind,
    required this.occurredAt,
    required this.rawOccurredAt,
    required this.clockOffsetMs,
    required this.countedQty,
    required this.reversesId,
    required this.deviceId,
    required this.serverCreatedAt,
    this.note,
  });

  final String id;
  final String productId;
  final int delta;
  final String kind;
  final String? note;
  final DateTime occurredAt;
  final DateTime rawOccurredAt;
  final int clockOffsetMs;
  final int? countedQty;
  final String? reversesId;
  final String deviceId;
  final DateTime serverCreatedAt;

  Map<String, Object?> toJson() {
    _validateSnapshotUuid(id, 'movements.id');
    _validateSnapshotUuid(productId, 'movements.product_id');
    _validateSnapshotInt32(delta, 'movements.delta');
    if (delta == 0) {
      throw _snapshotInvalid('movements.delta', 'must not be zero');
    }
    if (!_snapshotMovementKinds.contains(kind)) {
      throw _snapshotInvalid('movements.kind', 'is not supported');
    }
    _validateSnapshotTimestamp(occurredAt, 'movements.occurred_at');
    _validateSnapshotTimestamp(rawOccurredAt, 'movements.raw_occurred_at');
    _validateSnapshotInt64(clockOffsetMs, 'movements.clock_offset_ms');
    if (countedQty != null) {
      _validateSnapshotInt32(countedQty!, 'movements.counted_qty');
      if (countedQty! < 0) {
        throw _snapshotInvalid('movements.counted_qty', 'must not be negative');
      }
    }
    if (kind == 'stocktake' && countedQty == null) {
      throw _snapshotInvalid(
        'movements.counted_qty',
        'is required for stocktake movements',
      );
    }
    if (kind != 'stocktake' && countedQty != null) {
      throw _snapshotInvalid(
        'movements.counted_qty',
        'is only valid for stocktake movements',
      );
    }
    if (reversesId != null) {
      _validateSnapshotUuid(reversesId!, 'movements.reverses_id');
      if (kind != 'adjust') {
        throw _snapshotInvalid(
          'movements.reverses_id',
          'is only valid for adjust movements',
        );
      }
    }
    _validateSnapshotUuid(deviceId, 'movements.device_id');
    _validateSnapshotTimestamp(serverCreatedAt, 'movements.server_created_at');
    return <String, Object?>{
      'id': id,
      'product_id': productId,
      'delta': delta,
      'kind': kind,
      'note': note,
      'occurred_at': _snapshotTimestamp(occurredAt, 'movements.occurred_at'),
      'raw_occurred_at': _snapshotTimestamp(
        rawOccurredAt,
        'movements.raw_occurred_at',
      ),
      'clock_offset_ms': clockOffsetMs,
      'counted_qty': countedQty,
      'reverses_id': reversesId,
      'device_id': deviceId,
      'server_created_at': _snapshotTimestamp(
        serverCreatedAt,
        'movements.server_created_at',
      ),
    };
  }

  static SnapshotMovement fromJson(Object? value) {
    final map = _snapshotObject(value, 'movement');
    _snapshotCheckKeys(
      map,
      const {
        'id',
        'product_id',
        'delta',
        'kind',
        'note',
        'occurred_at',
        'raw_occurred_at',
        'clock_offset_ms',
        'counted_qty',
        'reverses_id',
        'device_id',
        'server_created_at',
      },
      const {
        'id',
        'product_id',
        'delta',
        'kind',
        'note',
        'occurred_at',
        'raw_occurred_at',
        'clock_offset_ms',
        'counted_qty',
        'reverses_id',
        'device_id',
        'server_created_at',
      },
      'movement',
    );
    final movement = SnapshotMovement(
      id: _snapshotUuid(map['id'], 'movements.id'),
      productId: _snapshotUuid(map['product_id'], 'movements.product_id'),
      delta: _snapshotInt(map['delta'], 'movements.delta'),
      kind: _snapshotRequiredString(map['kind'], 'movements.kind'),
      note: _snapshotOptionalString(map['note'], 'movements.note'),
      occurredAt: _snapshotDateTime(
        map['occurred_at'],
        'movements.occurred_at',
      ),
      rawOccurredAt: _snapshotDateTime(
        map['raw_occurred_at'],
        'movements.raw_occurred_at',
      ),
      clockOffsetMs: _snapshotInt(
        map['clock_offset_ms'],
        'movements.clock_offset_ms',
      ),
      countedQty: _snapshotOptionalInt(
        map['counted_qty'],
        'movements.counted_qty',
      ),
      reversesId: _snapshotOptionalUuid(
        map['reverses_id'],
        'movements.reverses_id',
      ),
      deviceId: _snapshotUuid(map['device_id'], 'movements.device_id'),
      serverCreatedAt: _snapshotDateTime(
        map['server_created_at'],
        'movements.server_created_at',
      ),
    );
    movement.toJson();
    return movement;
  }
}

/// A materialized balance supplied with a canonical snapshot.
final class SnapshotBalance {
  const SnapshotBalance({
    required this.productId,
    required this.qty,
    required this.lastMovementAt,
  });

  final String productId;
  final int qty;
  final DateTime? lastMovementAt;

  Map<String, Object?> toJson() {
    _validateSnapshotUuid(productId, 'balances.product_id');
    _validateSnapshotInt64(qty, 'balances.qty');
    if (lastMovementAt != null) {
      _validateSnapshotTimestamp(lastMovementAt!, 'balances.last_movement_at');
    }
    return <String, Object?>{
      'product_id': productId,
      'qty': qty,
      'last_movement_at': lastMovementAt == null
          ? null
          : _snapshotTimestamp(lastMovementAt!, 'balances.last_movement_at'),
    };
  }

  static SnapshotBalance fromJson(Object? value) {
    final map = _snapshotObject(value, 'balance');
    _snapshotCheckKeys(
      map,
      const {'product_id', 'qty', 'last_movement_at'},
      const {'product_id', 'qty', 'last_movement_at'},
      'balance',
    );
    final balance = SnapshotBalance(
      productId: _snapshotUuid(map['product_id'], 'balances.product_id'),
      qty: _snapshotInt(map['qty'], 'balances.qty'),
      lastMovementAt: _snapshotOptionalDateTime(
        map['last_movement_at'],
        'balances.last_movement_at',
      ),
    );
    balance.toJson();
    return balance;
  }
}

/// Explicit deletion metadata accompanying a deleted product row.
final class SnapshotTombstone {
  const SnapshotTombstone({
    required this.id,
    required this.version,
    required this.deletedAt,
    required this.updatedAt,
    required this.updatedByDeviceId,
  });

  final String id;
  final int version;
  final DateTime deletedAt;
  final DateTime updatedAt;
  final String updatedByDeviceId;

  Map<String, Object?> toJson() {
    _validateSnapshotUuid(id, 'tombstones.id');
    _validateSnapshotInt64(version, 'tombstones.version');
    if (version < 0) {
      throw _snapshotInvalid('tombstones.version', 'must not be negative');
    }
    _validateSnapshotTimestamp(deletedAt, 'tombstones.deleted_at');
    _validateSnapshotTimestamp(updatedAt, 'tombstones.updated_at');
    _validateSnapshotUuid(updatedByDeviceId, 'tombstones.updated_by_device_id');
    return <String, Object?>{
      'id': id,
      'version': version,
      'deleted_at': _snapshotTimestamp(deletedAt, 'tombstones.deleted_at'),
      'updated_at': _snapshotTimestamp(updatedAt, 'tombstones.updated_at'),
      'updated_by_device_id': updatedByDeviceId,
    };
  }

  static SnapshotTombstone fromJson(Object? value) {
    final map = _snapshotObject(value, 'tombstone');
    _snapshotCheckKeys(
      map,
      const {
        'id',
        'version',
        'deleted_at',
        'updated_at',
        'updated_by_device_id',
      },
      const {
        'id',
        'version',
        'deleted_at',
        'updated_at',
        'updated_by_device_id',
      },
      'tombstone',
    );
    final tombstone = SnapshotTombstone(
      id: _snapshotUuid(map['id'], 'tombstones.id'),
      version: _snapshotInt(map['version'], 'tombstones.version'),
      deletedAt: _snapshotDateTime(map['deleted_at'], 'tombstones.deleted_at'),
      updatedAt: _snapshotDateTime(map['updated_at'], 'tombstones.updated_at'),
      updatedByDeviceId: _snapshotUuid(
        map['updated_by_device_id'],
        'tombstones.updated_by_device_id',
      ),
    );
    tombstone.toJson();
    return tombstone;
  }
}

/// Versioned full-replica response returned by `GET /v1/snapshot`.
final class SnapshotResponse {
  const SnapshotResponse({
    required this.products,
    required this.movements,
    required this.balances,
    required this.tombstones,
    required this.cursor,
    required this.serverTime,
  });

  final List<SnapshotProduct> products;
  final List<SnapshotMovement> movements;
  final List<SnapshotBalance> balances;
  final List<SnapshotTombstone> tombstones;
  final int cursor;
  final DateTime serverTime;

  /// Validates this response without changing or persisting any state.
  void validate() {
    toJson();
  }

  Map<String, Object?> toJson() {
    final productJson = products.map((product) => product.toJson()).toList();
    final movementJson = movements
        .map((movement) => movement.toJson())
        .toList();
    final balanceJson = balances.map((balance) => balance.toJson()).toList();
    final tombstoneJson = tombstones
        .map((tombstone) => tombstone.toJson())
        .toList();
    _validateSnapshotInt64(cursor, 'cursor');
    if (cursor < 0) {
      throw _snapshotInvalid('cursor', 'must not be negative');
    }
    _validateSnapshotTimestamp(serverTime, 'server_time');
    _validateSnapshotConsistency();
    return <String, Object?>{
      'schema_version': snapshotSchemaVersion,
      'products': productJson,
      'movements': movementJson,
      'balances': balanceJson,
      'tombstones': tombstoneJson,
      'cursor': cursor,
      'server_time': _snapshotTimestamp(serverTime, 'server_time'),
    };
  }

  String toJsonString() => jsonEncode(toJson());

  static SnapshotResponse fromJson(Object? value) {
    final map = _snapshotObject(value, 'snapshot');
    _snapshotCheckKeys(
      map,
      const {
        'schema_version',
        'products',
        'movements',
        'balances',
        'tombstones',
        'cursor',
        'server_time',
      },
      const {
        'schema_version',
        'products',
        'movements',
        'balances',
        'tombstones',
        'cursor',
        'server_time',
      },
      'snapshot',
    );
    _validateSnapshotSchema(
      _snapshotInt(map['schema_version'], 'schema_version'),
    );
    final response = SnapshotResponse(
      products: _snapshotList(
        map['products'],
        'products',
      ).map(SnapshotProduct.fromJson).toList(growable: false),
      movements: _snapshotList(
        map['movements'],
        'movements',
      ).map(SnapshotMovement.fromJson).toList(growable: false),
      balances: _snapshotList(
        map['balances'],
        'balances',
      ).map(SnapshotBalance.fromJson).toList(growable: false),
      tombstones: _snapshotList(
        map['tombstones'],
        'tombstones',
      ).map(SnapshotTombstone.fromJson).toList(growable: false),
      cursor: _snapshotInt(map['cursor'], 'cursor'),
      serverTime: _snapshotDateTime(map['server_time'], 'server_time'),
    );
    response.validate();
    return response;
  }

  static SnapshotResponse fromJsonString(String source) {
    return SnapshotResponse.fromJson(_snapshotDecodeJson(source, 'snapshot'));
  }

  void _validateSnapshotConsistency() {
    final productsById = <String, SnapshotProduct>{};
    for (final product in products) {
      if (productsById.containsKey(product.id)) {
        throw _snapshotInvalid(
          'products.${product.id}',
          'contains a duplicate product id',
        );
      }
      productsById[product.id] = product;
    }

    final movementsById = <String, SnapshotMovement>{};
    for (final movement in movements) {
      if (movementsById.containsKey(movement.id)) {
        throw _snapshotInvalid(
          'movements.${movement.id}',
          'contains a duplicate movement id',
        );
      }
      movementsById[movement.id] = movement;
      if (!productsById.containsKey(movement.productId)) {
        throw _snapshotInvalid(
          'movements.${movement.id}.product_id',
          'does not reference a snapshot product',
        );
      }
    }

    final balancesByProductId = <String, SnapshotBalance>{};
    for (final balance in balances) {
      if (balancesByProductId.containsKey(balance.productId)) {
        throw _snapshotInvalid(
          'balances.${balance.productId}',
          'contains a duplicate product id',
        );
      }
      balancesByProductId[balance.productId] = balance;
      if (!productsById.containsKey(balance.productId)) {
        throw _snapshotInvalid(
          'balances.${balance.productId}.product_id',
          'does not reference a snapshot product',
        );
      }
    }

    final tombstonesById = <String, SnapshotTombstone>{};
    for (final tombstone in tombstones) {
      if (tombstonesById.containsKey(tombstone.id)) {
        throw _snapshotInvalid(
          'tombstones.${tombstone.id}',
          'contains a duplicate product id',
        );
      }
      tombstonesById[tombstone.id] = tombstone;
      final product = productsById[tombstone.id];
      if (product == null) {
        throw _snapshotInvalid(
          'tombstones.${tombstone.id}.id',
          'does not reference a snapshot product',
        );
      }
      if (product.deletedAt == null ||
          product.version != tombstone.version ||
          !product.deletedAt!.toUtc().isAtSameMomentAs(tombstone.deletedAt) ||
          !product.updatedAt.toUtc().isAtSameMomentAs(tombstone.updatedAt) ||
          product.updatedByDeviceId != tombstone.updatedByDeviceId) {
        throw _snapshotInvalid(
          'tombstones.${tombstone.id}',
          'does not match the deleted product row',
        );
      }
    }

    for (final movement in movements) {
      final reversesId = movement.reversesId;
      if (reversesId == null) {
        continue;
      }
      final original = movementsById[reversesId];
      if (original == null) {
        throw _snapshotInvalid(
          'movements.${movement.id}.reverses_id',
          'does not reference a snapshot movement',
        );
      }
      if (original.productId != movement.productId) {
        throw _snapshotInvalid(
          'movements.${movement.id}.reverses_id',
          'must reference a movement for the same product',
        );
      }
    }
  }
}

const Set<String> _snapshotMovementKinds = {
  'receive',
  'issue',
  'adjust',
  'stocktake',
};

void _validateSnapshotSchema(int version) {
  if (version != snapshotSchemaVersion) {
    throw UnsupportedSchemaVersionException(
      receivedVersion: version,
      minimumSupportedVersion: snapshotSchemaVersion,
    );
  }
}

void _validateSnapshotUuid(String value, String field) {
  if (!_snapshotUuidPattern.hasMatch(value) ||
      value.toLowerCase() == '00000000-0000-0000-0000-000000000000') {
    throw _snapshotInvalid(field, 'must be a non-zero UUID string');
  }
}

void _validateSnapshotRequiredText(String value, String field) {
  if (value.trim().isEmpty) {
    throw _snapshotInvalid(field, 'must not be blank');
  }
}

void _validateSnapshotInt32(int value, String field) {
  if (value < -2147483648 || value > 2147483647) {
    throw _snapshotInvalid(field, 'is outside the supported integer range');
  }
}

void _validateSnapshotInt64(int value, String field) {
  if (value < -9223372036854775808 || value > 9223372036854775807) {
    throw _snapshotInvalid(field, 'is outside the supported integer range');
  }
}

void _validateSnapshotTimestamp(DateTime value, String field) {
  final timestamp = value.toUtc().toIso8601String();
  if (!_snapshotRfc3339UtcPattern.hasMatch(timestamp)) {
    throw _snapshotInvalid(field, 'must be an RFC3339 UTC timestamp');
  }
}

String _snapshotTimestamp(DateTime value, String field) {
  _validateSnapshotTimestamp(value, field);
  return value.toUtc().toIso8601String();
}

String _snapshotRequiredString(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw _snapshotInvalid(field, 'must be a non-empty string');
  }
  return value;
}

String? _snapshotOptionalString(Object? value, String field) {
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw _snapshotInvalid(field, 'must be a string when provided');
  }
  return value;
}

int _snapshotInt(Object? value, String field) {
  if (value is! int) {
    throw _snapshotInvalid(field, 'must be an integer');
  }
  return value;
}

int? _snapshotOptionalInt(Object? value, String field) {
  if (value == null) {
    return null;
  }
  return _snapshotInt(value, field);
}

String _snapshotUuid(Object? value, String field) {
  final result = _snapshotRequiredString(value, field);
  _validateSnapshotUuid(result, field);
  return result;
}

String? _snapshotOptionalUuid(Object? value, String field) {
  if (value == null) {
    return null;
  }
  return _snapshotUuid(value, field);
}

DateTime _snapshotDateTime(Object? value, String field) {
  final text = _snapshotRequiredString(value, field);
  final match = _snapshotRfc3339UtcPattern.firstMatch(text);
  if (match == null) {
    throw _snapshotInvalid(field, 'must be an RFC3339 UTC timestamp');
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null ||
      !parsed.isUtc ||
      parsed.year != int.parse(match.group(1)!) ||
      parsed.month != int.parse(match.group(2)!) ||
      parsed.day != int.parse(match.group(3)!) ||
      parsed.hour != int.parse(match.group(4)!) ||
      parsed.minute != int.parse(match.group(5)!) ||
      parsed.second != int.parse(match.group(6)!)) {
    throw _snapshotInvalid(field, 'must be an RFC3339 UTC timestamp');
  }
  return parsed;
}

DateTime? _snapshotOptionalDateTime(Object? value, String field) {
  if (value == null) {
    return null;
  }
  return _snapshotDateTime(value, field);
}

Map<String, Object?> _snapshotObject(Object? value, String field) {
  if (value is! Map) {
    throw _snapshotInvalid(field, 'must be a JSON object');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw _snapshotInvalid(field, 'contains a non-string field name');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

List<Object?> _snapshotList(Object? value, String field) {
  if (value is! List) {
    throw _snapshotInvalid(field, 'must be a JSON array');
  }
  return value.cast<Object?>();
}

void _snapshotCheckKeys(
  Map<String, Object?> map,
  Set<String> allowed,
  Set<String> required,
  String field,
) {
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throw _snapshotInvalid(field, 'contains an unknown field');
    }
  }
  for (final key in required) {
    if (!map.containsKey(key)) {
      throw _snapshotInvalid('$field.$key', 'is required');
    }
  }
}

Object? _snapshotDecodeJson(String source, String field) {
  try {
    return jsonDecode(source);
  } on FormatException {
    throw SyncProtocolException(
      SyncProtocolErrorKind.malformedJson,
      'contains malformed JSON',
      field: field,
    );
  }
}

SyncProtocolException _snapshotInvalid(String field, String message) {
  return SyncProtocolException(
    SyncProtocolErrorKind.invalidValue,
    message,
    field: field,
  );
}
