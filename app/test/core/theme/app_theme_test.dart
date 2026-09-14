import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('derives Material 3 light and dark themes from the shared seed', () {
    final lightTheme = buildStokSyncTheme(Brightness.light);
    final darkTheme = buildStokSyncTheme(Brightness.dark);

    expect(lightTheme.useMaterial3, isTrue);
    expect(darkTheme.useMaterial3, isTrue);
    expect(
      lightTheme.colorScheme,
      ColorScheme.fromSeed(
        seedColor: stoksyncSeedColor,
        brightness: Brightness.light,
      ),
    );
    expect(
      darkTheme.colorScheme,
      ColorScheme.fromSeed(
        seedColor: stoksyncSeedColor,
        brightness: Brightness.dark,
      ),
    );
    expect(lightTheme.textTheme.bodyMedium?.fontFamily, startsWith('Inter'));
    expect(darkTheme.textTheme.bodyMedium?.fontFamily, startsWith('Inter'));
  });
}
