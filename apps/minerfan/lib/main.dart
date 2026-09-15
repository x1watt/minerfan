import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'theme.dart';
import 'ui/contacts_page.dart';
import 'ui/dashboard.dart';
import 'ui/miners_page.dart';
import 'ui/settings_page.dart';
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

/// Four places: the dashboard, the miners (each with its own page), the
/// wallets and the app settings.
class Home extends StatefulWidget {
  final AppController app;
  const Home({super.key, required this.app});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _index = 0;

  static const _destinations = [
    (Icons.dashboard_outlined, Icons.dashboard, 'Dashboard'),
    (Icons.memory_outlined, Icons.memory, 'Miners'),
    (Icons.account_balance_wallet_outlined, Icons.account_balance_wallet, 'Wallets'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final pages = [DashboardPage(app), MinersPage(app), WalletsPage(app), SettingsPage(app)];
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
