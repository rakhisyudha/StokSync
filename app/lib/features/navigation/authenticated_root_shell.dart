import 'package:flutter/material.dart';

import '../../core/theme/appearance_controller.dart';
import '../movements/movement_destination_page.dart';
import '../products/product_pages.dart';
import '../settings/settings_page.dart';
import '../sync/conflict_pages.dart';
import '../sync/sync_status_widgets.dart';

/// The authenticated app shell and its four primary destinations.
///
/// Settings is intentionally a shell action rather than a fifth primary tab so
/// Products, Movements, Sync, and Conflicts remain the main workflow.
class AuthenticatedRootShell extends StatefulWidget {
  const AuthenticatedRootShell({super.key, this.appearanceController});

  final AppearanceController? appearanceController;

  @override
  State<AuthenticatedRootShell> createState() => _AuthenticatedRootShellState();
}

class _AuthenticatedRootShellState extends State<AuthenticatedRootShell> {
  var _selectedIndex = 0;
  late final AppearanceController _appearanceController;
  var _ownsAppearanceController = false;

  static const _destinations = <NavigationDestination>[
    NavigationDestination(
      key: Key('products-navigation-destination'),
      icon: Icon(Icons.inventory_2_outlined),
      selectedIcon: Icon(Icons.inventory_2),
      label: 'Products',
    ),
    NavigationDestination(
      key: Key('movements-navigation-destination'),
      icon: Icon(Icons.swap_vert_outlined),
      selectedIcon: Icon(Icons.swap_vert),
      label: 'Movements',
    ),
    NavigationDestination(
      key: Key('sync-navigation-destination'),
      icon: Icon(Icons.sync_outlined),
      selectedIcon: Icon(Icons.sync),
      label: 'Sync',
    ),
    NavigationDestination(
      key: Key('conflicts-navigation-destination'),
      icon: Icon(Icons.warning_amber_outlined),
      selectedIcon: Icon(Icons.warning_amber),
      label: 'Conflicts',
    ),
  ];

  static const _pages = <Widget>[
    KeyedSubtree(key: Key('products-destination'), child: ProductBrowsePage()),
    KeyedSubtree(
      key: Key('movements-destination'),
      child: MovementDestinationPage(),
    ),
    KeyedSubtree(key: Key('sync-destination'), child: SyncStatusDetailPage()),
    KeyedSubtree(key: Key('conflicts-destination'), child: ConflictListPage()),
  ];

  @override
  void initState() {
    super.initState();
    final controller = widget.appearanceController;
    if (controller == null) {
      _appearanceController = AppearanceController.inMemory();
      _ownsAppearanceController = true;
    } else {
      _appearanceController = controller;
    }
  }

  @override
  void dispose() {
    if (_ownsAppearanceController) {
      _appearanceController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: IndexedStack(
        key: const Key('authenticated-destination-stack'),
        index: _selectedIndex,
        children: _pages,
      ),
      bottomNavigationBar: Material(
        color: scheme.surface,
        elevation: 2,
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              Expanded(
                child: NavigationBar(
                  key: const Key('authenticated-navigation-bar'),
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: (index) {
                    setState(() => _selectedIndex = index);
                  },
                  destinations: _destinations,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: IconButton(
                  key: const Key('open-settings-button'),
                  tooltip: 'Settings',
                  icon: const Icon(Icons.settings_outlined),
                  color: scheme.onSurfaceVariant,
                  onPressed: _openSettings,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openSettings() {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SettingsPage(controller: _appearanceController),
      ),
    );
  }
}
