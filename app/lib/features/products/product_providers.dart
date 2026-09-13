import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/identifiers/uuid_v7_generator.dart';
import '../../core/identity/device_identity.dart';
import '../../data/local/local_mutation_repositories.dart';
import '../../data/local/local_query_providers.dart';

/// Provides product mutations backed exclusively by the local Drift database.
///
/// The repository writes the product and its durable pending operation in one
/// local transaction. Remote synchronization is intentionally not part of a
/// product screen action.
final localProductRepositoryProvider = Provider<LocalProductRepository>((ref) {
  return LocalProductRepository(
    database: ref.watch(stoksyncDatabaseProvider),
    identifierGenerator: UuidV7Generator(),
    deviceIdentity: DeviceIdentity.platform(),
  );
});
