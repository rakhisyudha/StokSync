import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('builds the deliberate light and dark SaaS schemes', () {
    final lightTheme = buildStokSyncTheme(Brightness.light);
    final darkTheme = buildStokSyncTheme(Brightness.dark);

    expect(lightTheme.useMaterial3, isTrue);
    expect(darkTheme.useMaterial3, isTrue);
    expect(lightTheme.colorScheme.primary, stoksyncPrimaryLight);
    expect(darkTheme.colorScheme.primary, stoksyncPrimaryDark);
    expect(lightTheme.colorScheme.surface, stoksyncSurfaceLight);
    expect(darkTheme.colorScheme.surface, stoksyncSurfaceDark);
    expect(lightTheme.colorScheme.onSurface, stoksyncOnSurfaceLight);
    expect(darkTheme.colorScheme.onSurface, stoksyncOnSurfaceDark);
    expect(lightTheme.extension<StokSyncSemanticColors>(), isNotNull);
    expect(darkTheme.extension<StokSyncSemanticColors>(), isNotNull);
    expect(lightTheme.textTheme.bodyMedium?.fontFamily, startsWith('Inter'));
    expect(darkTheme.textTheme.bodyMedium?.fontFamily, startsWith('Inter'));
  });
}
