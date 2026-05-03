import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyage/core/providers/currency_provider.dart';
import 'package:voyage/core/providers/offline_provider.dart';
import 'package:voyage/core/services/currency_service.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';

enum _TripFilter { upcoming, ongoing, past }

List<Trip> _applyFilter(List<Trip> trips, _TripFilter filter, DateTime today) {
  return trips.where((t) {
    final startDay = DateTime(t.startDate.year, t.startDate.month, t.startDate.day);
    final endDay = DateTime(t.endDate.year, t.endDate.month, t.endDate.day);
    switch (filter) {
      case _TripFilter.upcoming:
        return startDay.isAfter(today);
      case _TripFilter.ongoing:
        return !startDay.isAfter(today) && !endDay.isBefore(today);
      case _TripFilter.past:
        return endDay.isBefore(today);
    }
  }).toList();
}

class TripsScreen extends ConsumerStatefulWidget {
  const TripsScreen({super.key});

  @override
  ConsumerState<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends ConsumerState<TripsScreen> {
  _TripFilter _filter = _TripFilter.upcoming;

  /// Wording humanisé du message d'erreur de suppression. L'erreur brute
  /// `ClientException with SocketException: Failed host lookup: ...` est
  /// incompréhensible — on classifie selon le type pour donner une
  /// explication actionnable.
  String _humanizeDeleteError(Object e) {
    final raw = e.toString();
    if (raw.contains('SocketException') ||
        raw.contains('Failed host lookup') ||
        raw.contains('TimeoutException') ||
        raw.contains('ClientException') ||
        raw.contains('Connection reset') ||
        raw.contains('Connection refused') ||
        raw.contains('Network is unreachable') ||
        raw.contains('No address associated')) {
      return 'Pas de connexion internet. Vérifie ta connexion et réessaie.';
    }
    return 'Quelque chose a coincé lors de la suppression. Réessaie dans un instant.';
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final tripsAsync = ref.watch(tripsProvider);
    final firstName = (user?.userMetadata?['full_name'] as String? ?? 'Voyageur').split(' ').first;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final allTrips = tripsAsync.valueOrNull ?? const <Trip>[];
    final countByFilter = {
      _TripFilter.upcoming: _applyFilter(allTrips, _TripFilter.upcoming, today).length,
      _TripFilter.ongoing: _applyFilter(allTrips, _TripFilter.ongoing, today).length,
      _TripFilter.past: _applyFilter(allTrips, _TripFilter.past, today).length,
    };

    final offline = ref.watch(isOfflineProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // Bandeau "hors ligne" : visible dès qu'un provider Trip a
            // fallback sur le cache local. Disparaît automatiquement quand
            // un fetch suivant réussit (provider reset à false). Wording
            // doux + icône cloud_off, couleur ambre cohérente avec les
            // autres warnings UX (TransportDocWarnings, etc.).
            if (offline)
              SliverToBoxAdapter(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: AppColors.accent.withValues(alpha: 0.15),
                  child: Row(
                    children: [
                      Icon(Icons.cloud_off, size: 16, color: AppColors.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Mode hors ligne — affichage depuis le cache local',
                          style: TextStyle(fontSize: 12, color: AppColors.textPrimary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                color: AppColors.surface,
                child: Row(
                  children: [
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Bonjour $firstName 👋', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                        const SizedBox(height: 2),
                        Text('Mes voyages', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                      ],
                    )),
                    // Bouton "+" pour créer un voyage. Grisé en mode hors
                    // ligne — la création nécessite Supabase (sauvegarde
                    // immédiate, pas de queue offline pour la beta).
                    GestureDetector(
                      onTap: offline
                          ? () => ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Pas de connexion internet. Reconnecte-toi pour créer un voyage.',
                                  ),
                                  duration: Duration(seconds: 4),
                                ),
                              )
                          : () => context.go('/onboarding/destination'),
                      child: Container(
                        width: 36, height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: offline ? AppColors.textSecondary.withValues(alpha: 0.3) : AppColors.accent,
                        ),
                        child: const Center(child: Icon(Icons.add, color: Colors.white, size: 20)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    _filterChip('À venir', _TripFilter.upcoming, countByFilter[_TripFilter.upcoming] ?? 0),
                    _filterChip('En cours', _TripFilter.ongoing, countByFilter[_TripFilter.ongoing] ?? 0),
                    _filterChip('Passés', _TripFilter.past, countByFilter[_TripFilter.past] ?? 0),
                  ]),
                ),
              ),
            ),
            tripsAsync.when(
              loading: () => const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => SliverFillRemaining(
                child: Center(child: Text('Erreur de chargement', style: TextStyle(color: AppColors.error))),
              ),
              data: (trips) {
                if (trips.isEmpty) {
                  return SliverFillRemaining(
                    child: _EmptyTrips(onTap: () => context.go('/onboarding/destination')),
                  );
                }
                final filtered = _applyFilter(trips, _filter, today);
                if (filtered.isEmpty) {
                  return SliverFillRemaining(
                    child: _EmptyFilterState(filter: _filter),
                  );
                }
                return SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final trip = filtered[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: Dismissible(
                              key: ValueKey(trip.id),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                padding: const EdgeInsets.only(right: 20),
                                decoration: BoxDecoration(
                                  color: AppColors.error,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                alignment: Alignment.centerRight,
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.delete_outline, color: Colors.white),
                                    SizedBox(width: 6),
                                    Text('Supprimer', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              ),
                              confirmDismiss: (_) async {
                                return await showDialog<bool>(
                                  context: context,
                                  builder: (dialogCtx) => AlertDialog(
                                    title: const Text('Supprimer ce voyage ?'),
                                    content: Text('« ${trip.title} » ainsi que toutes ses activités et trajets seront définitivement supprimés.'),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: const Text('Annuler')),
                                      TextButton(
                                        onPressed: () => Navigator.pop(dialogCtx, true),
                                        style: TextButton.styleFrom(foregroundColor: AppColors.error),
                                        child: const Text('Supprimer'),
                                      ),
                                    ],
                                  ),
                                ) ?? false;
                              },
                              onDismissed: (_) async {
                                final messenger = ScaffoldMessenger.of(context);
                                final navContext = context;
                                try {
                                  await deleteTripCascade(ref.read(supabaseProvider), trip.id);
                                  ref.invalidate(tripsProvider);
                                  ref.invalidate(hasTripsProvider);
                                  messenger.showSnackBar(
                                    SnackBar(content: Text('« ${trip.title} » supprimé.')),
                                  );
                                } catch (e, st) {
                                  // Suppression : un SnackBar court ne tient pas (le swipe + le
                                  // rebuild de la liste après invalidate fait disparaitre le
                                  // SnackBar avant lecture). On utilise un AlertDialog qui reste
                                  // jusqu'au dismissal manuel + texte sélectable pour copie. Log
                                  // console aussi (debugPrint = visible en `flutter run`).
                                  debugPrint('[trip-delete] échec suppression voyage ${trip.id} : $e');
                                  debugPrint('[trip-delete] stack: $st');
                                  ref.invalidate(tripsProvider);
                                  ref.invalidate(hasTripsProvider);
                                  if (!navContext.mounted) return;
                                  await showDialog<void>(
                                    context: navContext,
                                    builder: (dialogCtx) => AlertDialog(
                                      title: const Text('Erreur lors de la suppression'),
                                      content: SelectableText(_humanizeDeleteError(e)),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(dialogCtx),
                                          child: const Text('OK'),
                                        ),
                                      ],
                                    ),
                                  );
                                }
                              },
                              child: _TripCard(trip: trip, onTap: () => context.go('/trips/${trip.id}')),
                            ),
                          );
                        },
                        childCount: filtered.length,
                      ),
                    ),
                  );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(String label, _TripFilter value, int count) {
    final active = _filter == value;
    return GestureDetector(
      onTap: () => setState(() => _filter = value),
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppColors.primary : AppColors.primaryLight,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: active ? Colors.white : AppColors.primary)),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: active ? Colors.white.withValues(alpha: 0.25) : AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('$count', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: active ? Colors.white : AppColors.primary)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyFilterState extends StatelessWidget {
  final _TripFilter filter;
  const _EmptyFilterState({required this.filter});

  @override
  Widget build(BuildContext context) {
    final (emoji, title, subtitle) = switch (filter) {
      _TripFilter.upcoming => ('🗓️', 'Aucun voyage à venir', 'Prépare ta prochaine évasion — clique sur + pour en créer un.'),
      _TripFilter.ongoing => ('🧳', 'Aucun voyage en cours', 'Tu n\'as pas de voyage à cette date. Profite-en pour en préparer un !'),
      _TripFilter.past => ('📜', 'Aucun voyage passé', 'Les voyages archivés apparaîtront ici quand ils seront terminés.'),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 56)),
            const SizedBox(height: 16),
            Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            const SizedBox(height: 6),
            Text(subtitle, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.5)),
          ],
        ),
      ),
    );
  }
}

