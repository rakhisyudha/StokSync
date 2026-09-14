import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/identifiers/uuid_v7_generator.dart';
import '../../core/identity/device_identity.dart';
import '../../data/local/conflict_resolution_repository.dart';
import '../../data/local/local_query_providers.dart';
import '../../data/local/local_write_notifier.dart';

/// Provides local-first conflict actions. The repository never calls the API.
final localConflictResolutionRepositoryProvider =
    Provider<LocalConflictResolutionRepository>((ref) {
      return LocalConflictResolutionRepository(
        database: ref.watch(stoksyncDatabaseProvider),
        identifierGenerator: UuidV7Generator(),
        deviceIdentity: DeviceIdentity.platform(),
        localWriteNotifier: ref.watch(localWriteNotifierProvider),
      );
    });
