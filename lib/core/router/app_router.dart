import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/auth/screens/onboarding_screen.dart';
import 'package:voyage/features/auth/screens/login_screen.dart';
import 'package:voyage/features/auth/screens/register_screen.dart';
import 'package:voyage/features/auth/screens/reset_password_screen.dart';
import 'package:voyage/features/onboarding/screens/traveler_type_screen.dart';
import 'package:voyage/features/onboarding/screens/interests_screen.dart';
import 'package:voyage/features/onboarding/screens/destination_screen.dart';
import 'package:voyage/features/trips/screens/trips_screen.dart';
import 'package:voyage/features/trips/screens/trip_detail_screen.dart';
import 'package:voyage/features/trips/screens/create_trip_screen.dart';
import 'package:voyage/features/planning/screens/planning_screen.dart';
import 'package:voyage/features/map/screens/trip_map_screen.dart';
import 'package:voyage/features/wallet/screens/wallet_screen.dart';
import 'package:voyage/features/assistant/screens/assistant_screen.dart';
import 'package:voyage/features/profile/screens/profile_screen.dart';
import 'package:voyage/shared/widgets/main_shell.dart';

// Notifier qui écoute l'auth sans recréer le router
class _AuthNotifier extends ChangeNotifier {
  _AuthNotifier(Ref ref) {
    ref.listen(authStateProvider, (_, __) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final notifier = _AuthNotifier(ref);

  return GoRouter(
    initialLocation: '/onboarding',
    refreshListenable: notifier,
    errorBuilder: (context, state) => _NotFoundScreen(location: state.matchedLocation),
    redirect: (context, state) {
      final authState = ref.read(authStateProvider);
      if (authState.isLoading) return null;

      final isAuthenticated = authState.valueOrNull?.session != null;
      final loc = state.matchedLocation;

      const onboardingPages = [
        '/onboarding/traveler-type',
        '/onboarding/interests',
        '/onboarding/destination',
      ];

      // /reset-password est un écran spécial : accessible qu'on soit connecté (session
      // de récupération établie par deep link) ou non (erreur → redirige login).
      // On laisse passer dans tous les cas, le screen gère sa propre logique.
      if (loc == '/reset-password') return null;

      // Utilisateur connecté sur login/register/intro → trips
      if (isAuthenticated && (loc == '/login' || loc == '/register' || loc == '/onboarding')) {
        return '/trips';
      }

      // Utilisateur connecté sur pages d'onboarding → laisser passer
      if (isAuthenticated && onboardingPages.contains(loc)) return null;

      // Utilisateur non connecté sur route protégée → login
      if (!isAuthenticated && !onboardingPages.contains(loc) &&
          loc != '/onboarding' && loc != '/login' && loc != '/register') {
        return '/login';
      }

      return null;
    },
    routes: [
      GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingScreen()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, __) => const RegisterScreen()),
      GoRoute(path: '/reset-password', builder: (_, __) => const ResetPasswordScreen()),
      GoRoute(path: '/onboarding/traveler-type', builder: (_, __) => const TravelerTypeScreen()),
      GoRoute(path: '/onboarding/interests', builder: (_, __) => const InterestsScreen()),
      GoRoute(path: '/onboarding/destination', builder: (_, __) => const DestinationScreen()),
      GoRoute(path: '/trips/create', builder: (_, __) => const CreateTripScreen()),
      ShellRoute(
        builder: (context, state, child) => MainShell(child: child),
        routes: [
          GoRoute(path: '/trips', builder: (_, __) => const TripsScreen()),
          GoRoute(
            path: '/trips/:id',
            builder: (_, state) => TripDetailScreen(tripId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: '/trips/:id/planning',
            builder: (_, state) => PlanningScreen(tripId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: '/trips/:id/map',
            builder: (_, state) => TripMapScreen(tripId: state.pathParameters['id']!),
          ),
          GoRoute(path: '/wallet', builder: (_, __) => const WalletScreen()),
          // Vue Wallet filtrée sur un voyage (depuis le détail voyage). Réutilise
          // WalletScreen avec filterTripId pré-rempli — le filtre par voyage est
          // alors caché (déjà imposé par la route).
          GoRoute(
            path: '/trips/:id/documents',
            builder: (_, state) => WalletScreen(filterTripId: state.pathParameters['id']!),
          ),
          GoRoute(path: '/assistant', builder: (_, __) => const AssistantScreen()),
          GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
        ],
      ),
    ],
  );
});

class _NotFoundScreen extends StatelessWidget {
  final String location;
  const _NotFoundScreen({required this.location});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('🚧', style: TextStyle(fontSize: 64), textAlign: TextAlign.center),
              const SizedBox(height: 20),
              const Text(
                'Cette page n\'existe pas encore',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'La route "$location" n\'est pas disponible pour l\'instant.',
                style: const TextStyle(fontSize: 13, color: Colors.black54, height: 1.5),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                onPressed: () => context.go('/trips'),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Retour à mes voyages'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
