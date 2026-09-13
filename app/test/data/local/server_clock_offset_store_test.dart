import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/server_clock_offset_store.dart';
import 'package:stoksync/data/local/stoksync_database.dart';

void main() {
  test('persists the server clock offset in sync_state', () async {
    final database = StokSyncDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final store = DriftServerClockOffsetStore(database);

    expect(await store.readOffsetMs(), 0);

    await store.writeOffsetMs(250);
    expect(await store.readOffsetMs(), 250);

    await store.writeOffsetMs(-1250);
    expect(await store.readOffsetMs(), -1250);
  });
}
