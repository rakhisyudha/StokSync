import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/theme/appearance_controller.dart';
import 'package:stoksync/core/theme/app_theme.dart';
import 'package:stoksync/features/settings/settings_page.dart';

void main() {
  testWidgets('selects and immediately displays the appearance preference', (
    tester,
  ) async {
    final controller = AppearanceController.inMemory();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildStokSyncTheme(Brightness.light),
        home: SettingsPage(controller: controller),
      ),
    );

    expect(find.byKey(const Key('appearance-settings-card')), findsOneWidget);
    expect(find.byKey(const Key('appearance-option-system')), findsOneWidget);

    await tester.tap(find.byKey(const Key('appearance-option-dark')));
    await tester.pump();

    expect(controller.preference, AppearancePreference.dark);
    final option = tester.widget<ListTile>(
      find.byKey(const Key('appearance-option-dark')),
    );
    expect(option.selected, isTrue);
    controller.dispose();
  });
}
