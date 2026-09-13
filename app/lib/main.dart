import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/local/local_database.dart';
import 'data/local/local_query_providers.dart';
import 'features/products/product_pages.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final database = await openLocalDatabase();
  runApp(
    ProviderScope(
      overrides: [stoksyncDatabaseProvider.overrideWithValue(database)],
      child: const StokSyncApp(),
    ),
  );
}

class StokSyncApp extends StatelessWidget {
  const StokSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'StokSync',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const ProductBrowsePage(),
    );
  }
}
