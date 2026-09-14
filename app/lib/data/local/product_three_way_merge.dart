import 'package:sync_engine/sync_engine.dart';

/// Product fields whose values are authored by an `upsert_product` operation.
///
/// Server metadata such as version, timestamps, update device, and deletion
/// state is never merged from a stale local payload. The server state remains
/// canonical for those fields.
const List<String> productMergeFields = <String>[
  'barcode',
  'sku',
  'name',
  'description',
  'unit',
  'category',
  'min_stock',
];

/// The result of comparing one product's base, local, and canonical values.
final class ProductThreeWayMergeResult {
  const ProductThreeWayMergeResult({
    required this.localChangedFields,
    required this.serverChangedFields,
    required this.overlappingFields,
    required this.mergedPayload,
  });

  final Set<String> localChangedFields;
  final Set<String> serverChangedFields;
  final Set<String> overlappingFields;

  /// The complete product payload when the changed field sets are disjoint;
  /// `null` when the payload is unavailable or fields overlap.
  final Map<String, Object?>? mergedPayload;

  bool get canAutoMerge => mergedPayload != null && overlappingFields.isEmpty;
}

/// Performs a strict field-level three-way merge for product upserts.
///
/// A field is considered changed when its local or server value differs from
/// the base value. Only disjoint changed field sets are auto-merged. Missing
/// fields, mismatched product ids, or a canonical tombstone make the inputs
/// insufficient and return `null` rather than guessing at user intent.
final class ProductThreeWayMerge {
  const ProductThreeWayMerge._();

  static ProductThreeWayMergeResult? compare({
    required Map<String, Object?> base,
    required Map<String, Object?> local,
    required Map<String, Object?> server,
  }) {
    if (!_hasCompleteEditablePayload(base) ||
        !_hasCompleteEditablePayload(local) ||
        !_hasCompleteEditablePayload(server)) {
      return null;
    }
    final baseId = base['id'];
    if (baseId is! String || local['id'] != baseId || server['id'] != baseId) {
      return null;
    }
    if (server['deleted_at'] != null) {
      return null;
    }

    final localChanged = <String>{};
    final serverChanged = <String>{};
    for (final field in productMergeFields) {
      if (local[field] != base[field]) {
        localChanged.add(field);
      }
      if (server[field] != base[field]) {
        serverChanged.add(field);
      }
    }
    final overlap = localChanged.intersection(serverChanged);
    if (overlap.isNotEmpty) {
      return ProductThreeWayMergeResult(
        localChangedFields: Set<String>.unmodifiable(localChanged),
        serverChangedFields: Set<String>.unmodifiable(serverChanged),
        overlappingFields: Set<String>.unmodifiable(overlap),
        mergedPayload: null,
      );
    }

    final merged = <String, Object?>{'id': baseId};
    for (final field in productMergeFields) {
      merged[field] = localChanged.contains(field)
          ? local[field]
          : server[field];
    }
    return ProductThreeWayMergeResult(
      localChangedFields: Set<String>.unmodifiable(localChanged),
      serverChangedFields: Set<String>.unmodifiable(serverChanged),
      overlappingFields: const <String>{},
      mergedPayload: Map<String, Object?>.unmodifiable(merged),
    );
  }

  static bool _hasCompleteEditablePayload(Map<String, Object?> payload) {
    if (!payload.containsKey('id')) {
      return false;
    }
    return productMergeFields.every(payload.containsKey);
  }
}

/// Validates the merged payload using the same protocol rules used for queued
/// operations, without changing its explicit null fields.
void validateMergedProductPayload(Map<String, Object?> payload) {
  UpsertProductPayload.fromJson(payload);
}
