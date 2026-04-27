import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/core/providers/currency_provider.dart';
import 'package:voyage/core/services/currency_service.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';
import 'package:voyage/features/trips/widgets/regional_loop_sheet.dart';
import 'package:voyage/features/trips/widgets/trip_edit_sheet.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';
import 'package:voyage/features/wallet/screens/wallet_screen.dart';
import 'package:voyage/features/wallet/widgets/document_form_sheet.dart';

class TripDetailScreen extends ConsumerWidget {
  final String tripId;
  const TripDetailScreen({super.key, required this.tripId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tripAsync = ref.watch(tripByIdProvider(tripId));

    return Scaffold(
      backgroundColor: AppColors.background,
      body: tripAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e', style: TextStyle(color: AppColors.error))),
        data: (trip) {
          if (trip == null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Voyage introuvable', style: TextStyle(fontSize: 16, color: AppColors.textSecondary)),
                  const SizedBox(height: 16),
                  TextButton(onPressed: () => context.go('/trips'), child: const Text('Retour aux voyages')),
                ],
              ),
            );
          }
          return _TripDetail(trip: trip);
        },
      ),
    );
  }
}

/// Statut d'avancement d'un voyage. Calculé à partir du Trip + de ses
/// dépendances (activités, étapes, kind de destination). Préparé extensible :
/// V1 = 3 statuts simples ; en V2 on pourra ajouter `inProgress`/`past` quand
/// on les voudra.
enum _TripStatus {
  /// Destination = pays/région ET aucune étape — l'utilisateur doit préciser
  /// au moins une ville pour que l'IA sache où chercher.
  toComplete,
  /// ≥1 étape définie ET 0 activité — l'utilisateur peut générer le planning.
  readyToPlan,
  /// ≥1 activité — le voyage est prêt à consulter / ajuster.
  ready,
}

class _TripDetail extends ConsumerStatefulWidget {
  final Trip trip;
  const _TripDetail({required this.trip});

  @override
  ConsumerState<_TripDetail> createState() => _TripDetailState();
}

class _TripDetailState extends ConsumerState<_TripDetail> {
  /// Type de destination détecté via Places autocomplete au boot. Sert à
  /// distinguer "destination ville" (auto-création possible d'étape par défaut)
  /// vs "destination pays/région" (nécessite des étapes explicites).
  /// `null` au boot = en cours de détection ; `'unknown'` = échec / saisie manuelle
  /// non présente dans Places. On traite `unknown` comme une ville par défaut
  /// (ne bloque rien), mais le statut "À compléter" ne se déclenche que pour
  /// `country`/`region` confirmés.
  String? _destinationKind;

  Trip get trip => widget.trip;

  static const _months = [
    'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
    'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
  ];

  @override
  void initState() {
    super.initState();
    _detectDestinationKind();
  }

  Future<void> _detectDestinationKind() async {
    final dest = trip.destination.trim();
    if (dest.isEmpty) {
      if (mounted) setState(() => _destinationKind = 'unknown');
      return;
    }
    try {
      final places = ref.read(placesServiceProvider);
      final results = await places.autocompleteDestinations(dest);
      if (!mounted) return;
      if (results.isEmpty) {
        setState(() => _destinationKind = 'unknown');
        return;
      }
      // Prend la 1ère suggestion dont le mainText matche exactement la destination
      // pour éviter les homonymies (cf. trip_edit_sheet._detectInitialKind).
      final exact = results.where((r) => r.mainText.toLowerCase() == dest.toLowerCase());
      final pick = exact.isNotEmpty ? exact.first : results.first;
      setState(() => _destinationKind = pick.kind);
    } catch (_) {
      if (mounted) setState(() => _destinationKind = 'unknown');
    }
  }

  /// Calcule le statut courant du voyage. `activitiesCount` vient d'un provider
  /// async — quand il est null (pas encore chargé), on ne montre pas de badge
  /// pour ne pas afficher "À compléter" puis "Voyage prêt" juste après le boot.
  _TripStatus? _computeStatus(int? activitiesCount) {
    if (activitiesCount == null) return null;
    if (activitiesCount > 0) return _TripStatus.ready;
    final hasSegments = trip.itinerarySegments.isNotEmpty;
    final destIsLarge = _destinationKind == 'country' || _destinationKind == 'region';
    if (destIsLarge && !hasSegments) return _TripStatus.toComplete;
    return _TripStatus.readyToPlan;
  }