class _TripCard extends ConsumerWidget {
  final Trip trip;
  final VoidCallback onTap;
  const _TripCard({required this.trip, required this.onTap});

  String _countdown() {
    final now = DateTime.now();
    final diff = trip.startDate.difference(now).inDays;
    if (diff < 0) return 'Passé';
    if (diff == 0) return 'Aujourd\'hui';
    if (diff == 1) return 'Demain';
    return 'Dans $diff jours';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final budget = ref.watch(tripBudgetProvider(trip.id)).valueOrNull;
    final userCurrency = ref.watch(userCurrencyProvider);
    final budgetLabel = (budget != null && budget.total > 0)
        ? '~${CurrencyService.formatAmount(budget.total, userCurrency)}'
        : null;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 2)],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Container(
              height: 90,
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [Color(0xFF2563EB), Color(0xFF4F46E5)]),
              ),
              padding: const EdgeInsets.all(10),
              child: Stack(
                children: [
                  Positioned(
                    top: 0, right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(6)),
                      child: Text(_countdown(), style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
                    ),
                  ),
                  Align(alignment: Alignment.bottomLeft, child: Text(trip.coverEmoji, style: const TextStyle(fontSize: 28))),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(trip.title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text(trip.destination, style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text('📅 ${trip.durationDays} jours', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      if (budgetLabel != null) ...[
                        Text(' · ', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                        Text('💰 $budgetLabel', style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyTrips extends StatelessWidget {
  final VoidCallback onTap;
  const _EmptyTrips({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('✈️', style: TextStyle(fontSize: 64)),
            const SizedBox(height: 20),
            Text('Aucun voyage pour l\'instant', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            const SizedBox(height: 8),
            Text('Créez votre premier voyage et laissez Voyage construire votre planning sur mesure.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.5)),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: onTap,
              icon: const Icon(Icons.add),
              label: const Text('Créer mon premier voyage'),
            ),
          ],
        ),
      ),
    );
  }
}
