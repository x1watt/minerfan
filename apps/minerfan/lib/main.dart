import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'desktop.dart';
import 'theme.dart';
import 'ui/contacts_page.dart';
import 'ui/dashboard.dart';
import 'ui/miners_page.dart';
import 'ui/settings_page.dart';
import 'ui/shop_page.dart';
import 'ui/wallets_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  migrateDataDir();
  final app = AppController();
  app.load();
  runApp(MinerfanApp(app: app));
}

class MinerfanApp extends StatelessWidget {
  final AppController app;
  const MinerfanApp({super.key, required this.app});

  /// One theme per accent color: the app rebuilds on every status (every
  /// 2 s), and an equal but new theme each time would still cost a full
  /// theme comparison, or an animation if any part compared unequal.
  static final Map<int, ThemeData> _themes = {};

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final theme = _themes.putIfAbsent(app.settings.accent, () => blackTheme(Color(app.settings.accent)));
        return MaterialApp(
          title: 'minerfan',
          debugShowCheckedModeBanner: false,
          theme: theme,
          darkTheme: theme,
          themeMode: ThemeMode.dark,
          home: Home(app: app),
        );
      },
    );
  }
}

/// Five places: the dashboard, the miners (each with its own page), the
/// wallets, the shop and the app settings.
class Home extends StatefulWidget {
  final AppController app;
  const Home({super.key, required this.app});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _index = 0;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    if (Desktop.supported) Desktop.onClose(_closeRequested);
  }

  /// The close button was pressed and the runner left the decision here:
  /// quit outright when that is the setting, otherwise ask once.
  Future<void> _closeRequested(String action) async {
    final app = widget.app;
    if (action == CloseAction.quit.name) {
      await app.quit();
      return;
    }
    if (_closing) return;
    _closing = true;
    try {
      var remember = false;
      final choice = await showDialog<CloseAction>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Close minerfan?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text(
              'minerfan can keep mining in the dock, or stop the miners and quit. Quitting saves what the '
              'miners and wallets have done so far.',
            ),
            StatefulBuilder(
              builder: (_, setLocal) => CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Do this from now on'),
                value: remember,
                onChanged: (v) => setLocal(() => remember = v ?? false),
              ),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, CloseAction.dock), child: const Text('Keep mining')),
            FilledButton(onPressed: () => Navigator.pop(c, CloseAction.quit), child: const Text('Quit minerfan')),
          ],
        ),
      );
      if (choice == null) return;
      if (remember) app.setCloseAction(choice);
      if (choice == CloseAction.quit) {
        await app.quit();
      } else {
        await Desktop.minimize();
      }
    } finally {
      _closing = false;
    }
  }

  static const _destinations = [
    (Icons.dashboard_outlined, Icons.dashboard, 'Dashboard'),
    (Icons.memory_outlined, Icons.memory, 'Miners'),
    (Icons.account_balance_wallet_outlined, Icons.account_balance_wallet, 'Wallets'),
    (Icons.storefront_outlined, Icons.storefront, 'Shop'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final pages = [DashboardPage(app), MinersPage(app), WalletsPage(app), ShopPage(app), SettingsPage(app)];
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final body = SafeArea(child: pages[_index]);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'minerfan',
          style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary),
        ),
        actions: [
          IconButton(
            tooltip: 'Contacts',
            icon: const Icon(Icons.contacts_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ContactsPage(app))),
          ),
        ],
      ),
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  destinations: [
                    for (final (icon, selected, label) in _destinations)
                      NavigationRailDestination(icon: Icon(icon), selectedIcon: Icon(selected), label: Text(label)),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            )
          : body,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (final (icon, selected, label) in _destinations)
                  NavigationDestination(icon: Icon(icon), selectedIcon: Icon(selected), label: label),
              ],
            ),
    );
  }
}