  String _formatRange() {
    final s = trip.startDate;
    final e = trip.endDate;
    final sameMonth = s.month == e.month && s.year == e.year;
    if (sameMonth) {
      return '${s.day} – ${e.day} ${_months[e.month - 1]} ${e.year} • ${trip.durationDays} jours';
    }
    return '${s.day} ${_months[s.month - 1]} – ${e.day} ${_months[e.month - 1]} ${e.year} • ${trip.durationDays} jours';
  }

  /// Sous-titre court pour le header : "21 jours · 11–31 mai 2026".
  String _headerSubtitle() {
    final s = trip.startDate;
    final e = trip.endDate;
    final sameMonth = s.month == e.month && s.year == e.year;
    final dates = sameMonth
        ? '${s.day}–${e.day} ${_months[e.month - 1]} ${e.year}'
        : '${s.day} ${_months[s.month - 1]} – ${e.day} ${_months[e.month - 1]} ${e.year}';
    return '${trip.durationDays} jour${trip.durationDays > 1 ? "s" : ""} · $dates';
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  /// Mode "clé en main" V1 — pour l'instant on chaîne uniquement la 1ère moitié
  /// (boucle régionale qui propose des villes via Gemini). La 2e moitié (génération
  /// auto du planning) sera la tranche 3 du redesign : pour l'instant, après
  /// création des étapes, on redirige vers le planning où l'utilisateur peut
  /// cliquer "Suggérer". Pas idéal UX mais ça compile et ne casse rien.
  Future<void> _runTurnkeyItinerary() async {
    final segments = await openRegionalLoopSheet(
      context, ref,
      mainDestination: trip.destination,
      durationDays: trip.durationDays,
      travelerType: trip.travelerType,
      interests: trip.interests ?? const [],
    );
    if (segments == null || segments.isEmpty || !mounted) return;
    try {
      await ref.read(supabaseProvider).from('trips').update({
        'itinerary_segments': segments.map((s) => s.toJson()).toList(),
      }).eq('id', trip.id);
      ref.invalidate(tripsProvider);
      ref.invalidate(tripByIdProvider(trip.id));
      if (!mounted) return;
      // TODO tranche 3 : enchaîner avec la génération du planning ici (loader
      // 1/2 → 2/2). Pour l'instant on navigue, l'utilisateur clique "Suggérer".
      context.go('/trips/${trip.id}/planning');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _confirmDeleteTrip(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Supprimer ce voyage ?'),
        content: Text(
          '« ${trip.title} » ainsi que toutes ses activités et trajets seront '
          'définitivement supprimés. Les documents (hôtels, vols, billets) restent '
          'dans ton wallet et peuvent être réutilisés sur un autre voyage. Action irréversible.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await deleteTripCascade(ref.read(supabaseProvider), trip.id);
      ref.invalidate(tripsProvider);
      ref.invalidate(hasTripsProvider);
      ref.invalidate(documentsProvider);
      messenger.showSnackBar(SnackBar(content: Text('« ${trip.title} » supprimé.')));
      router.go('/trips');
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final docsAsync = ref.watch(tripDocumentsProvider(trip.id));
    final docs = docsAsync.valueOrNull ?? const <TripDocument>[];
    final hotelsAsync = ref.watch(tripHotelsProvider(trip.id));
    final hotels = hotelsAsync.valueOrNull ?? const <TripDocument>[];
    final others = docs.where((d) => d.category != DocumentCategory.hotel).toList();

    final budget = ref.watch(tripBudgetProvider(trip.id)).valueOrNull;
    final userCurrency = ref.watch(userCurrencyProvider);
    final budgetLabel = (budget != null && budget.total > 0)
        ? '~${CurrencyService.formatAmount(budget.total, userCurrency)}'
        : null;

    final activitiesAsync = ref.watch(tripActivitiesProvider(trip.id));
    final activitiesCount = activitiesAsync.valueOrNull?.length;
    final status = _computeStatus(activitiesCount);

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          // Header plus haut pour accommoder emoji 64px aligné gauche + titre
          // + sous-titre + badge statut. 240px laisse respirer sans déborder.
          expandedHeight: 240,
          pinned: true,
          backgroundColor: AppColors.primary,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => context.go('/trips'),
          ),
          actions: [
            // Bouton Modifier visible : icône + texte (au-delà des 600px on
            // peut afficher le label, sinon icon seul). Plus parlant que la
            // simple icône crayon de l'ancienne version.
            TextButton.icon(
              onPressed: () => openTripEditSheet(context, ref, trip: trip),
              icon: const Icon(Icons.edit_outlined, color: Colors.white, size: 18),
              label: const Text('Modifier', style: TextStyle(color: Colors.white)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
            // PopupMenu kebab conservé pour l'instant (Supprimer reste accessible).
            // Sera retiré en tranche 6 quand la section Actions du bas sera
            // ajoutée avec une icône corbeille séparée.
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              tooltip: 'Options',
              onSelected: (v) {
                if (v == 'delete') _confirmDeleteTrip(context, ref);
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline, size: 18, color: AppColors.error),
                      const SizedBox(width: 10),
                      const Text('Supprimer le voyage'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          flexibleSpace: FlexibleSpaceBar(
            // Titre compact pinned (visible quand collapsed). On garde juste
            // le titre + budget pour ne pas surcharger la barre repliée.
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    trip.title,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (budgetLabel != null) ...[
                  const SizedBox(width: 12),
                  Text(budgetLabel, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ],
              ],
            ),
            titlePadding: const EdgeInsetsDirectional.only(start: 56, bottom: 14, end: 16),
            // Background expanded : gradient subtil bleu primary → primaryDark
            // (10% d'opacité de différence — plus que ça vire kitsch). Emoji
            // 64px aligné gauche, titre grand dessous, sous-titre durée/dates,
            // badge statut outline. Layout mobile-first, padding généreux pour
            // éviter de toucher les actions du SliverAppBar.
            background: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppColors.primary, AppColors.primaryDark],
                    ),
                  ),
                ),
                // SafeArea + padding pour ne pas chevaucher les actions
                // (AppBar fait ~56px de haut + status bar). On positionne
                // le contenu dans la moitié basse de l'expanded.
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 56,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(trip.coverEmoji, style: const TextStyle(fontSize: 56)),
                      const SizedBox(height: 8),
                      Text(
                        trip.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 26,
                          height: 1.1,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              _headerSubtitle(),
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (status != null) ...[
                            const SizedBox(width: 10),
                            _TripStatusBadge(status: status),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.all(24),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              // Card "Prochaine étape" : guide l'utilisateur sur la prochaine
              // action selon l'état du voyage (3 cas dynamiques mappés sur le
              // statut). Tant que `status` n'est pas chargé (kind en cours de
              // détection ou activitiesAsync loading), on skip — évite le flicker
              // "À compléter" → "Voyage prêt" au boot.
              if (status != null)
                _NextStepCard(
                  trip: trip,
                  nextCase: switch (status) {
                    _TripStatus.toComplete => _NextStepCase.discoverItinerary,
                    _TripStatus.readyToPlan => _NextStepCase.generatePlan,
                    _TripStatus.ready => _NextStepCase.viewPlan,
                  },
                  onPrimary: switch (status) {
                    _TripStatus.toComplete => _runTurnkeyItinerary,
                    _TripStatus.readyToPlan => () => context.go('/trips/${trip.id}/planning'),
                    _TripStatus.ready => () => context.go('/trips/${trip.id}/planning'),
                  },
                  onSecondary: status == _TripStatus.toComplete
                      ? () => openTripEditSheet(context, ref, trip: trip)
                      : null,
                ),
              _InfoRow(icon: Icons.location_on, text: trip.destination),
              const SizedBox(height: 12),
              _InfoRow(icon: Icons.calendar_today, text: _formatRange()),
              if (trip.travelers.isNotEmpty) ...[
                const SizedBox(height: 12),
                _InfoRow(
                  icon: Icons.group,
                  text: '${trip.travelers.length} voyageur${trip.travelers.length > 1 ? 's' : ''} · ${trip.travelers.map((t) => '${t.name} (${t.age})').join(', ')}',
                ),
              ],
              const SizedBox(height: 24),

              // Bloc Hébergement(s) — carrousel swipeable (une carte visible à la fois)
              // pour que le bouton Planning reste proche du haut même sur un road trip 15 jours.
              if (hotels.isEmpty)
                OutlinedButton.icon(
                  onPressed: () => openDocumentFormSheet(
                    context, ref,
                    initialTripId: trip.id,
                    initialCategory: DocumentCategory.hotel,
                  ),
                  icon: const Icon(Icons.hotel_outlined),
                  label: const Text('Ajouter un hébergement'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 52),
                    foregroundColor: AppColors.primary,
                    side: BorderSide(color: AppColors.primary),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                )
              else ...[
                _HotelsCarousel(hotels: hotels, fmtDate: _fmtDate),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => openDocumentFormSheet(
                    context, ref,
                    initialTripId: trip.id,
                    initialCategory: DocumentCategory.hotel,
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Ajouter un autre hébergement'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 44),
                    foregroundColor: AppColors.primary,
                    side: BorderSide(color: AppColors.border),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],

              // Autres documents du voyage
              if (others.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('AUTRES DOCUMENTS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                const SizedBox(height: 10),
                for (final d in others)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: DocumentCard(
                      doc: d,
                      onTap: () => openDocumentFormSheet(context, ref, existing: d),
                    ),
                  ),
              ],

              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: () => openDocumentFormSheet(context, ref, initialTripId: trip.id),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Ajouter un document'),
                style: TextButton.styleFrom(foregroundColor: AppColors.primary),
              ),
              const SizedBox(height: 16),

              // Cards principales avec sous-texte dynamique : transforme les
              // boutons "navigation" en "résumé d'état". Plus engageant + plus
              // utile (l'utilisateur sait déjà ce qu'il y a derrière).
              _RichActionCard(
                icon: Icons.calendar_month,
                label: 'Planning',
                subtitle: () {
                  if (activitiesCount == null) return 'Chargement...';
                  if (activitiesCount == 0) return 'Aucun planning pour l\'instant';
                  // Compte les jours uniques avec ≥1 activité (pas le total
                  // d'activités). Plus parlant : "8 jours planifiés" > "40 activités".
                  final activities = activitiesAsync.valueOrNull ?? const [];
                  final daysWith = activities
                      .map((a) => DateTime(a.dayDate.year, a.dayDate.month, a.dayDate.day))
                      .toSet()
                      .length;
                  return '$daysWith jour${daysWith > 1 ? "s" : ""} planifié${daysWith > 1 ? "s" : ""}';
                }(),
                onTap: () => context.go('/trips/${trip.id}/planning'),
              ),
              const SizedBox(height: 12),
              _RichActionCard(
                icon: Icons.wallet,
                label: 'Documents',
                subtitle: 'Billets, hôtels, confirmations',
                onTap: () => context.go('/wallet'),
              ),
              const SizedBox(height: 12),
              _RichActionCard(
                icon: Icons.map,
                label: 'Carte',
                subtitle: (activitiesCount == null || activitiesCount == 0)
                    ? 'Tes lieux apparaîtront ici dès que tu auras un planning.'
                    : 'Voir les lieux de ton voyage',
                onTap: () => context.go('/trips/${trip.id}/map'),
              ),
            ]),
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.primary, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text, style: TextStyle(color: AppColors.textSecondary, fontSize: 15)),
        ),
      ],
    );
  }
}

