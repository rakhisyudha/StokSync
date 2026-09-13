import 'dart:io';

import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';

import 'stoksync_database.dart';

/// Opens the durable SQLite replica used by the local-first application UI.
///
/// Product screens only read and write through this database and its local
/// repositories; it does not make or await a network request.
Future<StokSyncDatabase> openLocalDatabase() async {
  final directory = await getApplicationSupportDirectory();
  final databaseFile = File(
    '${directory.path}${Platform.pathSeparator}stoksync.sqlite',
  );
  return StokSyncDatabase(NativeDatabase.createInBackground(databaseFile));
}
