import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Emits after a user-originated local transaction commits successfully.
///
/// The signal contains no domain data. Consumers use it only to schedule
/// work, so local-first mutations remain independent of synchronization.
final class LocalWriteNotifier {
  LocalWriteNotifier() : _events = StreamController<void>.broadcast(sync: true);

  final StreamController<void> _events;
  var _disposed = false;

  Stream<void> get events => _events.stream;

  /// Notifies listeners after a committed local mutation.
  void notify() {
    if (!_disposed) {
      _events.add(null);
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _events.close();
  }
}

/// Application-scoped local-write signal shared by repositories and sync.
final localWriteNotifierProvider = Provider<LocalWriteNotifier>((ref) {
  final notifier = LocalWriteNotifier();
  ref.onDispose(() {
    unawaited(notifier.dispose());
  });
  return notifier;
});
