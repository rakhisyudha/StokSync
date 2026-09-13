import 'package:sync_engine/sync_engine.dart';

void main() {
  final request = SyncRequest(
    deviceId: '0192f200-0000-7000-8000-000000000001',
    cursor: 0,
    maxChanges: 10,
    clientTime: DateTime.now().toUtc(),
    operations: const [],
  );
  print(request.toJsonString());
}
