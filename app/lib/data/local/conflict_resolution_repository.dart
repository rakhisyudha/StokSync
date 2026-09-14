import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/identifiers/uuid_v7_generator.dart';
import '../../core/identity/device_identity.dart';
import 'local_write_notifier.dart';
import 'local_mutation_repositories.dart';
import 'stoksync_database.dart';

/// The explicit local intent a user can create from a product conflict.
enum ProductConflictResolution { useLocal, useServer, removeConflictingBarcode }

/// Identifies the new queued operation created by a conflict resolution.
final class ConflictResolutionResult {
  const ConflictResolutionResult({
    required this.operationId,
    required this.localSequence,
  });

  final String operationId;
  final int localSequence;
}

/// Raised when a conflict cannot be resolved from the locally retained data.
final class ConflictResolutionException implements Exception {
  const ConflictResolutionException(this.message);

  final String message;

  @override
  String toString() => 'ConflictResolutionException: $message';
}

/// Creates explicit, local-first follow-up operations for retained conflicts.
///
/// The original blocked operation and its conflict row are never deleted. A
/// product resolution writes the selected optimistic product state and its new
/// FIFO operation in one Drift transaction, then marks the original conflict
/// resolved. This keeps the rejected intent auditable while allowing normal
/// synchronization to submit the follow-up later.
final class LocalConflictResolutionRepository {
  LocalConflictResolutionRepository({
    required StokSyncDatabase database,
    required IdentifierGenerator identifierGenerator,
    required DeviceIdentity deviceIdentity,
    DateTime Function()? clock,
    PendingOperationDao? pendingOperations,
    LocalWriteNotifier? localWriteNotifier,
  }) : _database = database,
       _identifierGenerator = identifierGenerator,
       _deviceIdentity = deviceIdentity,
       _clock = clock ?? _utcNow,
       _pendingOperations = pendingOperations ?? PendingOperationDao(database),
       _localWriteNotifier = localWriteNotifier;

  final StokSyncDatabase _database;
  final IdentifierGenerator _identifierGenerator;
  final DeviceIdentity _deviceIdentity;
  final DateTime Function() _clock;
  final PendingOperationDao _pendingOperations;
  final LocalWriteNotifier? _localWriteNotifier;

  /// Resolves a product conflict by queuing a new supported product upsert.
  ///
  /// [useServer] is only available when the retained canonical state belongs
  /// to the conflicted product. A barcode collision instead exposes the
  /// canonical owner for inspection and supports retrying the local product
  /// without its colliding barcode.
  Future<ConflictResolutionResult> resolveProduct({
    required Conflict conflict,
    required ProductConflictResolution resolution,
  }) async {
    if (conflict.entity != 'product') {
      throw const ConflictResolutionException(
        'Only product conflicts have a product resolution flow.',
      );
    }
    if (conflict.resolutionStatus != 'unresolved') {
      throw const ConflictResolutionException(
        'This conflict is already resolved.',
      );
    }

    final localPayload = _decodeObject(conflict.localPayload);
    final serverPayload = _decodeObject(conflict.serverPayload);
    if (localPayload == null) {
      throw const ConflictResolutionException(
        'The retained local intent is not a valid product payload.',
      );
    }
    final now = _clock().toUtc();
    final deviceId = await _deviceIdentity.getDeviceId();

    final result = await _database.transaction(() async {
      final currentConflict = await (_database.select(
        _database.conflicts,
      )..where((row) => row.opId.equals(conflict.opId))).getSingleOrNull();
      if (currentConflict == null ||
          currentConflict.resolutionStatus != 'unresolved') {
        throw const ConflictResolutionException(
          'This conflict was resolved by another local action.',
        );
      }

      final product = await (_database.select(
        _database.products,
      )..where((row) => row.id.equals(conflict.entityId))).getSingleOrNull();
      if (product == null) {
        throw ConflictResolutionException(
          'Product ${conflict.entityId} is not available locally.',
        );
      }

      final selectedPayload = _selectPayload(
        conflict: conflict,
        localPayload: localPayload,
        serverPayload: serverPayload,
        resolution: resolution,
      );
      final serverVersion = _serverVersion(serverPayload);
      final pending = await (_database.select(
        _database.pendingOperations,
      )..where((row) => row.opId.equals(conflict.opId))).getSingleOrNull();
      final baseVersion = switch (resolution) {
        ProductConflictResolution.removeConflictingBarcode =>
          pending?.baseVersion,
        ProductConflictResolution.useLocal ||
        ProductConflictResolution.useServer => serverVersion,
      };

      if (resolution != ProductConflictResolution.removeConflictingBarcode &&
          serverVersion == null) {
        throw const ConflictResolutionException(
          'The canonical product version is required before retrying this edit.',
        );
      }

      final operationId = _newIdentifier('operation');
      final localSequence = await _pendingOperations.enqueue(
        operationId: operationId,
        entity: 'product',
        entityId: conflict.entityId,
        operation: 'upsert_product',
        payload: jsonEncode(selectedPayload),
        basePayload:
            resolution == ProductConflictResolution.removeConflictingBarcode
            ? pending?.basePayload
            : _basePayloadJson(serverPayload, id: conflict.entityId),
        baseVersion: baseVersion,
        enqueuedAt: now,
      );

      final nextVersion = serverVersion == null
          ? (product.version < 1 ? 1 : product.version) + 1
          : serverVersion + 1;
      await (_database.update(
        _database.products,
      )..where((row) => row.id.equals(conflict.entityId))).write(
        ProductsCompanion(
          barcode: Value(_stringOrNull(selectedPayload['barcode'])),
          sku: Value(_stringOrNull(selectedPayload['sku'])),
          name: Value(_requiredName(selectedPayload, product.name)),
          description: Value(_stringOrNull(selectedPayload['description'])),
          unit: Value(_requiredUnit(selectedPayload, product.unit)),
          category: Value(_stringOrNull(selectedPayload['category'])),
          minStock: Value(_intOrNull(selectedPayload['min_stock'])),
          version: Value(nextVersion),
          updatedAt: Value(now),
          updatedBy: Value(deviceId),
          deletedAt: const Value(null),
          syncStatus: const Value('pending'),
        ),
      );

      await (_database.update(_database.conflicts)
            ..where((row) => row.opId.equals(conflict.opId)))
          .write(ConflictsCompanion(resolutionStatus: const Value('resolved')));

      return ConflictResolutionResult(
        operationId: operationId,
        localSequence: localSequence,
      );
    });
    _localWriteNotifier?.notify();
    return result;
  }

