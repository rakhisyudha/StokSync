import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/theme/appearance_controller.dart';

void main() {
  test('defaults to System and persists a changed preference', () async {
    final store = MemoryAppearanceStore();
    final controller = AppearanceController(store: store);

    expect(controller.preference, AppearancePreference.system);
    expect(controller.themeMode.name, 'system');

    await controller.setPreference(AppearancePreference.dark);

    expect(controller.preference, AppearancePreference.dark);
    expect(controller.themeMode.name, 'dark');
    expect(await store.read(), AppearancePreference.dark);
    controller.dispose();
  });

  test('loads a saved preference', () async {
    final controller = await AppearanceController.load(
      store: MemoryAppearanceStore(AppearancePreference.light),
    );

    expect(controller.preference, AppearancePreference.light);
    expect(controller.themeMode.name, 'light');
    controller.dispose();
  });
}
