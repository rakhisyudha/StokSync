import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const appearancePreferenceKey = 'stoksync.appearance.v1';

enum AppearancePreference {
  system,
  light,
  dark;

  ThemeMode get themeMode => switch (this) {
    AppearancePreference.system => ThemeMode.system,
    AppearancePreference.light => ThemeMode.light,
    AppearancePreference.dark => ThemeMode.dark,
  };

  String get label => switch (this) {
    AppearancePreference.system => 'System',
    AppearancePreference.light => 'Light',
    AppearancePreference.dark => 'Dark',
  };

  String get description => switch (this) {
    AppearancePreference.system => 'Follow the device appearance setting.',
    AppearancePreference.light => 'Use a bright, high-clarity interface.',
    AppearancePreference.dark =>
      'Use a focused dark interface for low-light work.',
  };

  static AppearancePreference fromStorage(String? value) {
    return switch (value) {
      'light' => AppearancePreference.light,
      'dark' => AppearancePreference.dark,
      _ => AppearancePreference.system,
    };
  }
}

abstract interface class AppearanceStore {
  Future<AppearancePreference?> read();

  Future<void> write(AppearancePreference preference);
}

final class SharedPreferencesAppearanceStore implements AppearanceStore {
  const SharedPreferencesAppearanceStore();

  @override
  Future<AppearancePreference?> read() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getString(appearancePreferenceKey);
    return value == null ? null : AppearancePreference.fromStorage(value);
  }

  @override
  Future<void> write(AppearancePreference preference) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(appearancePreferenceKey, preference.name);
  }
}

final class MemoryAppearanceStore implements AppearanceStore {
  MemoryAppearanceStore([this._preference]);

  AppearancePreference? _preference;

  @override
  Future<AppearancePreference?> read() async => _preference;

  @override
  Future<void> write(AppearancePreference preference) async {
    _preference = preference;
  }
}

final class AppearanceController extends ChangeNotifier {
  AppearanceController({
    required AppearanceStore store,
    AppearancePreference initial = AppearancePreference.system,
  }) : _store = store,
       _preference = initial;

  factory AppearanceController.inMemory({
    AppearancePreference initial = AppearancePreference.system,
  }) {
    return AppearanceController(
      store: MemoryAppearanceStore(initial),
      initial: initial,
    );
  }

  static Future<AppearanceController> load({
    AppearanceStore store = const SharedPreferencesAppearanceStore(),
  }) async {
    try {
      final saved = await store.read();
      return AppearanceController(
        store: store,
        initial: saved ?? AppearancePreference.system,
      );
    } on Object {
      return AppearanceController(store: store);
    }
  }

  final AppearanceStore _store;
  AppearancePreference _preference;

  AppearancePreference get preference => _preference;

  ThemeMode get themeMode => _preference.themeMode;

  Future<void> setPreference(AppearancePreference preference) async {
    if (_preference == preference) {
      return;
    }
    _preference = preference;
    notifyListeners();
    try {
      await _store.write(preference);
    } on Object {
      // Keep the current visual preference active for this session even when
      // platform preferences are temporarily unavailable.
    }
  }
}
