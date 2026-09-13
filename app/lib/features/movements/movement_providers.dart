import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/identifiers/uuid_v7_generator.dart';
import '../../core/identity/device_identity.dart';
import '../../data/local/local_mutation_repositories.dart';
import '../../data/local/local_query_providers.dart';

/// Provides immutable stock-ledger mutations backed exclusively by local Drift.
///
/// Movement screens never call a remote service. The repository updates the
/// ledger, rebuildable balance projection, and durable pending operation in one
/// local transaction.
final localStockMovementRepositoryProvider =
    Provider<LocalStockMovementRepository>((ref) {
      return LocalStockMovementRepository(
        database: ref.watch(stoksyncDatabaseProvider),
        identifierGenerator: UuidV7Generator(),
        deviceIdentity: DeviceIdentity.platform(),
      );
    });
