import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/assistant/providers/assistant_provider.dart';

class MainShell extends ConsumerWidget {
  final Widget child;
  const MainShell({super.key, required this.child});

  int _selectedIndex(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    if (location.startsWith('/trips')) return 0;
    if (location.startsWith('/wallet')) return 1;
    if (location.startsWith('/assistant')) return 2;
    if (location.startsWith('/profile')) return 3;
    return 0;
  }

  /// Extrait le tripId de la route courante si elle matche `/trips/:id` ou
  /// `/trips/:id/*`. Retourne `null` pour `/trips`, `/trips/create`, ou
  /// toute route hors contexte voyage — dans ce cas l'assistant garde son
  /// comportement default (`defaultAssistantTripId`).
  String? _currentTripId(BuildContext context) {
    final path = GoRouterState.of(context).uri.path;
    final match = RegExp(r'^/trips/([^/]+)(?:/.*)?$').firstMatch(path);
    final id = match?.group(1);
    if (id == null || id.isEmpty || id == 'create') return null;
    return id;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: child,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _NavItem(icon: '🏠', label: 'Voyages', active: _selectedIndex(context) == 0, onTap: () => context.go('/trips')),
                _NavItem(icon: '💳', label: 'Wallet', active: _selectedIndex(context) == 1, onTap: () => context.go('/wallet')),
                _NavItem(icon: '💬', label: 'Assistant', active: _selectedIndex(context) == 2, onTap: () {
                  final tripId = _currentTripId(context);
                  if (tripId != null) {
                    ref.read(selectedAssistantTripIdProvider.notifier).state = tripId;
                  }
                  context.go('/assistant');
                }),
                _NavItem(icon: '👤', label: 'Profil', active: _selectedIndex(context) == 3, onTap: () => context.go('/profile')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final String icon, label;
  final bool active;
  final VoidCallback onTap;
  const _NavItem({required this.icon, required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(icon, style: const TextStyle(fontSize: 22)),
        const SizedBox(height: 3),
        Text(label, style: TextStyle(fontSize: 10, color: active ? AppColors.primary : AppColors.textSecondary, fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
      ],
    ),
  );
}