/// Carrousel horizontal des hébergements : une seule carte visible, swipe pour changer.
/// Démarre sur l'hôtel qui couvre ce soir (ou le premier à venir).
class _HotelsCarousel extends StatefulWidget {
  final List<TripDocument> hotels;
  final String Function(DateTime) fmtDate;
  const _HotelsCarousel({required this.hotels, required this.fmtDate});

  @override
  State<_HotelsCarousel> createState() => _HotelsCarouselState();
}

class _HotelsCarouselState extends State<_HotelsCarousel> {
  late final PageController _controller;
  late int _currentPage;

  static const double _cardHeight = 124;

  int _initialIndex() {
    final today = DateTime.now();
    final d = DateTime(today.year, today.month, today.day);
    // 1. Hôtel couvrant aujourd'hui
    for (var i = 0; i < widget.hotels.length; i++) {
      final h = widget.hotels[i];
      final ci = h.metadata['check_in'] is String ? DateTime.tryParse(h.metadata['check_in'] as String) : null;
      final co = h.metadata['check_out'] is String ? DateTime.tryParse(h.metadata['check_out'] as String) : null;
      if (ci == null || co == null) continue;
      final start = DateTime(ci.year, ci.month, ci.day);
      final end = DateTime(co.year, co.month, co.day);
      if (!d.isBefore(start) && !d.isAfter(end)) return i;
    }
    // 2. Premier hôtel à venir (check_in ≥ aujourd'hui)
    for (var i = 0; i < widget.hotels.length; i++) {
      final h = widget.hotels[i];
      final ci = h.metadata['check_in'] is String ? DateTime.tryParse(h.metadata['check_in'] as String) : null;
      if (ci == null) continue;
      final start = DateTime(ci.year, ci.month, ci.day);
      if (!start.isBefore(d)) return i;
    }
    // 3. Fallback : premier
    return 0;
  }

