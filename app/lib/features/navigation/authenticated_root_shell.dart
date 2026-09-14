import 'package:flutter/material.dart';

import '../movements/movement_destination_page.dart';
import '../products/product_pages.dart';
import '../sync/conflict_pages.dart';
import '../sync/sync_status_widgets.dart';

/// The authenticated app shell and its four top-level destinations.
///
/// Feature pages remain responsible for their own pushed child routes. The
/// shell only owns the selected destination, so authentication and sync
/// orchestration can continue to be provided by the composition root.
class AuthenticatedRootShell extends StatefulWidget {
  const AuthenticatedRootShell({super.key});

  @override
  State<AuthenticatedRootShell> createState() => _AuthenticatedRootShellState();
}

class _AuthenticatedRootShellState extends State<AuthenticatedRootShell> {
  var _selectedIndex = 0;

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
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        key: const Key('authenticated-destination-stack'),
        index: _selectedIndex,
        children: _pages,
      ),
      bottomNavigationBar: NavigationBar(
        key: const Key('authenticated-navigation-bar'),
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() => _selectedIndex = index);
        },
        destinations: _destinations,
      ),
    );
  }
}