  /// Marks a delete-wins conflict reviewed without rewriting the tombstone.
  ///
  /// A remote tombstone is already canonical and cannot be undone by an
  /// `upsert_product` operation. Marking it reviewed is therefore the only
  /// applicable local action; the rejected edit remains in the conflict row.
  Future<void> markReviewed(Conflict conflict) async {
    if (conflict.resolutionStatus != 'unresolved') {
      throw const ConflictResolutionException(
        'This conflict is already resolved.',
      );
    }
    await (_database.update(_database.conflicts)
          ..where((row) => row.opId.equals(conflict.opId)))
        .write(const ConflictsCompanion(resolutionStatus: Value('resolved')));
  }

  Map<String, Object?> _selectPayload({
    required Conflict conflict,
    required Map<String, Object?> localPayload,
    required Map<String, Object?>? serverPayload,
    required ProductConflictResolution resolution,
  }) {
    switch (resolution) {
      case ProductConflictResolution.useLocal:
        if (conflict.reason == 'barcode_conflict') {
          throw const ConflictResolutionException(
            'A colliding barcode must be removed before retrying this product.',
          );
        }
        return _editablePayload(localPayload, id: conflict.entityId);
      case ProductConflictResolution.useServer:
        if (serverPayload == null ||
            serverPayload['id'] != conflict.entityId ||
            serverPayload['deleted_at'] != null) {
          throw const ConflictResolutionException(
            'The canonical state cannot replace this local product.',
          );
        }
        return _editablePayload(serverPayload, id: conflict.entityId);
      case ProductConflictResolution.removeConflictingBarcode:
        if (conflict.reason != 'barcode_conflict') {
          throw const ConflictResolutionException(
            'Removing a barcode is only applicable to barcode conflicts.',
          );
        }
        final payload = _editablePayload(localPayload, id: conflict.entityId);
        payload['barcode'] = null;
        return payload;
    }
  }

  int? _serverVersion(Map<String, Object?>? serverPayload) {
    final version = serverPayload?['version'];
    return version is int && version > 0 ? version : null;
  }

  Map<String, Object?> _editablePayload(
    Map<String, Object?>? source, {
    required String id,
  }) {
    final payload = <String, Object?>{'id': id};
    if (source == null) {
      return payload;
    }
    for (final field in const [
      'barcode',
      'sku',
      'name',
      'description',
      'unit',
      'category',
      'min_stock',
    ]) {
      if (source.containsKey(field)) {
        payload[field] = source[field];
      }
    }
    return payload;
  }

  Map<String, Object?>? _decodeObject(String? source) {
    if (source == null) {
      return null;
    }
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map) {
        return null;
      }
      final result = <String, Object?>{};
      for (final entry in decoded.entries) {
        if (entry.key is! String) {
          return null;
        }
        result[entry.key as String] = entry.value;
      }
      return result;
    } on FormatException {
      return null;
    }
  }

  String _requiredName(Map<String, Object?> payload, String fallback) {
    final name = payload['name'];
    if (name is String && name.trim().isNotEmpty) {
      return name;
    }
    return fallback;
  }

  String _requiredUnit(Map<String, Object?> payload, String fallback) {
    final unit = payload['unit'];
    if (unit is String && unit.trim().isNotEmpty) {
      return unit;
    }
    return fallback;
  }

  String? _stringOrNull(Object? value) => value is String ? value : null;

  int? _intOrNull(Object? value) => value is int ? value : null;

  String? _basePayloadJson(
    Map<String, Object?>? serverPayload, {
    required String id,
  }) {
    if (serverPayload == null) {
      return null;
    }
    return jsonEncode(_editablePayload(serverPayload, id: id));
  }

  String _newIdentifier(String field) {
    final identifier = _identifierGenerator.generate();
    if (!UuidV7.isValid(identifier)) {
      throw StateError('$field identifier must be a UUIDv7');
    }
    return identifier;
  }
}

DateTime _utcNow() => DateTime.now().toUtc();