  @override
  void initState() {
    super.initState();
    _currentPage = _initialIndex();
    _controller = PageController(initialPage: _currentPage);
  }

  @override
  void didUpdateWidget(covariant _HotelsCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si un hôtel est ajouté/supprimé et que l'index courant sort des bornes, on recale.
    if (_currentPage >= widget.hotels.length) {
      _currentPage = widget.hotels.length - 1;
      if (_controller.hasClients) {
        _controller.jumpToPage(_currentPage);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hotels = widget.hotels;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hotels.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'HÉBERGEMENT ${_currentPage + 1}/${hotels.length}',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5),
                ),
                Text(
                  'Glisser ›',
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
        SizedBox(
          height: _cardHeight,
          child: PageView.builder(
            controller: _controller,
            itemCount: hotels.length,
            onPageChanged: (i) => setState(() => _currentPage = i),
            itemBuilder: (_, i) => _HotelCard(hotel: hotels[i], fmtDate: widget.fmtDate),
          ),
        ),
        if (hotels.length > 1) ...[
          const SizedBox(height: 8),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(hotels.length, (i) {
                final active = i == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: active ? AppColors.primary : AppColors.border,
                    borderRadius: BorderRadius.circular(3),
                  ),
                );
              }),
            ),
          ),
        ],
      ],
    );
  }
}

