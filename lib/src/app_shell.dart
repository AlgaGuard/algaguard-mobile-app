import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../main.dart'
    show AccountScreen, AlertsScreen, DevicesScreen, realtimeControllerProvider;
import 'history_screen.dart';
import 'home_dashboard_view.dart';

/// The authenticated app's top-level shell: a 5-tab bottom NavigationBar
/// (Home / Devices / History / Alerts / Profile) wrapping the tabs in an
/// IndexedStack so switching tabs never re-triggers each tab's own data
/// load. Replaces the old flat HomeScreen menu -- destinations that don't
/// map onto one of these 5 tabs live inside the Profile tab (AccountScreen)
/// as a grouped "More" list instead.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;

  static const _tabs = [
    HomeDashboardView(),
    DevicesScreen(),
    HistoryScreen(),
    AlertsScreen(),
    AccountScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(realtimeControllerProvider).start();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: IndexedStack(index: _index, children: _tabs),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _index,
      onDestinationSelected: (value) => setState(() => _index = value),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
        NavigationDestination(icon: Icon(Icons.memory_outlined), selectedIcon: Icon(Icons.memory), label: 'Devices'),
        NavigationDestination(icon: Icon(Icons.show_chart_outlined), selectedIcon: Icon(Icons.show_chart), label: 'History'),
        NavigationDestination(icon: Icon(Icons.notifications_outlined), selectedIcon: Icon(Icons.notifications), label: 'Alerts'),
        NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
      ],
    ),
  );
}