class _HotelCard extends ConsumerWidget {
  final TripDocument hotel;
  final String Function(DateTime) fmtDate;
  const _HotelCard({required this.hotel, required this.fmtDate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: () => openDocumentFormSheet(context, ref, existing: hotel),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('🏨', style: TextStyle(fontSize: 28)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(hotel.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  if (hotel.metadata['address'] != null) ...[
                    const SizedBox(height: 2),
                    Text(hotel.metadata['address'] as String, style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  ],
                  if (hotel.metadata['check_in'] != null || hotel.metadata['check_out'] != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (hotel.metadata['check_in'] != null) 'Check-in ${fmtDate(DateTime.parse(hotel.metadata['check_in'] as String))}',
                        if (hotel.metadata['check_out'] != null) 'Check-out ${fmtDate(DateTime.parse(hotel.metadata['check_out'] as String))}',
                      ].join(' · '),
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ],
                  if (hotel.reservationNumber != null) ...[
                    const SizedBox(height: 4),
                    Text('N° ${hotel.reservationNumber}', style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontStyle: FontStyle.italic)),
                  ],
                ],
              ),
            ),
            Icon(Icons.edit, size: 16, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// Card d'action enrichie : icône + label + sous-texte dynamique + chevron.
/// Remplace l'ancien `_ActionButton` qui n'avait que icône+label. Le sous-texte
/// donne un état immédiat ("8 jours planifiés", "Aucun planning pour l'instant",
/// "Billets, hôtels, confirmations") qui transforme la card de simple bouton
/// de navigation en résumé d'état du voyage.
class _RichActionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  const _RichActionCard({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: AppColors.primaryLight,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: AppColors.primary, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                      height: 1.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.arrow_forward_ios, size: 14, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// Card "Prochaine étape" : guide l'utilisateur sur l'action suivante selon
/// l'état du voyage. 3 cas dynamiques :
/// - `_NextStepCase.discoverItinerary` : destination=country/region + 0 étape
///   → 2 CTAs (clé en main / manuel)
/// - `_NextStepCase.generatePlan` : étapes définies + 0 activité
///   → 1 CTA "Générer mon planning"
/// - `_NextStepCase.viewPlan` : ≥1 activité
///   → 1 CTA "Voir le planning"
enum _NextStepCase { discoverItinerary, generatePlan, viewPlan }

class _NextStepCard extends StatelessWidget {
  final Trip trip;
  final _NextStepCase nextCase;
  /// Callback du CTA principal (mode auto / générer / voir selon le cas).
  final VoidCallback onPrimary;
  /// Callback du CTA secondaire — utilisé uniquement dans le cas
  /// `discoverItinerary` (ajout manuel des étapes). Null pour les autres cas.
  final VoidCallback? onSecondary;

  const _NextStepCard({
    required this.trip,
    required this.nextCase,
    required this.onPrimary,
    this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    final (title, body, primaryLabel, primaryEmoji, primaryHint) = switch (nextCase) {
      _NextStepCase.discoverItinerary => (
        'Crée ton voyage',
        'Ta destination est large. Choisis comment tu veux organiser ton voyage.',
        'Crée-moi un circuit clé en main',
        '✨',
        'Pensé pour toi',
      ),
      _NextStepCase.generatePlan => (
        'Ton planning n\'est pas encore prêt',
        'Génère un itinéraire adapté à ton voyage.',
        'Générer mon planning',
        '✨',
        null,
      ),
      _NextStepCase.viewPlan => (
        'Ton voyage est prêt',
        'Consulte ou ajuste ton planning.',
        'Voir le planning',
        null,
        null,
      ),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
        // Ombre très légère pour donner du poids sans alourdir.
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          // CTA principal : bouton plein bleu, plus visible. L'emoji est
          // optionnel selon le cas (✨ pour l'IA, rien pour le simple "Voir").
          ElevatedButton(
            onPressed: onPrimary,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (primaryEmoji != null) ...[
                  Text(primaryEmoji, style: const TextStyle(fontSize: 16)),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    primaryLabel,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          if (primaryHint != null) ...[
            const SizedBox(height: 6),
            Center(
              child: Text(
                primaryHint,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
          // CTA secondaire (uniquement dans le cas "destination large") :
          // ajout manuel des étapes via le sheet d'édition.
          if (onSecondary != null) ...[
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: onSecondary,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 44),
                foregroundColor: AppColors.primary,
                side: BorderSide(color: AppColors.border),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text(
                '+ Ajouter mes étapes manuellement',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Badge statut "outline" (bordure + texte couleur, fond transparent) — style
/// Material 3 / iOS moderne. Volontairement discret pour ne pas concurrencer
/// les CTAs pleins. 3 statuts V1 : "À compléter" (ambre), "Prêt à planifier"
/// (bleu primary), "Voyage prêt" (vert success). Extensible pour V2 (en cours,
/// passé) sans changer l'API.
class _TripStatusBadge extends StatelessWidget {
  final _TripStatus status;
  const _TripStatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      _TripStatus.toComplete => ('À compléter', AppColors.accent),
      _TripStatus.readyToPlan => ('Prêt à planifier', AppColors.primaryLight),
      _TripStatus.ready => ('Voyage prêt', AppColors.success),
    };
    // Sur le header bleu, le contraste demande un texte blanc + bordure
    // claire — on garde le même esprit "outline" mais adapté fond foncé.
    // Sur fond clair (utilisation future hors header), on tomberait sur le
    // mode classique : bordure et texte couleur, fond transparent.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
