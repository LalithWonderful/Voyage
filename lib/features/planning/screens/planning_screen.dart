import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:voyage/core/services/location_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyage/core/services/notification_service.dart';
import 'package:voyage/core/providers/currency_provider.dart';
import 'package:voyage/core/services/currency_service.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/core/widgets/converted_price.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/planning/models/activity_suggestion_model.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/models/trip_transport_model.dart';
import 'package:voyage/features/planning/providers/planning_provider.dart';
import 'package:voyage/features/planning/services/places_service.dart';
import 'package:voyage/features/planning/widgets/activity_create_sheet.dart';
import 'package:voyage/features/planning/widgets/activity_detail_sheet.dart';
import 'package:voyage/features/planning/widgets/suggestion_detail_sheet.dart';
import 'package:voyage/features/planning/services/ai_suggestions_service.dart';
import 'package:voyage/features/planning/services/document_to_activity.dart';
import 'package:voyage/features/planning/services/places_first_pipeline.dart';
import 'package:voyage/features/planning/services/routes_service.dart';
import 'package:voyage/features/planning/services/traveler_to_places_mapping.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';
import 'package:voyage/features/wallet/widgets/document_form_sheet.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';
import 'package:voyage/features/trips/widgets/trip_edit_sheet.dart';

class PlanningScreen extends ConsumerWidget {
  final String tripId;
  const PlanningScreen({super.key, required this.tripId});

  /// Premier passage sur "Suggérer" pour un voyage : on demande à l'utilisateur
  /// son mode de planification (Auto = mass planning prêt-à-l'emploi vs Co-pilote =
  /// 3 options par créneau, le voyageur choisit). Choix stocké dans `trips.planning_mode`,
  /// pas re-demandé sur les Suggérer suivants. Modifiable via les paramètres du voyage.
  Future<PlanningMode?> _askPlanningModeIfNeeded(BuildContext context, WidgetRef ref, Trip trip) async {
    debugPrint('[PLANNING_MODE] trip.planningMode lu = ${trip.planningMode} (id=${trip.id})');
    if (trip.planningMode != null) return trip.planningMode;
    if (!context.mounted) return null;
    final choice = await showModalBottomSheet<PlanningMode>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Comment veux-tu planifier ce voyage ?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                'Tu pourras changer d\'avis plus tard dans les paramètres du voyage.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 20),
              _PlanningModeCard(
                emoji: '✨',
                title: 'Pilote auto',
                description: 'On te propose un planning complet de A à Z. Tu ajusteras après si tu veux.',
                color: AppColors.primary,
                onTap: () => Navigator.pop(ctx, PlanningMode.auto),
              ),
              const SizedBox(height: 12),
              _PlanningModeCard(
                emoji: '🎯',
                title: 'Co-pilote',
                description: 'Tu participes à la planification. 3 options par créneau, tu choisis ce qui te plaît.',
                color: AppColors.accent,
                onTap: () => Navigator.pop(ctx, PlanningMode.coPilot),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return null;
    // Persiste le choix sur le voyage
    try {
      final res = await ref
          .read(supabaseProvider)
          .from('trips')
          .update({'planning_mode': choice.dbValue})
          .eq('id', trip.id)
          .select('id, planning_mode');
      debugPrint('[PLANNING_MODE] persist OK → ${res.isEmpty ? "(0 rows updated, RLS?)" : res.first}');
      ref.invalidate(tripByIdProvider(trip.id));
      ref.invalidate(tripsProvider);
    } catch (e) {
      debugPrint('[PLANNING_MODE] erreur persist : $e');
    }
    return choice;
  }

  /// Affiche un bottom sheet avec le choix de catégorie puis enchaîne sur la génération.
  /// Cohérent avec la vision produit (cf. mémoire project_ai_suggestions_vision) :
  /// laisser l'utilisateur cibler précisément ce qu'il cherche plutôt qu'un mega-prompt
  /// qui hallucine sur 77 activités.
  Future<void> _openSuggestionMenu(BuildContext context, WidgetRef ref, Trip trip) async {
    // Garde-fou Niveau 2 : si la destination est un pays/région ET qu'aucune
    // étape n'a été ajoutée, on bloque la suggestion et on dirige l'utilisateur
    // vers l'édition pour qu'il précise au moins une ville. Sans ça, le moteur
    // Places ne sait pas où chercher (centroïde du pays = milieu de désert).
    if (trip.itinerarySegments.isEmpty) {
      final places = ref.read(placesServiceProvider);
      final results = await places.autocompleteDestinations(trip.destination);
      if (!context.mounted) return;
      String? kind;
      if (results.isNotEmpty) {
        final exact = results.where((r) => r.mainText.toLowerCase() == trip.destination.trim().toLowerCase());
        kind = (exact.isNotEmpty ? exact.first : results.first).kind;
      }
      if (kind == 'country' || kind == 'region') {
        final goEdit = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(kind == 'country' ? 'Précise ta destination' : 'Précise ta région'),
            content: Text(
              kind == 'country'
                  ? 'Tu pars en ${trip.destination}, mais tu n\'as pas dit dans quelle(s) ville(s) tu seras. '
                      'Ajoute au moins une étape pour que je puisse chercher des activités au bon endroit.'
                  : 'Tu pars en ${trip.destination}, mais c\'est une région. '
                      'Ajoute au moins une ville-étape pour que je puisse chercher des activités au bon endroit.',
              style: const TextStyle(height: 1.4),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Annuler')),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Modifier le voyage'),
              ),
            ],
          ),
        );
        if (goEdit == true && context.mounted) {
          await openTripEditSheet(context, ref, trip: trip);
        }
        return;
      }
    }
    // Le menu retourne soit une SuggestionCategory (génération normale), soit
    // la chaîne sentinel 'test' (test debug Places-first), soit null (annulé).
    // Le test est présenté AVANT le choix de mode car il tourne sur n'importe
    // quel voyage, indépendamment de planningMode.
    final result = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text('Que veux-tu suggérer ?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            ),
            const SizedBox(height: 10),
            ListTile(
              leading: const Text('✨', style: TextStyle(fontSize: 24)),
              title: const Text('Tout', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Visites et repas, comble les créneaux libres'),
              onTap: () => Navigator.pop(ctx, SuggestionCategory.all),
            ),
            ListTile(
              leading: const Text('🍽️', style: TextStyle(fontSize: 24)),
              title: const Text('Restaurants', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Petit-déj, déjeuner, dîner — uniquement'),
              onTap: () => Navigator.pop(ctx, SuggestionCategory.restaurants),
            ),
            ListTile(
              leading: const Text('🏛️', style: TextStyle(fontSize: 24)),
              title: const Text('Visites & activités', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Culture, nature, shopping, détente — hors repas'),
              onTap: () => Navigator.pop(ctx, SuggestionCategory.activities),
            ),
            const Divider(height: 1),
            // ⚠️ DEBUG — diagnostic Places-first sans toucher à l'état du voyage.
            // Logue tout dans la console (`places_test`) et appelle Gemini en
            // mode Auto sur le plus petit groupe (cache → re-runs gratuits).
            ListTile(
              leading: const Text('🧪', style: TextStyle(fontSize: 24)),
              title: const Text('Test Places-first (debug)', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Gather + groupes + Gemini Auto sur 1 groupe — voir console'),
              onTap: () => Navigator.pop(ctx, 'test'),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (result == null || !context.mounted) return;
    if (result == 'test') {
      await _runPlacesNearbyTest(context, ref, trip);
      return;
    }
    final mode = await _askPlanningModeIfNeeded(context, ref, trip);
    if (mode == null || !context.mounted) return;
    await _generateSuggestions(context, ref, trip, category: result as SuggestionCategory, mode: mode);
  }

  /// ⚠️ DEBUG — diagnostic Places-first sans modifier l'état du voyage.
  /// Logue dans la console (`places_test`) :
  /// - le détail de la pool par jour (intérêts × candidats)
  /// - les groupes par centre géographique avec tailles de prompts
  /// - pour le plus petit groupe : appel Gemini en mode Auto + parsing
  /// - les distances haversine entre activités successives suggérées
  ///
  /// Cache via `gemini_cache` action `places_first_auto` → re-runs gratuits.
  /// N'utilise pas `runAutoPlacesFirst` directement parce qu'on veut le détail
  /// par groupe + le prompt brut + les distances post-parsing.
  Future<void> _runPlacesNearbyTest(BuildContext context, WidgetRef ref, Trip trip) async {
    final messenger = ScaffoldMessenger.of(context);
    final languageCode = Localizations.maybeLocaleOf(context)?.languageCode ?? 'fr';
    if (trip.interests == null || trip.interests!.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('⚠️ Aucun intérêt sur ce voyage. Édite-le pour en ajouter.')),
      );
      return;
    }

    messenger.showSnackBar(
      const SnackBar(content: Text('🧪 Test Places-first lancé — voir la console (places_test)')),
    );

    try {
      final hotels = await ref.read(tripHotelsProvider(tripId).future);
      final geocoder = ref.read(geocodingServiceProvider);
      final nearbyService = ref.read(placesNearbyServiceProvider);

      debugPrint('[places_test] === PLACES-FIRST TEST (gather all days) ===');
      final travelerProfile = trip.travelerType != null
          ? travelerPlacesProfiles[trip.travelerType]
          : null;
      final searchRadius = travelerProfile?.searchRadiusMeters ?? defaultSearchRadiusMeters;
      debugPrint(
        '[places_test] Trip: ${trip.title} | type=${trip.travelerType ?? "default"} '
        '(radius=${searchRadius}m) | intérêts=${trip.interests}',
      );

      final stopwatch = Stopwatch()..start();
      final pool = await gatherCandidatesForTrip(
        trip: trip,
        hotels: hotels,
        geocoder: geocoder,
        nearbyService: nearbyService,
        languageCode: languageCode,
      );
      stopwatch.stop();
      debugPrint(
        '[places_test] Récolte ${pool.length} jours en ${stopwatch.elapsedMilliseconds}ms',
      );

      var totalAfterFilters = 0;
      for (var i = 0; i < pool.length; i++) {
        final day = pool[i];
        final dayIso = day.day.toIso8601String().split('T').first;
        final byInterestSummary = day.byInterest.entries
            .map((e) => '${e.key}=${e.value.length}')
            .join(', ');
        debugPrint(
          '[places_test] Jour $dayIso (${day.center.source}, '
          '${day.center.latitude.toStringAsFixed(3)},${day.center.longitude.toStringAsFixed(3)}) : '
          '${day.uniqueCandidates} uniques [$byInterestSummary]',
        );
        totalAfterFilters += day.totalCandidates;
        // Top 3 par intérêt seulement pour le 1er jour de chaque groupe pour
        // ne pas noyer la console (la pool est la même pour tous les jours
        // d'un même centre).
        if (i == 0) {
          for (final entry in day.byInterest.entries) {
            for (final c in entry.value.take(3)) {
              debugPrint(
                '[places_test]   [${entry.key}] ${c.name} (${c.address ?? "?"}) '
                '★${c.rating} (${c.userRatingCount ?? 0} avis)',
              );
            }
          }
        }
      }

      // ─── Groupes par centre géographique ──────────────────────────────
      final groups = groupDaysByCenter(pool);
      debugPrint(
        '[places_test] === ${groups.length} GROUPE(S) PAR CENTRE ===',
      );
      for (var g = 0; g < groups.length; g++) {
        final group = groups[g];
        final dayList = group.days.map((d) => d.toIso8601String().split('T').first).join(', ');
        debugPrint(
          '[places_test] Groupe ${g + 1}/${groups.length} : ${group.center.source} '
          '(${group.center.latitude.toStringAsFixed(3)},${group.center.longitude.toStringAsFixed(3)}) | '
          'jours=$dayList | pool=${group.poolSize} lieux',
        );
      }

      // ─── K-means clustering par quartier ──────────────────────────────
      // Le test simule le mode Auto category=all : on retire les types repas
      // de la pool envoyée à Gemini (le code insère les repas après par
      // scoring déterministe, cf. _insertDeterministicMeals — pas testé ici,
      // c'est ce que voit l'utilisateur via le flow normal "Suggérer").
      final clustersRaw = partitionByQuartier(groups);
      final clusters = clustersRaw.map((c) {
        final filteredPool = Map.fromEntries(
          c.pool.entries.where((e) {
            final types = e.value.candidate.types;
            if (types.isEmpty) return true;
            const mealTypes = {
              'restaurant', 'cafe', 'bakery', 'bar', 'pub', 'food_court',
              'meal_delivery', 'meal_takeaway', 'wine_bar', 'sports_bar',
              'night_club', 'fine_dining_restaurant', 'fast_food_restaurant',
              'french_restaurant', 'italian_restaurant', 'japanese_restaurant',
              'chinese_restaurant', 'thai_restaurant', 'mexican_restaurant',
              'mediterranean_restaurant', 'pizza_restaurant', 'sushi_restaurant',
              'vegan_restaurant', 'vegetarian_restaurant', 'seafood_restaurant',
              'steak_house', 'sandwich_shop', 'breakfast_restaurant',
              'brunch_restaurant', 'coffee_shop', 'tea_house', 'ice_cream_shop',
            };
            return !mealTypes.contains(types.first);
          }),
        );
        return PlacesPromptInput(center: c.center, days: c.days, pool: filteredPool);
      }).toList();

      debugPrint(
        '[places_test] === ${clusters.length} CLUSTER(S) APRÈS K-MEANS (repas exclus pour Gemini, insertion déterministe via flow normal) ===',
      );
      for (var c = 0; c < clusters.length; c++) {
        final cluster = clusters[c];
        final dayList = cluster.days.map((d) => d.toIso8601String().split('T').first).join(', ');
        if (cluster.pool.isEmpty) {
          debugPrint(
            '[places_test] Cluster ${c + 1}/${clusters.length} : pool vide après filtrage repas, skip',
          );
          continue;
        }
        final lats = cluster.pool.values.map((e) => e.candidate.latitude).toList();
        final lngs = cluster.pool.values.map((e) => e.candidate.longitude).toList();
        final centroidLat = lats.reduce((a, b) => a + b) / lats.length;
        final centroidLng = lngs.reduce((a, b) => a + b) / lngs.length;
        var maxDistM = 0.0;
        for (var i = 0; i < lats.length; i++) {
          final dLat = (lats[i] - centroidLat) * 111000;
          final dLng = (lngs[i] - centroidLng) * 73000;
          final d = math.sqrt(dLat * dLat + dLng * dLng);
          if (d > maxDistM) maxDistM = d;
        }
        final autoPrompt = buildAutoPrompt(
          input: cluster, trip: trip, travelerProfile: travelerProfile,
          category: SuggestionCategory.all,
        );
        debugPrint(
          '[places_test] Cluster ${c + 1}/${clusters.length} : centre ${cluster.center.source} | '
          'centroïde=(${centroidLat.toStringAsFixed(4)},${centroidLng.toStringAsFixed(4)}) | '
          'rayon=${maxDistM.round()}m | pool=${cluster.poolSize} lieux non-repas | '
          'jours=$dayList | prompt Auto=${autoPrompt.length} chars',
        );
        // Liste exhaustive de la pool du cluster — pour vérifier qu'un lieu
        // attendu (Musée de l'Image, Imagerie d'Épinal, etc.) est bien
        // présent. Triée par score qualité (rating × log avis).
        final poolEntries = cluster.pool.entries.toList()
          ..sort((a, b) {
            final ra = a.value.candidate.rating ?? 0;
            final rb = b.value.candidate.rating ?? 0;
            final ca = a.value.candidate.userRatingCount ?? 0;
            final cb = b.value.candidate.userRatingCount ?? 0;
            double sc(double r, int n) => r * (n <= 1 ? 1 : (1 + math.log(n)));
            return sc(rb, cb).compareTo(sc(ra, ca));
          });
        for (var i = 0; i < poolEntries.length; i++) {
          final c2 = poolEntries[i].value.candidate;
          final typesShort = c2.types.take(2).join(',');
          debugPrint(
            '[places_test]   [${i + 1}/${poolEntries.length}] ${c2.name} ★${c2.rating} (${c2.userRatingCount ?? 0} avis) [$typesShort] · ${c2.address ?? "?"}',
          );
        }
      }

      // ─── Simulation du flow Auto complet (Round 2A déterministe) ─────
      // Reproduit ce que fait `runAutoPlacesFirst` en mode `category=all` :
      // 1. Sélecteur déterministe (visites)
      // 2. Insertion déterministe des repas (déjeuner 12:30 + dîner 19:30)
      // Affiche le résultat final par jour avec distances inter-activités.
      // 0 Gemini.
      if (clusters.isEmpty) {
        debugPrint('[places_test] Aucun cluster → fin du test.');
      } else {
        final stopwatchSelect = Stopwatch()..start();
        final visits = selectVisitsDeterministic(
          clusters: clusters,
          trip: trip,
          travelerProfile: travelerProfile,
        );
        stopwatchSelect.stop();
        debugPrint(
          '[places_test] === SÉLECTEUR DÉTERMINISTE : ${visits.length} visites en ${stopwatchSelect.elapsedMilliseconds}ms ===',
        );

        // Insertion déterministe des repas
        final stopwatchMeals = Stopwatch()..start();
        final nearbyService = ref.read(placesNearbyServiceProvider);
        final meals = await insertDeterministicMeals(
          activities: visits,
          pool: pool,
          nearbyService: nearbyService,
          travelerProfile: travelerProfile,
          tripInterests: trip.interests ?? const <String>[],
          languageCode: languageCode,
        );
        stopwatchMeals.stop();
        debugPrint(
          '[places_test] === INSERTION REPAS : ${meals.length} repas en ${stopwatchMeals.elapsedMilliseconds}ms ===',
        );

        final all = [...visits, ...meals];

        // Affichage par jour, trié chronologiquement avec distances
        debugPrint('[places_test] === PLANNING COMPLET PAR JOUR ===');
        final byDay = <String, List<ActivitySuggestion>>{};
        for (final s in all) {
          final key = s.dayDate.toIso8601String().split('T').first;
          byDay.putIfAbsent(key, () => []).add(s);
        }
        // On itère sur TOUS les jours du voyage (pas seulement ceux avec activités)
        for (final dayCandidate in pool) {
          final key = dayCandidate.day.toIso8601String().split('T').first;
          final list = (byDay[key] ?? const <ActivitySuggestion>[])
              .toList()
            ..sort((a, b) => a.startTime.compareTo(b.startTime));
          if (list.isEmpty) {
            debugPrint(
              '[places_test] $key (${dayCandidate.center.source}) : 🚨 AUCUNE ACTIVITÉ',
            );
            continue;
          }
          final visitCount = list.where((s) => s.tag != 'Repas').length;
          final mealCount = list.where((s) => s.tag == 'Repas').length;
          debugPrint(
            '[places_test] $key (${dayCandidate.center.source}) : ${list.length} entrées '
            '($visitCount visites + $mealCount repas)',
          );
          for (var i = 0; i < list.length; i++) {
            final s = list[i];
            final prefix = s.tag == 'Repas' ? '🍽️' : '📍';
            debugPrint(
              '[places_test]   $prefix ${s.startTime} · ${s.title} [${s.tag}] '
              '${s.priceEstimate ?? "?"} (${s.durationMinutes ?? "?"} min) — ${s.matchReason ?? ""}',
            );
            if (i + 1 < list.length) {
              final next = list[i + 1];
              if (s.latitude != null && s.longitude != null &&
                  next.latitude != null && next.longitude != null) {
                final km = haversineKm(s.latitude!, s.longitude!, next.latitude!, next.longitude!);
                final m = (km * 1000).round();
                final flag = travelerProfile?.maxConsecutiveDistanceMeters != null &&
                        m > travelerProfile!.maxConsecutiveDistanceMeters!
                    ? ' ⚠️ DÉPASSE seuil ${travelerProfile.maxConsecutiveDistanceMeters}m'
                    : '';
                debugPrint('[places_test]      ↓ ${m}m vers le suivant$flag');
              }
            }
          }
        }
        debugPrint(
          '[places_test] === RÉSUMÉ : ${visits.length} visites + ${meals.length} repas = ${all.length} entrées sur ${pool.length} jours ===',
        );
      }
      final totalUnique = pool.fold<int>(0, (sum, d) => sum + d.uniqueCandidates);
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text(
            '✓ ${pool.length} jours · ${groups.length} groupes · $totalUnique uniques · $totalAfterFilters cumulés (voir console)',
          ),
          duration: const Duration(seconds: 5),
        ));
      }
    } catch (e, st) {
      debugPrint('[places_test] EXCEPTION: $e\n$st');
      if (context.mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('❌ Erreur test : $e')),
        );
      }
    }
  }

  Future<void> _generateSuggestions(
    BuildContext context,
    WidgetRef ref,
    Trip trip, {
    SuggestionCategory category = SuggestionCategory.all,
    required PlanningMode mode,
  }) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);
    // Langue dans laquelle Places doit retourner les noms — sinon "L'Excelsior"
    // devient الإكسلسيور au Maroc, ร้านอาหาร à Bangkok, etc. Capturée AVANT les
    // await pour ne pas dépendre d'un context potentiellement stale plus tard.
    final languageCode = Localizations.maybeLocaleOf(context)?.languageCode ?? 'fr';

    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => const _LoadingDialog(),
    );

    bool dialogClosed = false;
    void closeDialog() {
      if (!dialogClosed) {
        dialogClosed = true;
        navigator.pop();
      }
    }

    try {
      final profile = await ref.read(userProfileProvider.future);
      var existing = await ref.read(planningTimelineProvider(tripId).future);
      final hotels = await ref.read(tripHotelsProvider(tripId).future);

      // Backfill des adresses manquantes via Places API. Critique pour que Gemini
      // puisse raisonner par quartier et regrouper ses propositions géographiquement.
      // Les titres déjà validés sont cachés en places_cache 30j → coût minime sur les runs suivants.
      final missingAddress = existing.where((a) =>
        (a.detail == null || a.detail!.trim().isEmpty) &&
        a.tag != 'Hébergement' &&
        !isVirtualActivity(a.id) // les activités virtuelles n'ont pas d'id DB
      ).toList();
      if (missingAddress.isNotEmpty) {
        debugPrint('[BACKFILL] ${missingAddress.length} activités sans adresse → enrichissement Places');
        final placesService = ref.read(placesCacheServiceProvider);
        final supabaseClient = ref.read(supabaseProvider);
        var updated = 0;
        await Future.wait(missingAddress.map((a) async {
          try {
            final info = await placesService.findInfo(title: a.title, destination: trip.destination);
            if (info.address != null && info.address!.trim().isNotEmpty) {
              await supabaseClient.from('trip_activities')
                  .update({'detail': info.address}).eq('id', a.id);
              updated++;
            }
          } catch (_) {} // silent — un échec sur une activité ne doit pas bloquer le flow
        }));
        debugPrint('[BACKFILL] $updated adresses ajoutées (${missingAddress.length - updated} non trouvées)');
        // Re-fetch pour que Gemini voit les nouvelles adresses
        if (updated > 0) {
          ref.invalidate(tripActivitiesProvider(tripId));
          existing = await ref.read(planningTimelineProvider(tripId).future);
        }
      }

      // Préférences : trip-level si défini, sinon fallback profil utilisateur.
      // Le formulaire d'édition affiche "Optionnel — vide = on utilise ton
      // profil voyageur global" : on aligne le runtime sur cette promesse,
      // sinon le pipeline retourne 0 candidats (intérêts vides → pool vide).
      final effectiveTravelerType = trip.travelerType ?? profile?['traveler_type'] as String?;
      final tripInterests = trip.interests;
      final globalInterests = await ref.read(userInterestsProvider.future);
      final effectiveInterests = (tripInterests != null && tripInterests.isNotEmpty)
          ? tripInterests
          : globalInterests;
      final effectiveTrip = trip.copyWith(
        travelerType: effectiveTravelerType,
        interests: effectiveInterests,
      );
      if (effectiveInterests.isEmpty) {
        closeDialog();
        if (!context.mounted) return;
        messenger.showSnackBar(
          const SnackBar(content: Text(
            'Aucun intérêt défini, ni sur ce voyage ni sur ton profil. '
            'Édite ton profil ou ce voyage pour en ajouter.',
          )),
        );
        return;
      }

      // ─── MODE COPILOT — flow Places-first (refonte 2026-04-25) ──────────
      // Bypass complet de l'ancien pipeline Gemini-first. On va directement
      // chercher des lieux RÉELS via Places API, puis demander à Gemini de
      // SÉLECTIONNER dans cette liste (zéro hallucination par construction).
      // L'ancienne branche coPilot Gemini-first plus bas est définitivement
      // supprimée — elle était cassée par les hallucinations Gemini.
      if (mode == PlanningMode.coPilot) {
        debugPrint('[SUGGEST coPilot] Démarrage flow Places-first');
        final aiService = ref.read(aiSuggestionsServiceProvider);
        final nearbyService = ref.read(placesNearbyServiceProvider);
        final geocoder = ref.read(geocodingServiceProvider);

        // Titres normalisés des activités déjà au planning, pour pré-filtrer
        // la pool Places (pas la peine de reproposer ce que le voyageur a déjà).
        String normTitle(String s) => s
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-zà-ÿ0-9\s]'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        final existingTitlesNorm = existing.map((a) => normTitle(a.title)).toSet();

        try {
          final groups = await runCoPilotPlacesFirst(
            trip: effectiveTrip,
            hotels: hotels,
            geocoder: geocoder,
            nearbyService: nearbyService,
            aiService: aiService,
            existingTitlesNormalized: existingTitlesNorm,
            languageCode: languageCode,
          );
          closeDialog();
          if (!context.mounted) return;
          if (groups.isEmpty) {
            messenger.showSnackBar(
              const SnackBar(content: Text('Aucune nouvelle suggestion — Places n\'a rien retourné dans le périmètre.')),
            );
            return;
          }
          await showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: AppColors.background,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
            builder: (_) => _SuggestionsSheet(
              tripId: tripId,
              groups: groups,
              travelerType: effectiveTravelerType,
              mode: PlanningMode.coPilot,
            ),
          );
          ref.invalidate(tripActivitiesProvider(tripId));
          ref.invalidate(tripTransportsProvider(tripId));
        } catch (e) {
          closeDialog();
          debugPrint('[SUGGEST coPilot Places-first] EXCEPTION : $e');
          messenger.showSnackBar(
            SnackBar(
              content: Text('Erreur Places-first : $e', maxLines: 4),
              backgroundColor: AppColors.error,
              duration: const Duration(seconds: 6),
            ),
          );
        }
        return;
      }
      // ─── MODE AUTO — flow Places-first (refonte 4d, 2026-04-26) ────────
      // Comme CoPilot : on récolte des lieux RÉELS via Places API puis on
      // demande à Gemini de SÉLECTIONNER dans cette liste (zéro hallucination
      // par construction). Différence avec CoPilot : sortie plate (5-8 sugg/jour
      // étalées), pas de groupes 3-options.
      debugPrint('[SUGGEST] Démarrage flow Auto Places-first (trip=${trip.destination}, existing=${existing.length}, category=${category.name})');
      final aiService = ref.read(aiSuggestionsServiceProvider);
      final nearbyService = ref.read(placesNearbyServiceProvider);
      final geocoder = ref.read(geocodingServiceProvider);

      String norm(String s) => s
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-zà-ÿ0-9\s]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final existingTitlesNorm = existing.map((a) => norm(a.title)).toSet();

      final rawSuggestions = await runAutoPlacesFirst(
        trip: effectiveTrip,
        hotels: hotels,
        geocoder: geocoder,
        nearbyService: nearbyService,
        aiService: aiService,
        category: category,
        existingTitlesNormalized: existingTitlesNorm,
        languageCode: languageCode,
      );

      // ── Filtres métier (toujours pertinents en Places-first) ──
      // - dedup interne (Gemini peut sélectionner 2 fois la même ref)
      // - filtre catégorie (cohérence tag retourné par Gemini)
      // - retour hôtel (l'app les insère depuis les docs)
      // - passé (jours déjà passés)
      // - overlap horaire (chevauchement avec activités existantes)
      // La validation Places (placeId/address/city-match/fuzzy/inappropriate) a
      // été retirée : les lieux viennent DÉJÀ de Places, c'est redondant.

      final hotelActionsRe = RegExp(
        r'\b(retour|départ|depart|arrivée|arrivee|check[\s-]?in|check[\s-]?out)\b',
        caseSensitive: false,
      );
      bool isHotelReturn(String title) => hotelActionsRe.hasMatch(title);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final earliestMinToday = now.hour * 60 + now.minute + 30;

      int? timeToMin(String hhmm) {
        final parts = hhmm.split(':');
        if (parts.length != 2) return null;
        final h = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        if (h == null || m == null) return null;
        return h * 60 + m;
      }

      bool isInPast(ActivitySuggestion s) {
        final day = DateTime(s.dayDate.year, s.dayDate.month, s.dayDate.day);
        if (day.isBefore(today)) return true;
        if (day.isAtSameMomentAs(today)) {
          final minutes = timeToMin(s.startTime);
          if (minutes == null) return false;
          return minutes < earliestMinToday;
        }
        return false;
      }

      final existingByDay = <String, List<TripActivity>>{};
      for (final a in existing) {
        final key = a.dayDate.toIso8601String().split('T').first;
        existingByDay.putIfAbsent(key, () => []).add(a);
      }

      bool hasTimeOverlap(ActivitySuggestion s) {
        final key = s.dayDate.toIso8601String().split('T').first;
        final sStart = timeToMin(s.startTime);
        if (sStart == null) return false;
        final sEnd = sStart + (s.durationMinutes ?? 60);
        for (final e in existingByDay[key] ?? const <TripActivity>[]) {
          final eStart = timeToMin(e.startTime);
          if (eStart == null) continue;
          final eEnd = eStart + (e.durationMinutes ?? 60);
          if (sStart < eEnd && eStart < sEnd) return true;
        }
        return false;
      }

      final seenInternal = <String>{};
      final uniqueInternal = <ActivitySuggestion>[];
      for (final s in rawSuggestions) {
        final key = norm(s.title);
        if (seenInternal.add(key)) uniqueInternal.add(s);
      }

      const mealTags = {'repas', 'gastronomie', 'restaurant', 'resto'};
      bool isMealActivity(ActivitySuggestion s) {
        final t = s.tag.toLowerCase().trim();
        if (mealTags.contains(t)) return true;
        final title = s.title.toLowerCase();
        return RegExp(r'\b(petit[\s-]?déjeuner|déjeuner|dîner|diner|brunch|restaurant|resto|café|food tour|street food)\b').hasMatch(title);
      }
      bool matchesCategory(ActivitySuggestion s) {
        switch (category) {
          case SuggestionCategory.all:
            return true;
          case SuggestionCategory.restaurants:
            return isMealActivity(s);
          case SuggestionCategory.activities:
            return !isMealActivity(s);
        }
      }

      final afterCategory = uniqueInternal.where(matchesCategory).toList();
      final afterDup = afterCategory.where((s) => !existingTitlesNorm.contains(norm(s.title))).toList();
      final afterReturn = afterDup.where((s) => !isHotelReturn(s.title)).toList();
      final afterPast = afterReturn.where((s) => !isInPast(s)).toList();
      final afterOverlap = afterPast.where((s) => !hasTimeOverlap(s)).toList();

      debugPrint(
        '[SUGGEST] Auto Places-first : brut=${rawSuggestions.length}, '
        'dedup=${uniqueInternal.length}, après catégorie=${afterCategory.length}, '
        'après dedup-existant=${afterDup.length}, après retour=${afterReturn.length}, '
        'après passé=${afterPast.length}, après overlap=${afterOverlap.length}',
      );

      closeDialog();
      if (!context.mounted) return;
      if (afterOverlap.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Aucune nouvelle suggestion — Places n\'a rien retourné dans le périmètre ou ton planning est déjà bien rempli.')),
        );
        return;
      }
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.background,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (_) => _SuggestionsSheet(
          tripId: tripId,
          suggestions: afterOverlap,
          travelerType: effectiveTravelerType,
        ),
      );
      ref.invalidate(tripActivitiesProvider(tripId));
      ref.invalidate(tripTransportsProvider(tripId));
    } catch (e) {
      closeDialog();
      debugPrint('[SUGGEST] EXCEPTION : $e');
      messenger.showSnackBar(
        SnackBar(
          content: Text('Erreur IA : $e', maxLines: 4),
          backgroundColor: AppColors.error,
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tripAsync = ref.watch(tripByIdProvider(tripId));
    final activitiesAsync = ref.watch(planningTimelineProvider(tripId));
    final trip = tripAsync.valueOrNull;
    final hasActivities = activitiesAsync.valueOrNull?.isNotEmpty ?? false;

    // Reschedule les notifs locales dès que le timeline (activités réelles + docs) change.
    ref.listen(tripActivitiesProvider(tripId), (_, next) {
      final activities = next.valueOrNull;
      if (activities == null) return;
      final docs = ref.read(tripDocumentsProvider(tripId)).valueOrNull ?? const [];
      NotificationService.instance.rescheduleForTrip(activities: activities, documents: docs);
    });
    ref.listen(tripDocumentsProvider(tripId), (_, next) {
      final docs = next.valueOrNull;
      if (docs == null) return;
      final activities = ref.read(tripActivitiesProvider(tripId)).valueOrNull ?? const [];
      NotificationService.instance.rescheduleForTrip(activities: activities, documents: docs);
    });

    return Scaffold(
      backgroundColor: AppColors.background,
      floatingActionButton: (trip == null || !hasActivities)
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openSuggestionMenu(context, ref, trip),
              backgroundColor: AppColors.accent,
              icon: const Icon(Icons.auto_awesome, color: Colors.white),
              label: const Text('Suggérer', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
      body: Column(
        children: [
          _GradientHeader(
            tripId: tripId,
            trip: trip,
          ),
          _TabBar(tripId: tripId),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(tripActivitiesProvider(tripId));
                await ref.read(tripActivitiesProvider(tripId).future);
              },
              child: Builder(builder: (context) {
                // Garde la valeur précédente pendant un refetch pour éviter un flash
                final activities = activitiesAsync.valueOrNull;
                if (activities == null) {
                  if (activitiesAsync.hasError) {
                    return Center(child: Text('Erreur : ${activitiesAsync.error}', style: TextStyle(color: AppColors.error)));
                  }
                  return ListView(children: const [SizedBox(height: 200, child: Center(child: CircularProgressIndicator()))]);
                }
                if (activities.isEmpty) {
                  return ListView(children: [
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.5,
                      child: _EmptyPlanning(
                        onSuggest: trip == null ? null : () => _openSuggestionMenu(context, ref, trip),
                        onAddManual: () => openActivityCreateSheet(context, ref, tripId: tripId, defaultDay: trip?.startDate ?? DateTime.now()),
                      ),
                    ),
                  ]);
                }
                final transports = ref.watch(tripTransportsProvider(tripId)).valueOrNull ?? const [];
                return _PlanningContent(tripId: tripId, activities: activities, transports: transports);
              }),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingDialog extends StatelessWidget {
  const _LoadingDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('✨', style: TextStyle(fontSize: 48)),
            SizedBox(height: 12),
            Text('Je prépare ton planning...', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            SizedBox(height: 4),
            Text('Quelques secondes', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            SizedBox(height: 16),
            CircularProgressIndicator(strokeWidth: 2.5),
          ],
        ),
      ),
    );
  }
}

class _GradientHeader extends ConsumerWidget {
  final String tripId;
  final Trip? trip;
  const _GradientHeader({required this.tripId, required this.trip});

  static const _months = [
    'janv.', 'févr.', 'mars', 'avril', 'mai', 'juin',
    'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.',
  ];

  String _formatRange() {
    if (trip == null) return '';
    final s = trip!.startDate;
    final e = trip!.endDate;
    final sameMonth = s.month == e.month && s.year == e.year;
    if (sameMonth) {
      return '${s.day} – ${e.day} ${_months[e.month - 1]} ${e.year}';
    }
    return '${s.day} ${_months[s.month - 1]} – ${e.day} ${_months[e.month - 1]} ${e.year}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final budget = ref.watch(tripBudgetProvider(tripId)).valueOrNull;
    final userCurrency = ref.watch(userCurrencyProvider);
    final totalLabel = (budget != null && budget.total > 0)
        ? '~${CurrencyService.formatAmount(budget.total, userCurrency)}'
        : null;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF2563EB), Color(0xFF4F46E5)]),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                GestureDetector(onTap: () => context.go('/trips/$tripId'), child: const Icon(Icons.arrow_back, color: Colors.white)),
                const Spacer(),
                const Icon(Icons.more_horiz, color: Colors.white),
              ]),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Text(
                      trip != null ? '${trip!.title} ${trip!.coverEmoji}' : '...',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                  if (totalLabel != null)
                    Text(
                      totalLabel,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                ],
              ),
              Text(
                _formatRange(),
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  final String tripId;
  const _TabBar({required this.tripId});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _tab(context, 'Planning', active: true, onTap: null),
          _tab(context, '🗺️ Carte', onTap: () => context.go('/trips/$tripId/map')),
          _tab(context, '📄 Docs', onTap: () => context.go('/trips/$tripId')),
          _tab(context, '💬 Assistant', onTap: () => context.go('/assistant')),
        ]),
      ),
    );
  }

  Widget _tab(BuildContext context, String label, {bool active = false, VoidCallback? onTap}) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: active ? AppColors.primary : AppColors.primaryLight,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: active ? Colors.white : AppColors.primary)),
    ),
  );
}

class _EmptyPlanning extends StatelessWidget {
  final VoidCallback? onSuggest;
  final VoidCallback? onAddManual;
  const _EmptyPlanning({this.onSuggest, this.onAddManual});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('📅', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 16),
            Text('Aucune activité pour l\'instant', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            const SizedBox(height: 6),
            Text('Laisse-moi construire un planning ou crée tes activités à la main.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.5)),
            if (onSuggest != null) ...[
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onSuggest,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Suggérer des activités'),
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
              ),
            ],
            if (onAddManual != null) ...[
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: onAddManual,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Ou ajouter une activité manuellement'),
                style: TextButton.styleFrom(foregroundColor: AppColors.primary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SuggestionsSheet extends ConsumerStatefulWidget {
  final String tripId;
  /// Liste plate, utilisée en mode auto. Vide en mode coPilot.
  final List<ActivitySuggestion> suggestions;
  /// Groupes par créneau, utilisés en mode coPilot (3 options/créneau). Vide en mode auto.
  final List<SuggestionGroup> groups;
  final String? travelerType;
  /// Mode de planification utilisé pour la génération. Détermine le rendu UI :
  /// - auto : liste plate, tout coché par défaut, le voyageur décoche.
  /// - coPilot : sections par créneau avec 3 options, tout décoché par défaut, le voyageur coche.
  final PlanningMode mode;
  const _SuggestionsSheet({
    required this.tripId,
    this.suggestions = const [],
    this.groups = const [],
    this.travelerType,
    this.mode = PlanningMode.auto,
  });

  @override
  ConsumerState<_SuggestionsSheet> createState() => _SuggestionsSheetState();
}

class _SuggestionsSheetState extends ConsumerState<_SuggestionsSheet> {
  /// Mode auto : indices sélectionnés dans `widget.suggestions`. Tous cochés au départ.
  late final Set<int> _selected;
  /// Mode coPilot : pour chaque groupe (clé = index dans `widget.groups`), set des
  /// indices d'options cochées dans ce groupe. Multi-select libre. Vide au départ.
  final Map<int, Set<int>> _selectedByGroup = {};
  bool _saving = false;
  final Map<String, Future<PlaceInfo>> _placeCache = {};

  Future<PlaceInfo> _placeInfoFor(ActivitySuggestion s) {
    return _placeCache.putIfAbsent(s.title, () {
      final cache = ref.read(placesCacheServiceProvider);
      final destination = ref.read(tripByIdProvider(widget.tripId)).valueOrNull?.destination ?? '';
      return cache.findInfo(title: s.title, destination: destination);
    });
  }

  static const _months = [
    'janv.', 'févr.', 'mars', 'avril', 'mai', 'juin',
    'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.',
  ];
  static const _weekdays = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];

  /// Total d'options cochées tous groupes confondus (mode coPilot).
  int get _coPilotSelectedCount =>
      _selectedByGroup.values.fold<int>(0, (sum, s) => sum + s.length);

  /// Total d'options proposées tous groupes confondus (mode coPilot).
  /// Sert à savoir si "Tout cocher" doit basculer en "Tout décocher".
  int get _coPilotTotalOptions =>
      widget.groups.fold<int>(0, (sum, g) => sum + g.options.length);

  @override
  void initState() {
    super.initState();
    if (widget.mode == PlanningMode.coPilot) {
      // Tout décoché par défaut — le voyageur coche ce qui lui plaît.
      _selected = <int>{};
    } else {
      _selected = Set<int>.from(List.generate(widget.suggestions.length, (i) => i));
    }
  }

  /// Génère en BACKGROUND les descriptions pour les nouvelles activités, en un seul appel Gemini.
  /// Si l'utilisateur ouvre une activité avant la fin du batch, le fallback single-shot prend le relais.
  Future<void> _generateDescriptionsInBackground(List<TripActivity> activities) async {
    if (activities.isEmpty) return;
    try {
      final trip = await ref.read(tripByIdProvider(widget.tripId).future);
      if (trip == null) return;
      final service = ref.read(aiSuggestionsServiceProvider);
      final descriptions = await service.describeActivitiesBatch(
        items: activities
            .map((a) => (title: a.title, detail: a.detail, tag: a.tag as String?))
            .toList(),
        destination: trip.destination,
      );
      final client = ref.read(supabaseProvider);
      for (var i = 0; i < activities.length && i < descriptions.length; i++) {
        final desc = descriptions[i];
        if (desc.isEmpty) continue;
        try {
          await client.from('trip_activities').update({'description': desc}).eq('id', activities[i].id);
        } catch (_) {}
      }
      ref.invalidate(tripActivitiesProvider(widget.tripId));
      developer.log('Batch descriptions terminé (${descriptions.length})', name: 'planning');
    } catch (e) {
      developer.log('Erreur batch descriptions : $e', name: 'planning');
    }
  }

  /// Insère automatiquement une activité "Retour à [hôtel]" en fin de chaque journée
  /// couverte par au moins une réservation hôtel. Si le voyage a plusieurs hébergements
  /// (voyage multi-villes), chaque jour utilise l'hôtel dont la période couvre ce jour.
  /// Pas de retour ajouté si : pas d'hôtel, jour hors période, jour déjà pourvu d'un retour.
  Future<void> _autoInsertHotelReturns(dynamic client) async {
    final hotels = await ref.read(tripHotelsProvider(widget.tripId).future);
    if (hotels.isEmpty) return;
    final trip = await ref.read(tripByIdProvider(widget.tripId).future);
    if (trip == null) return;

    final all = await client
        .from('trip_activities')
        .select()
        .eq('trip_id', widget.tripId);
    final activities = (all as List).map((e) => TripActivity.fromJson(e)).toList();

    final byDay = <DateTime, List<TripActivity>>{};
    for (final a in activities) {
      final key = DateTime(a.dayDate.year, a.dayDate.month, a.dayDate.day);
      byDay.putIfAbsent(key, () => []).add(a);
    }

    final rows = <Map<String, dynamic>>[];
    for (final entry in byDay.entries) {
      final day = entry.key;
      // Hôtel actif pour ce jour précis (ou null si aucun ne couvre ce jour)
      final dayHotel = hotelForDay(hotels, day);
      if (dayHotel == null) continue;
      DateTime? tryParseDate(dynamic v) => v is String ? DateTime.tryParse(v) : null;
      final ci = tryParseDate(dayHotel.metadata['check_in']);
      final co = tryParseDate(dayHotel.metadata['check_out']);
      // Si l'hôtel a des dates, on vérifie que ce jour est bien une NUIT dormie
      // chez lui : [check_in, check_out[ (le jour du check-out on part le matin
      // donc on n'y dort pas — cohérent avec `_sleepNightsRange` du wallet).
      // Sans dates, on accepte tous les jours du voyage (legacy).
      if (ci != null && co != null) {
        final inRange = !day.isBefore(DateTime(ci.year, ci.month, ci.day)) &&
            day.isBefore(DateTime(co.year, co.month, co.day));
        if (!inRange) continue;
      }

      final hasReturn = entry.value.any((a) => a.title.toLowerCase().trim().startsWith('retour'));
      if (hasReturn) continue;

      final sorted = [...entry.value]..sort((a, b) => a.startTime.compareTo(b.startTime));
      String returnTime = '22:00';
      if (sorted.isNotEmpty) {
        final last = sorted.last;
        final parts = last.startTime.split(':');
        if (parts.length == 2) {
          final h = int.tryParse(parts[0]);
          final m = int.tryParse(parts[1]);
          if (h != null && m != null) {
            final endMinutes = h * 60 + m + (last.durationMinutes ?? 0) + 30;
            final finalH = (endMinutes ~/ 60).clamp(0, 23);
            final finalM = endMinutes % 60;
            returnTime = '${finalH.toString().padLeft(2, '0')}:${finalM.toString().padLeft(2, '0')}';
          }
        }
      }
      // Si le returnTime calculé tombe sur le slot d'une activité existante
      // (cas typique : la dernière activité du jour fait pile durée=N min et
      // returnTime calculé = startTime de la N+1ème activité), on décale
      // pour éviter le conflit unique constraint sur (trip_id, day, time).
      final takenTimes = entry.value.map((a) => a.startTime).toSet();
      var attempts = 0;
      while (takenTimes.contains(returnTime) && attempts < 20) {
        final parts = returnTime.split(':');
        final h = int.parse(parts[0]);
        final m = int.parse(parts[1]);
        final totalMin = h * 60 + m + 15;
        if (totalMin >= 24 * 60) {
          // Pas de slot dispo dans la journée : on skip ce retour pour ne pas
          // crasher l'insert. L'utilisateur peut l'ajouter manuellement.
          developer.log(
            'Retour hôtel skip : tous les slots après ${sorted.last.startTime} pris pour le ${day.toIso8601String().split("T").first}',
            name: 'planning',
          );
          returnTime = '';
          break;
        }
        returnTime = '${(totalMin ~/ 60).toString().padLeft(2, '0')}:${(totalMin % 60).toString().padLeft(2, '0')}';
        attempts++;
      }
      if (returnTime.isEmpty) continue;

      // Stocke l'adresse de l'hôtel dans `detail` pour que "Voir sur Maps" puisse
      // l'utiliser directement (évite la recherche fuzzy sur le titre qui fait planter
      // l'app Maps sur un nom d'hébergement privé).
      final hotelAddress = dayHotel.metadata['address'] as String?;
      // Propage lat/lng géocodés au save du doc Hébergement → l'activité
      // "Retour à hôtel" devient un waypoint avec coords précises pour le
      // pipeline trajets et le bouton Itinéraire.
      final hotelLat = (dayHotel.metadata['latitude'] as num?)?.toDouble();
      final hotelLng = (dayHotel.metadata['longitude'] as num?)?.toDouble();
      rows.add({
        'trip_id': widget.tripId,
        'day_date': day.toIso8601String().split('T').first,
        'start_time': returnTime,
        'title': 'Retour à ${dayHotel.name}',
        if (hotelAddress != null && hotelAddress.isNotEmpty) 'detail': hotelAddress,
        'tag': 'Hébergement',
        // Le retour à l'hôtel est sémantiquement un transit (déplacement de
        // fin de journée vers le point d'ancrage). Marqué logistic pour que
        // la timeline le rende distinctement des activités de contenu, sans
        // pour autant masquer les infos pratiques (adresse, itinéraire).
        'activity_kind': 'logistic',
        'duration_minutes': 15,
        'price_estimate': 'Gratuit',
        'suggested': true,
        'latitude': ?hotelLat,
        'longitude': ?hotelLng,
      });
    }

    if (rows.isNotEmpty) {
      developer.log('Insertion de ${rows.length} retour(s) à l\'hôtel', name: 'planning');
      await client.from('trip_activities').insert(rows);
    }
  }

  /// Choisit le mode de transport par défaut à pré-sélectionner pour une paire,
  /// à partir des options dispo (Routes API) et du profil voyageur.
  ///
  /// Règles :
  /// - Trajet à pied ≤12 min : on privilégie "walk" (sauf Grand luxe).
  /// - Grand luxe / Voyage pro : taxi si dispo.
  /// - Backpack / Meilleur prix : walk → transit → premier dispo.
  /// - En famille : transit → taxi → premier dispo.
  /// - Default : transit si dispo, sinon le premier mode retourné.
  String _pickDefaultMode(List<TransportOption> options, String? travelerType) {
    if (options.isEmpty) return 'walk';
    TransportOption? findMode(String m) {
      for (final o in options) {
        if (o.mode == m) return o;
      }
      return null;
    }
    // 'transit' = générique Routes API (couvre métro/tram/bus). On regarde aussi
    // 'metro' pour rétrocompat avec d'éventuelles options Gemini fallback.
    TransportOption? findTransit() => findMode('transit') ?? findMode('metro');

    final walk = findMode('walk');
    if (walk != null && walk.durationMinutes <= 12 && travelerType != 'Grand luxe') {
      return 'walk';
    }
    switch (travelerType) {
      case 'Grand luxe':
      case 'Voyage pro':
        return findMode('taxi')?.mode ?? options.first.mode;
      case 'Backpack':
      case 'Meilleur prix':
        return findMode('walk')?.mode ?? findTransit()?.mode ?? options.first.mode;
      case 'En famille':
        return findTransit()?.mode ?? findMode('taxi')?.mode ?? options.first.mode;
      default:
        return findTransit()?.mode ?? options.first.mode;
    }
  }

  /// Liste plate des suggestions cochées, indépendamment du mode (auto/coPilot).
  /// Mode auto = `widget.suggestions[i]` pour `i ∈ _selected`.
  /// Mode coPilot = options cochées dans chaque groupe.
  List<ActivitySuggestion> _collectSelectedSuggestions() {
    if (widget.mode == PlanningMode.coPilot) {
      final out = <ActivitySuggestion>[];
      for (final entry in _selectedByGroup.entries) {
        final group = widget.groups[entry.key];
        for (final optIdx in entry.value) {
          out.add(group.options[optIdx]);
        }
      }
      return out;
    }
    return _selected.map((i) => widget.suggestions[i]).toList();
  }

  /// Mesure la distance entre activités consécutives du même jour (triées par
  /// heure) et logue un warning si une paire dépasse le seuil du profil voyageur
  /// (`maxConsecutiveDistanceMeters`). Pas de blocage — juste de la visibilité
  /// pour debug. Skipped pour les suggestions sans coords (= pas générées par
  /// le flow Places-first).
  void _checkConsecutiveDistances(List<ActivitySuggestion> selections) {
    final trip = ref.read(tripByIdProvider(widget.tripId)).valueOrNull;
    final profile = trip?.travelerType != null
        ? travelerPlacesProfiles[trip!.travelerType]
        : null;
    final maxMeters = profile?.maxConsecutiveDistanceMeters ?? 1500;

    final byDay = <String, List<ActivitySuggestion>>{};
    for (final s in selections) {
      final key = s.dayDate.toIso8601String().split('T').first;
      byDay.putIfAbsent(key, () => []).add(s);
    }
    for (final entry in byDay.entries) {
      final list = [...entry.value]..sort((a, b) => a.startTime.compareTo(b.startTime));
      for (var i = 0; i < list.length - 1; i++) {
        final a = list[i];
        final b = list[i + 1];
        if (a.latitude == null || a.longitude == null ||
            b.latitude == null || b.longitude == null) {
          continue;
        }
        final km = haversineKm(a.latitude!, a.longitude!, b.latitude!, b.longitude!);
        final meters = (km * 1000).round();
        if (meters > maxMeters) {
          developer.log(
            'Distance dépassée jour ${entry.key} : "${a.title}" → "${b.title}" '
            '= ${meters}m (seuil profil ${trip?.travelerType ?? "default"} = ${maxMeters}m)',
            name: 'planning',
          );
        }
      }
    }
  }

  Future<void> _save() async {
    final rawSelections = _collectSelectedSuggestions();
    if (rawSelections.isEmpty) return;
    developer.log(
      '_save START — mode=${widget.mode.name}, selected=${rawSelections.length}',
      name: 'planning',
    );
    // Check distance haversine post-sélection (mode coPilot Places-first
    // uniquement, car seul lui injecte les coords lat/lng dans les options).
    // Pour chaque jour, on calcule la distance entre activités cochées
    // consécutives (triées par heure) et on log un warning si dépassement
    // du `maxConsecutiveDistanceMeters` du profil voyageur. Pas de blocage —
    // le voyageur a choisi délibérément, on l'informe seulement.
    if (widget.mode == PlanningMode.coPilot) {
      _checkConsecutiveDistances(rawSelections);
    }
    setState(() => _saving = true);
    try {
      // Tous les titres/adresses viennent DÉJÀ de Places (Auto + CoPilot sont
      // sur Places-first depuis 4d 2026-04-26) — pas besoin de canonisation.
      final client = ref.read(supabaseProvider);
      final rawRows = rawSelections.map((s) => s.toInsertJson(widget.tripId)).toList();
      // Dédup sur (day_date, start_time) : la contrainte unique
      // `trip_activities_unique_entry` côté Postgres rejette 2 activités au même
      // créneau. Le pipeline Places-first peut proposer 2 lieux pour le même
      // slot quand 2 intérêts ciblent le même créneau (ex: Randonnée 14h +
      // Nature 14h). On décale les suivants de 30 min, sinon on les drop si
      // ça déborde minuit.
      final taken = <String>{};
      final rows = <Map<String, dynamic>>[];
      for (final row in rawRows) {
        final day = row['day_date'] as String;
        var time = row['start_time'] as String;
        var key = '$day|$time';
        var attempts = 0;
        while (taken.contains(key) && attempts < 12) {
          // Décale de 30 min jusqu'à trouver un slot libre (max 6h de décalage).
          final parts = time.split(':');
          final h = int.parse(parts[0]);
          final m = int.parse(parts[1]);
          final totalMin = h * 60 + m + 30;
          if (totalMin >= 24 * 60) break;
          time = '${(totalMin ~/ 60).toString().padLeft(2, '0')}:${(totalMin % 60).toString().padLeft(2, '0')}';
          key = '$day|$time';
          attempts++;
        }
        if (taken.contains(key)) {
          developer.log(
            'Dédup : drop "${row['title']}" — slot $day $time déjà pris (et impossible à décaler)',
            name: 'planning',
          );
          continue;
        }
        if (time != row['start_time']) {
          developer.log(
            'Dédup : "${row['title']}" décalé de ${row['start_time']} → $time pour éviter conflit',
            name: 'planning',
          );
          row['start_time'] = time;
        }
        taken.add(key);
        rows.add(row);
      }
      developer.log('Insertion de ${rows.length} activité(s) dans trip_activities (depuis ${rawRows.length} suggestions)', name: 'planning');
      final inserted = await client.from('trip_activities').insert(rows).select();
      developer.log('Résultat insert : ${(inserted as List).length} ligne(s) retournée(s)', name: 'planning');
      if (inserted.isEmpty) {
        throw Exception('Aucune activité insérée (vérifie les policies RLS sur trip_activities).');
      }

      // Génération des descriptions en BATCH (fire-and-forget — l'UI n'attend pas)
      final insertedActivities = inserted.map((e) => TripActivity.fromJson(e)).toList();
      unawaited(_generateDescriptionsInBackground(insertedActivities));

      // Insert auto des retours à l'hôtel (si hôtel renseigné + jour dans la période de la résa)
      await _autoInsertHotelReturns(client);

      // Récupère toutes les activités du voyage (existantes + nouvellement insérées) triées par jour + heure
      final all = await client
          .from('trip_activities')
          .select()
          .eq('trip_id', widget.tripId)
          .order('day_date', ascending: true)
          .order('start_time', ascending: true);
      final allActivities = (all as List).map((e) => TripActivity.fromJson(e)).toList();
      // NOTE : on ne fusionne PAS les activités virtuelles `doc:xxx:checkin/checkout`
      // ici. Elles ne sont pas en DB (calculées à la volée par planningTimelineProvider)
      // donc leurs IDs préfixés `doc:` ne sont pas des UUID valides — l'INSERT dans
      // `trip_transports.from_activity_id` (colonne uuid) plante avec
      // "invalid input syntax for type uuid". Les trajets hôtel ↔ activité sont
      // assurés par les vraies activités "Retour à <hôtel>" créées par
      // _autoInsertHotelReturns (avec UUID propre + lat/lng depuis le doc géocodé).

      // Récupère les transports déjà en base pour éviter les doublons
      final existingTransportsData = await client
          .from('trip_transports')
          .select('from_activity_id, to_activity_id')
          .eq('trip_id', widget.tripId);
      final existingPairs = (existingTransportsData as List)
          .map((e) => '${e['from_activity_id']}|${e['to_activity_id']}')
          .toSet();

      // ─── Construction des transports pour chaque paire consécutive même jour ──
      // Routes API (Google Maps) si on a les place_id des 2 activités → durées
      // RÉELLES. Sinon skip : pas de transport pour cette paire.
      // (Le fallback Gemini historique a disparu avec la bascule Places-first :
      // les suggestions ne contiennent plus de bloc transport hallucinable.)

      // Identifie les paires à traiter (consécutives même jour, pas déjà en DB).
      final pairs = <(TripActivity, TripActivity)>[];
      for (var i = 0; i < allActivities.length - 1; i++) {
        final a = allActivities[i];
        final b = allActivities[i + 1];
        final sameDay = a.dayDate.year == b.dayDate.year &&
            a.dayDate.month == b.dayDate.month &&
            a.dayDate.day == b.dayDate.day;
        if (!sameDay) continue;
        if (existingPairs.contains('${a.id}|${b.id}')) continue;
        pairs.add((a, b));
      }

      final routesService = ref.read(routesServiceProvider);
      final placesService = ref.read(placesCacheServiceProvider);
      final trip = ref.read(tripByIdProvider(widget.tripId)).valueOrNull;
      final destination = trip?.destination ?? '';

      developer.log(
        'Construction transports : ${pairs.length} paire(s) consécutive(s) à traiter',
        name: 'planning',
      );
      // Lance les calculs Routes en parallèle pour limiter la latence sur les
      // gros plannings. Chaque slot construit 2 RouteEndpoints :
      // - Si l'activité a déjà lat/lng (cas hôtel virtual géocodé au save),
      //   on les utilise directement → pas de Places lookup, pas de coût.
      // - Sinon (activité réelle Places), on fait le findInfo() pour obtenir
      //   le placeId.
      Future<RouteEndpoint?> resolveEndpoint(TripActivity act) async {
        if (act.hasCoordinates) {
          return RouteEndpoint.coords(lat: act.latitude!, lng: act.longitude!);
        }
        final info = await placesService.findInfo(title: act.title, destination: destination);
        if (info.placeId != null && info.placeId!.isNotEmpty) {
          return RouteEndpoint.placeId(info.placeId!);
        }
        return null;
      }

      final transportResults = await Future.wait(pairs.map((pair) async {
        final (a, b) = pair;
        final epA = await resolveEndpoint(a);
        final epB = await resolveEndpoint(b);

        List<TransportOption>? routesOptions;
        if (epA != null && epB != null) {
          routesOptions = await routesService.computeOptionsFromEndpoints(
            from: epA,
            to: epB,
          );
          developer.log(
            'Routes "${a.title}" → "${b.title}" : '
            '${routesOptions == null ? "ÉCHEC (null)" : "${routesOptions.length} options [${routesOptions.map((o) => o.mode).join(", ")}]"}',
            name: 'planning',
          );
        } else {
          developer.log(
            'Routes "${a.title}" → "${b.title}" : SKIP (endpoint introuvable — A=${epA == null ? "null" : "ok"}, B=${epB == null ? "null" : "ok"})',
            name: 'planning',
          );
        }

        if (routesOptions == null || routesOptions.isEmpty) return null;
        final finalOptions = routesOptions;
        final defaultMode = _pickDefaultMode(finalOptions, widget.travelerType);

        final defaultOpt = finalOptions.firstWhere(
          (o) => o.mode == defaultMode,
          orElse: () => finalOptions.first,
        );
        return {
          'trip_id': widget.tripId,
          'from_activity_id': a.id,
          'to_activity_id': b.id,
          'selected_mode': defaultOpt.mode,
          'selected_duration_minutes': defaultOpt.durationMinutes,
          'selected_price_estimate': defaultOpt.priceEstimate,
          'options': finalOptions.map((o) => o.toJson()).toList(),
        };
      }));
      final transportRows = transportResults.whereType<Map<String, dynamic>>().toList();

      if (transportRows.isNotEmpty) {
        developer.log('Insertion de ${transportRows.length} trajet(s) dans trip_transports (Routes API)', name: 'planning');
        await client.from('trip_transports').insert(transportRows);
      }

      ref.invalidate(tripActivitiesProvider(widget.tripId));
      ref.invalidate(tripTransportsProvider(widget.tripId));
      await ref.read(tripActivitiesProvider(widget.tripId).future);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCoPilot = widget.mode == PlanningMode.coPilot;
    final height = MediaQuery.of(context).size.height * 0.85;
    final selectedCount = isCoPilot ? _coPilotSelectedCount : _selected.length;
    final canSave = !_saving && selectedCount > 0;

    return SizedBox(
      height: height,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isCoPilot ? '🎯 Co-pilote IA' : '✨ Suggestions IA',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isCoPilot
                            ? 'Pour chaque créneau, choisis la ou les options qui te plaisent.'
                            : 'Coche celles que tu veux ajouter à ton planning.',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (isCoPilot)
                  TextButton(
                    onPressed: () => setState(() {
                      if (_coPilotSelectedCount == _coPilotTotalOptions) {
                        // Tout coché actuellement → tout décocher = reset
                        _selectedByGroup.clear();
                      } else {
                        // Cocher toutes les options de tous les groupes — utile pour
                        // un import massif que le voyageur va trier ensuite dans le planning.
                        _selectedByGroup.clear();
                        for (var gIdx = 0; gIdx < widget.groups.length; gIdx++) {
                          _selectedByGroup[gIdx] = Set<int>.from(
                            List.generate(widget.groups[gIdx].options.length, (i) => i),
                          );
                        }
                      }
                    }),
                    child: Text(
                      _coPilotSelectedCount == _coPilotTotalOptions ? 'Tout décocher' : 'Tout cocher',
                      style: const TextStyle(fontSize: 12),
                    ),
                  )
                else
                  TextButton(
                    onPressed: () => setState(() {
                      if (_selected.length == widget.suggestions.length) {
                        _selected.clear();
                      } else {
                        _selected.addAll(List.generate(widget.suggestions.length, (i) => i));
                      }
                    }),
                    child: Text(
                      _selected.length == widget.suggestions.length ? 'Tout décocher' : 'Tout cocher',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                  color: AppColors.textSecondary,
                  tooltip: 'Fermer',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(child: isCoPilot ? _buildCoPilotBody() : _buildAutoBody()),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            decoration: BoxDecoration(color: AppColors.surface, border: Border(top: BorderSide(color: AppColors.border))),
            child: SafeArea(
              top: false,
              child: ElevatedButton(
                onPressed: canSave ? _save : null,
                child: _saving
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : Text(
                        selectedCount == 0
                            ? 'Sélectionne au moins une option'
                            : 'Ajouter $selectedCount activité${selectedCount > 1 ? 's' : ''} au planning',
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Mode auto : liste plate des suggestions, tout coché par défaut.
  Widget _buildAutoBody() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: widget.suggestions.length,
      itemBuilder: (_, i) {
        final s = widget.suggestions[i];
        final selected = _selected.contains(i);
        return _buildOptionCard(
          s,
          isSelected: selected,
          onToggle: () => setState(() => selected ? _selected.remove(i) : _selected.add(i)),
          showDateChip: true,
        );
      },
    );
  }

  /// Mode coPilot : sections par créneau (une section par groupe), 3 cartes
  /// par section, toutes décochées au départ. Multi-select libre dans un groupe.
  Widget _buildCoPilotBody() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: widget.groups.length,
      itemBuilder: (_, gIdx) {
        final group = widget.groups[gIdx];
        final selectedSet = _selectedByGroup[gIdx] ?? const <int>{};
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      group.slotLabel.toUpperCase(),
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.accent, letterSpacing: 0.6),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _formatGroupDate(group.dayDate, group.startTime),
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (selectedSet.isNotEmpty)
                    Text(
                      '${selectedSet.length}/${group.options.length}',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.primary),
                    ),
                ],
              ),
            ),
            ...List.generate(group.options.length, (oIdx) {
              final s = group.options[oIdx];
              final isSel = selectedSet.contains(oIdx);
              return _buildOptionCard(
                s,
                isSelected: isSel,
                onToggle: () => setState(() {
                  final set = _selectedByGroup.putIfAbsent(gIdx, () => <int>{});
                  if (isSel) {
                    set.remove(oIdx);
                    if (set.isEmpty) _selectedByGroup.remove(gIdx);
                  } else {
                    set.add(oIdx);
                  }
                }),
                showDateChip: false,
              );
            }),
          ],
        );
      },
    );
  }

  String _formatGroupDate(DateTime d, String startTime) {
    final wd = _weekdays[(d.weekday - 1).clamp(0, 6)];
    final timePart = startTime.isEmpty ? '' : ' · $startTime';
    return '$wd ${d.day} ${_months[d.month - 1]}$timePart';
  }

  /// Carte d'une option (auto OU coPilot). Photo Places + checkbox + détails +
  /// raison du match (coPilot uniquement). Tap sur la carte = ouvre le détail,
  /// tap sur la checkbox = toggle de la sélection.
  Widget _buildOptionCard(
    ActivitySuggestion s, {
    required bool isSelected,
    required VoidCallback onToggle,
    required bool showDateChip,
  }) {
    return FutureBuilder<PlaceInfo>(
      future: _placeInfoFor(s),
      builder: (_, snap) {
        final info = snap.data;
        final loading = snap.connectionState != ConnectionState.done;
        final photoUrl = info?.photos.isNotEmpty == true ? info!.photos.first.url : null;
        return GestureDetector(
          onTap: () {
            final destination = ref.read(tripByIdProvider(widget.tripId)).valueOrNull?.destination ?? '';
            openSuggestionDetailSheet(context, ref, suggestion: s, destination: destination);
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: isSelected ? AppColors.primaryLight : AppColors.surface,
              border: Border.all(color: isSelected ? AppColors.primary : AppColors.border, width: isSelected ? 1.5 : 1),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 90, height: 110,
                  child: photoUrl != null
                      ? CachedNetworkImage(
                          imageUrl: photoUrl,
                          fit: BoxFit.cover,
                          placeholder: (_, _) => Container(color: AppColors.primaryLight),
                          errorWidget: (_, _, _) => Container(color: const Color(0xFFF3F4F6), child: Icon(Icons.image_outlined, size: 28, color: AppColors.textSecondary)),
                        )
                      : Container(
                          color: loading ? AppColors.primaryLight : const Color(0xFFF3F4F6),
                          child: Center(
                            child: loading
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : Icon(Icons.image_outlined, size: 28, color: AppColors.textSecondary),
                          ),
                        ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GestureDetector(
                          onTap: onToggle,
                          child: Container(
                            width: 22, height: 22,
                            margin: const EdgeInsets.only(top: 2),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isSelected ? AppColors.primary : Colors.transparent,
                              border: Border.all(color: isSelected ? AppColors.primary : AppColors.border, width: 2),
                            ),
                            child: isSelected ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (showDateChip)
                                Text(
                                  '${s.dayDate.day} ${_months[s.dayDate.month - 1]} · ${s.startTime}',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.accent),
                                )
                              else if (s.startTime.isNotEmpty)
                                Text(
                                  s.startTime,
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.accent),
                                ),
                              if (showDateChip || s.startTime.isNotEmpty) const SizedBox(height: 2),
                              Text(s.title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary), maxLines: 2, overflow: TextOverflow.ellipsis),
                              if (info?.rating != null) ...[
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    const Icon(Icons.star, size: 12, color: Color(0xFFF59E0B)),
                                    const SizedBox(width: 2),
                                    Text(info!.rating!.toStringAsFixed(1), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                                    if (info.ratingsCount != null) ...[
                                      const SizedBox(width: 3),
                                      Text('(${info.ratingsCount})', style: TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                                    ],
                                  ],
                                ),
                              ],
                              if (s.detail != null && s.detail!.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(s.detail!, style: TextStyle(fontSize: 10, color: AppColors.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
                              ],
                              if (s.matchReason != null && s.matchReason!.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: AppColors.accent.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '✨ ${s.matchReason!}',
                                    style: TextStyle(fontSize: 10, color: AppColors.accent, fontWeight: FontWeight.w600, height: 1.3),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: [
                                  _Pill(label: s.tag, color: AppColors.primary, bg: AppColors.primaryLight),
                                  if (s.durationMinutes != null && s.durationMinutes! > 0)
                                    _Pill(label: '⏱ ${formatDuration(s.durationMinutes)}', color: AppColors.textSecondary, bg: const Color(0xFFF3F4F6)),
                                  if (info?.priceLevelLabel != null)
                                    _Pill(label: info!.priceLevelLabel!, color: AppColors.textSecondary, bg: const Color(0xFFF3F4F6))
                                  else if (s.priceEstimate != null && s.priceEstimate!.isNotEmpty)
                                    ConvertedPricePill(rawPrice: s.priceEstimate, color: AppColors.textSecondary, bg: const Color(0xFFF3F4F6)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PlanningContent extends ConsumerStatefulWidget {
  final String tripId;
  final List<TripActivity> activities;
  final List<TripTransport> transports;
  const _PlanningContent({required this.tripId, required this.activities, this.transports = const []});

  @override
  ConsumerState<_PlanningContent> createState() => _PlanningContentState();
}

class _PlanningContentState extends ConsumerState<_PlanningContent> {
  static const _weekdays = ['Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi', 'Dimanche'];
  static const _monthsShort = [
    'janv.', 'févr.', 'mars', 'avril', 'mai', 'juin',
    'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.',
  ];
  static const _monthsLong = [
    'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
    'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
  ];

  static const _overlapPalette = <(Color, Color)>[
    (Color(0xFFDBEAFE), Color(0xFF93C5FD)),
    (Color(0xFFFCE7F3), Color(0xFFF9A8D4)),
    (Color(0xFFD1FAE5), Color(0xFF6EE7B7)),
    (Color(0xFFEDE9FE), Color(0xFFC4B5FD)),
    (Color(0xFFFFEDD5), Color(0xFFFDBA74)),
  ];

  late PageController _pageController;
  int _currentIndex = 0;
  List<DateTime> _sortedDays = const [];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _recomputeDays();
  }

  @override
  void didUpdateWidget(covariant _PlanningContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    _recomputeDays();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _recomputeDays() {
    String norm(String s) => s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
    final seen = <String>{};
    final uniqueDays = <DateTime>{};
    for (final a in widget.activities) {
      final key = '${a.dayDate.toIso8601String().split('T').first}|${a.startTime}|${norm(a.title)}';
      if (seen.add(key)) {
        uniqueDays.add(DateTime(a.dayDate.year, a.dayDate.month, a.dayDate.day));
      }
    }
    final sorted = uniqueDays.toList()..sort();
    _sortedDays = sorted;

    // Sélectionne automatiquement aujourd'hui si dans le voyage, sinon reste sur l'index courant clampé
    final today = DateTime.now();
    final todayKey = DateTime(today.year, today.month, today.day);
    final todayIdx = sorted.indexWhere((d) => d.isAtSameMomentAs(todayKey));
    if (_currentIndex == 0 && todayIdx >= 0) {
      _currentIndex = todayIdx;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pageController.hasClients) _pageController.jumpToPage(todayIdx);
      });
    }
    if (_currentIndex >= sorted.length && sorted.isNotEmpty) {
      _currentIndex = sorted.length - 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sortedDays.isEmpty) return const SizedBox.shrink();

    String norm(String s) => s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
    final seen = <String>{};
    final unique = <TripActivity>[];
    for (final a in widget.activities) {
      final key = '${a.dayDate.toIso8601String().split('T').first}|${a.startTime}|${norm(a.title)}';
      if (seen.add(key)) unique.add(a);
    }

    final grouped = <DateTime, List<TripActivity>>{};
    for (final a in unique) {
      final key = DateTime(a.dayDate.year, a.dayDate.month, a.dayDate.day);
      grouped.putIfAbsent(key, () => []).add(a);
    }

    // Overlap coloring
    final overlapColorByActivityId = <String, (Color, Color)>{};
    var overlapIdx = 0;
    for (final day in _sortedDays) {
      final byTime = <String, List<TripActivity>>{};
      for (final a in grouped[day] ?? const <TripActivity>[]) {
        byTime.putIfAbsent(a.startTime, () => []).add(a);
      }
      final sortedTimes = byTime.keys.toList()..sort();
      for (final time in sortedTimes) {
        final acts = byTime[time]!;
        if (acts.length > 1) {
          final palette = _overlapPalette[overlapIdx % _overlapPalette.length];
          for (final a in acts) {
            overlapColorByActivityId[a.id] = palette;
          }
          overlapIdx++;
        }
      }
    }

    final transportByPair = <String, TripTransport>{
      for (final t in widget.transports) '${t.fromActivityId}|${t.toActivityId}': t,
    };

    return Column(
      children: [
        _DayPillsBar(
          days: _sortedDays,
          currentIndex: _currentIndex,
          monthsShort: _monthsShort,
          onTap: (i) {
            setState(() => _currentIndex = i);
            _pageController.animateToPage(i, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
          },
        ),
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: _sortedDays.length,
            onPageChanged: (i) => setState(() => _currentIndex = i),
            itemBuilder: (_, i) {
              final day = _sortedDays[i];
              final dayActs = (grouped[day] ?? const <TripActivity>[]).toList()
                ..sort((a, b) {
                  final t = a.startTime.compareTo(b.startTime);
                  return t != 0 ? t : a.title.compareTo(b.title);
                });
              return ReorderableListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
                // Drag handles explicites au lieu du long-press par défaut.
                // Sur Android, le défaut n'affichait AUCUN indicateur visuel et
                // les utilisateurs ignoraient que le reorder existait.
                buildDefaultDragHandles: false,
                header: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _DayHeader(
                    title: 'Jour ${i + 1} · ${_weekdays[day.weekday - 1]} ${day.day} ${_monthsLong[day.month - 1]}',
                    count: dayActs.length,
                    tripId: widget.tripId,
                    day: day,
                  ),
                ),
                footer: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: OutlinedButton.icon(
                    onPressed: () => openActivityCreateSheet(context, ref, tripId: widget.tripId, defaultDay: day),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Ajouter une activité'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 44),
                      foregroundColor: AppColors.primary,
                      side: BorderSide(color: AppColors.primary),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                itemCount: dayActs.length,
                onReorder: (oldIdx, newIdx) => _handleReorder(dayActs, oldIdx, newIdx),
                itemBuilder: (_, idx) {
                  final a = dayActs[idx];
                  final next = idx + 1 < dayActs.length ? dayActs[idx + 1] : null;
                  final transport = next != null ? transportByPair['${a.id}|${next.id}'] : null;
                  // Ne proposer l'ajout que si on peut l'attacher à 2 activités réelles
                  // (les trajets sont stockés avec des IDs réels uniquement).
                  final canAddTransport = next != null &&
                      transport == null &&
                      !isVirtualActivity(a.id) &&
                      !isVirtualActivity(next.id);
                  // Handle de drag visible (icône grid à gauche). Pour les
                  // activités virtuelles (liées à un wallet doc), pas de handle
                  // — on aligne avec un SizedBox de même largeur pour garder
                  // les cards alignées.
                  return Column(
                    key: ValueKey(a.id),
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (!isVirtualActivity(a.id))
                            ReorderableDragStartListener(
                              index: idx,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
                                child: Icon(Icons.drag_indicator, size: 22, color: AppColors.textSecondary),
                              ),
                            )
                          else
                            const SizedBox(width: 26),
                          Expanded(
                            child: _ActivityItem(activity: a, overlapColors: overlapColorByActivityId[a.id]),
                          ),
                        ],
                      ),
                      if (transport != null && next != null)
                        _TransportLeg(transport: transport, fromActivity: a, toActivity: next)
                      else if (canAddTransport)
                        _AddTransportButton(tripId: widget.tripId, fromActivity: a, toActivity: next),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  int? _timeToMin(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  String _minToTime(int min) {
    final clamped = min.clamp(0, 23 * 60 + 59);
    final h = clamped ~/ 60;
    final m = clamped % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  Future<void> _handleReorder(List<TripActivity> dayActs, int oldIndex, int newIndex) async {
    final originalOldIdx = oldIndex;
    final originalNewIdx = newIndex;
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;

    final moved = dayActs[oldIndex];
    if (isVirtualActivity(moved.id)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cette activité est liée à un document. Modifie-la via le wallet.')),
      );
      return;
    }

    // Logging defensif : permet de répro un éventuel bug d'inversion en
    // capturant l'ordre vu par Flutter (oldIdx/newIdx avant correction) ET
    // l'ordre construit par l'algo. Si Lalith signale "drag → ordre inversé",
    // ces logs permettent de comparer ordre attendu vs ordre appliqué.
    debugPrint('[reorder] flutter oldIdx=$originalOldIdx newIdx=$originalNewIdx → corrected newIdx=$newIndex');
    debugPrint('[reorder] dayActs initial: ${dayActs.map((a) => '${a.title}@${a.startTime}').join(' | ')}');

    final reordered = [...dayActs];
    final item = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, item);
    debugPrint('[reorder] reordered after insert: ${reordered.map((a) => '${a.title}@${a.startTime}').join(' | ')}');

    final client = ref.read(supabaseProvider);

    // Lookup des durées de trajet existantes (les deux directions fusionnées)
    final transportDurationByPair = <String, int>{};
    try {
      final data = await client.from('trip_transports').select().eq('trip_id', widget.tripId);
      for (final row in (data as List)) {
        final t = TripTransport.fromJson(row);
        transportDurationByPair['${t.fromActivityId}|${t.toActivityId}'] = t.selectedDurationMinutes;
        transportDurationByPair['${t.toActivityId}|${t.fromActivityId}'] = t.selectedDurationMinutes;
      }
    } catch (e) {
      developer.log('Erreur fetch transports : $e', name: 'planning');
    }

    // Slots originaux (activités réelles, ordre chronologique)
    final chronologicalReals = [...dayActs]
      ..sort((a, b) {
        final t = a.startTime.compareTo(b.startTime);
        return t != 0 ? t : a.title.compareTo(b.title);
      });
    final freeSlots = chronologicalReals
        .where((a) => !isVirtualActivity(a.id))
        .map((a) => a.startTime)
        .toList();

    final realsInNewOrder = reordered.where((a) => !isVirtualActivity(a.id)).toList();

    // Recalcul : slot swap + respect de la durée + transport en cascade
    const defaultTransportMin = 30;
    final updates = <String, String>{};
    int? prevEndMin;
    String? prevId;

    for (var i = 0; i < realsInNewOrder.length && i < freeSlots.length; i++) {
      final a = realsInNewOrder[i];
      final slotMin = _timeToMin(freeSlots[i]) ?? 9 * 60;
      int newStartMin;

      if (prevEndMin == null || prevId == null) {
        // Première activité : garde son créneau
        newStartMin = slotMin;
      } else {
        final transportMin = transportDurationByPair['$prevId|${a.id}'] ?? defaultTransportMin;
        final earliest = prevEndMin + transportMin;
        // Prend son créneau SI celui-ci est >= earliest, sinon on pousse
        newStartMin = slotMin >= earliest ? slotMin : earliest;
      }

      final newTime = _minToTime(newStartMin);
      if (newTime != a.startTime) updates[a.id] = newTime;

      prevEndMin = newStartMin + (a.durationMinutes ?? 60);
      prevId = a.id;
    }

    debugPrint('[reorder] updates à appliquer: ${updates.entries.map((e) => '${e.key.substring(0, 6)}→${e.value}').join(' | ')}');

    // Applique les updates en DB en parallèle pour minimiser la fenêtre où
    // l'UI montre encore les anciens horaires (entre la fin du drag et le
    // re-fetch via `ref.invalidate`). Sequentiel = ~50ms × N updates ; parallel
    // = max(50ms). Réduit l'effet "snap-back" perçu pendant le drag.
    await Future.wait(updates.entries.map((entry) async {
      try {
        await client.from('trip_activities').update({'start_time': entry.value}).eq('id', entry.key);
      } catch (e) {
        developer.log('Erreur update time ${entry.key}: $e', name: 'planning');
      }
    }));

    // Réaligne les trajets sur les nouvelles adjacences
    await _fixTransportsAfterReorder(reordered);

    ref.invalidate(tripActivitiesProvider(widget.tripId));
    ref.invalidate(tripTransportsProvider(widget.tripId));

    if (mounted && updates.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ordre mis à jour · ${updates.length} horaire${updates.length > 1 ? 's' : ''} recalculé${updates.length > 1 ? 's' : ''}.')),
      );
    }
  }

  /// Après un reorder, réaligne les trajets existants sur les nouvelles adjacences.
  /// - Si from→to correspond toujours à une adjacence : ne touche à rien
  /// - Si to→from correspond (swap direct) : inverse from/to du trajet
  /// - Sinon : supprime le trajet devenu invalide
  Future<void> _fixTransportsAfterReorder(List<TripActivity> reordered) async {
    final client = ref.read(supabaseProvider);

    // Adjacences des activités réelles dans le nouvel ordre
    final realsInNewOrder = reordered.where((a) => !isVirtualActivity(a.id)).toList();
    final newAdjacency = <String, String>{};
    for (var i = 0; i < realsInNewOrder.length - 1; i++) {
      newAdjacency[realsInNewOrder[i].id] = realsInNewOrder[i + 1].id;
    }

    // Récupère les trajets en base
    List<TripTransport> transports;
    try {
      final data = await client.from('trip_transports').select().eq('trip_id', widget.tripId);
      transports = (data as List).map((e) => TripTransport.fromJson(e)).toList();
    } catch (e) {
      developer.log('Erreur fetch transports : $e', name: 'planning');
      return;
    }

    final realIds = realsInNewOrder.map((a) => a.id).toSet();
    for (final t in transports) {
      // On ne touche que les trajets dont from ET to sont dans CE jour
      if (!realIds.contains(t.fromActivityId) || !realIds.contains(t.toActivityId)) continue;

      final expectedTo = newAdjacency[t.fromActivityId];
      if (expectedTo == t.toActivityId) continue; // déjà aligné

      // Swap direct (from↔to renversés) ?
      if (newAdjacency[t.toActivityId] == t.fromActivityId) {
        try {
          await client.from('trip_transports').update({
            'from_activity_id': t.toActivityId,
            'to_activity_id': t.fromActivityId,
          }).eq('id', t.id);
        } catch (_) {
          // Contrainte unique violée ou autre souci → on supprime
          try {
            await client.from('trip_transports').delete().eq('id', t.id);
          } catch (_) {}
        }
        continue;
      }

      // Plus valide dans aucune direction → on supprime
      try {
        await client.from('trip_transports').delete().eq('id', t.id);
      } catch (_) {}
    }
  }
}

class _DayPillsBar extends StatelessWidget {
  final List<DateTime> days;
  final int currentIndex;
  final List<String> monthsShort;
  final ValueChanged<int> onTap;

  const _DayPillsBar({
    required this.days,
    required this.currentIndex,
    required this.monthsShort,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: SizedBox(
        height: 56,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: days.length,
          itemBuilder: (_, i) {
            final d = days[i];
            final selected = i == currentIndex;
            return GestureDetector(
              onTap: () => onTap(i),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: selected ? AppColors.primary : AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'J${i + 1}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: selected ? Colors.white : AppColors.primary,
                      ),
                    ),
                    Text(
                      '${d.day} ${monthsShort[d.month - 1]}',
                      style: TextStyle(
                        fontSize: 11,
                        color: selected ? Colors.white : AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DayHeader extends ConsumerWidget {
  final String title;
  final int count;
  final String tripId;
  final DateTime day;
  const _DayHeader({required this.title, required this.count, required this.tripId, required this.day});

  Future<void> _clearDay(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Vider ce jour ?'),
        content: Text(
          'Cette action supprime toutes les activités planifiées pour $title. '
          'Les documents (hôtels, vols, billets) restent intacts. Action irréversible.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Vider'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final client = ref.read(supabaseProvider);
      final iso = '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      // 1) récupère les IDs d'activités pour ce jour, pour purger les transports liés
      final rows = await client.from('trip_activities').select('id').eq('trip_id', tripId).eq('day_date', iso);
      final ids = (rows as List).map((r) => r['id'] as String).toList();
      if (ids.isNotEmpty) {
        await client.from('trip_transports').delete().inFilter('from_activity_id', ids);
        await client.from('trip_transports').delete().inFilter('to_activity_id', ids);
      }
      await client.from('trip_activities').delete().eq('trip_id', tripId).eq('day_date', iso);
      ref.invalidate(tripActivitiesProvider(tripId));
      ref.invalidate(tripTransportsProvider(tripId));
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(content: Text('${ids.length} activité${ids.length > 1 ? 's' : ''} supprimée${ids.length > 1 ? 's' : ''}.')));
      }
    } catch (e) {
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error));
      }
    }
  }

  Future<void> _clearFutureTrip(BuildContext context, WidgetRef ref) async {
    // Capture le messenger synchroneously — on peut l'utiliser après les await
    // sans avoir à guarder chaque usage avec `context.mounted`.
    final messenger = ScaffoldMessenger.of(context);
    // 1) Récupère la liste complète des activités pour décider en Dart (comparaison
    // date fiable, vs risque de décalage timezone si on laisse Supabase comparer).
    final client = ref.read(supabaseProvider);
    final now = DateTime.now();
    final todayDay = DateTime(now.year, now.month, now.day);

    List<Map<String, dynamic>> allRows;
    try {
      final res = await client.from('trip_activities').select('id, day_date, title').eq('trip_id', tripId);
      allRows = (res as List).cast<Map<String, dynamic>>();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Erreur lecture : $e'), backgroundColor: AppColors.error),
      );
      return;
    }

    final toDelete = <String>[];
    DateTime? earliest;
    DateTime? latest;
    for (final r in allRows) {
      final dateStr = r['day_date'] as String?;
      if (dateStr == null) continue;
      final parsed = DateTime.tryParse(dateStr);
      if (parsed == null) continue;
      final day = DateTime(parsed.year, parsed.month, parsed.day);
      if (!day.isBefore(todayDay)) {
        toDelete.add(r['id'] as String);
        if (earliest == null || day.isBefore(earliest)) earliest = day;
        if (latest == null || day.isAfter(latest)) latest = day;
      }
    }
    debugPrint('[CLEAR] today=$todayDay, nb à supprimer=${toDelete.length}, plage=$earliest → $latest');

    if (toDelete.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Aucune activité à supprimer (pas de jours à venir).')),
        );
      }
      return;
    }

    // 2) Confirmation avec plage exacte
    String fmt(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Tout supprimer à venir ?'),
        content: Text(
          'Cette action supprime ${toDelete.length} activité${toDelete.length > 1 ? 's' : ''} '
          'entre le ${fmt(earliest!)} et le ${fmt(latest!)} (inclus).\n\n'
          'Les jours antérieurs à aujourd\'hui (${fmt(todayDay)}) sont préservés. '
          'Les documents (hôtels, vols, billets) restent intacts. Action irréversible.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Tout supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // 3) Purge transports puis activités, par IDs explicites
    try {
      await client.from('trip_transports').delete().inFilter('from_activity_id', toDelete);
      await client.from('trip_transports').delete().inFilter('to_activity_id', toDelete);
      await client.from('trip_activities').delete().inFilter('id', toDelete);
      ref.invalidate(tripActivitiesProvider(tripId));
      ref.invalidate(tripTransportsProvider(tripId));
      messenger.showSnackBar(SnackBar(content: Text('${toDelete.length} activité${toDelete.length > 1 ? 's' : ''} supprimée${toDelete.length > 1 ? 's' : ''}.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Erreur suppression : $e'), backgroundColor: AppColors.error));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final todayDay = DateTime(now.year, now.month, now.day);
    final thisDay = DateTime(day.year, day.month, day.day);
    final isDayPast = thisDay.isBefore(todayDay);

    final budget = ref.watch(tripBudgetProvider(tripId)).valueOrNull;
    final userCurrency = ref.watch(userCurrencyProvider);
    final iso = thisDay.toIso8601String().split('T').first;
    final dayAmount = budget?.byDay[iso] ?? 0;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text('📅 $title', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis),
        ),
        Text('$count activité${count > 1 ? 's' : ''}', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
        if (dayAmount > 0) ...[
          const SizedBox(width: 6),
          Text(
            '· ~${CurrencyService.formatAmount(dayAmount, userCurrency)}',
            style: TextStyle(fontSize: 12, color: AppColors.textPrimary, fontWeight: FontWeight.w800),
          ),
        ],
        PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, size: 18, color: AppColors.textSecondary),
          padding: EdgeInsets.zero,
          tooltip: 'Options',
          onSelected: (v) {
            if (v == 'clear_day') _clearDay(context, ref);
            if (v == 'clear_trip') _clearFutureTrip(context, ref);
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'clear_day',
              enabled: !isDayPast,
              child: Row(
                children: [
                  Icon(Icons.delete_sweep_outlined, size: 18, color: isDayPast ? AppColors.textSecondary : AppColors.error),
                  const SizedBox(width: 10),
                  Text('Tout supprimer du jour', style: TextStyle(color: isDayPast ? AppColors.textSecondary : AppColors.textPrimary)),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'clear_trip',
              child: Row(
                children: [
                  Icon(Icons.delete_forever_outlined, size: 18, color: AppColors.error),
                  const SizedBox(width: 10),
                  const Text('Tout supprimer à venir'),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ActivityItem extends ConsumerWidget {
  final TripActivity activity;
  final (Color, Color)? overlapColors;
  const _ActivityItem({required this.activity, this.overlapColors});

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Supprimer cette activité ?'),
        content: Text(activity.title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      developer.log('Suppression activité id=${activity.id}', name: 'planning');
      await ref.read(supabaseProvider).from('trip_activities').delete().eq('id', activity.id);
      developer.log('Supprimé, invalidation du provider', name: 'planning');
      ref.invalidate(tripActivitiesProvider(activity.tripId));
    } catch (e) {
      developer.log('Erreur suppression : $e', name: 'planning');
      messenger.showSnackBar(
        SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error),
      );
    }
  }

  Future<void> _openLogisticItinerary(BuildContext context) async {
    if (!activity.hasCoordinates) return;
    // Mode simple pour les étapes logistiques : on omet `origin=`, Google Maps
    // utilise la géoloc temps réel → guidage in-situ. Pour les vols/gares
    // c'est le cas d'usage standard (l'user veut savoir comment aller à
    // l'aéroport depuis où il se trouve, pas pré-calculer un trajet).
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=${activity.latitude},${activity.longitude}',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d\'ouvrir Google Maps.')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suggested = activity.suggested;
    final isLogistic = activity.isLogistic;
    // Le bandeau "Pour vous ✨" n'a de sens que pour les vraies recommandations
    // de contenu (visites/restos suggérés par l'IA). Sur un retour hôtel
    // auto-inséré (logistic + suggested), c'est trompeur — on retombe sur
    // l'heure simple.
    final timeLabel = (suggested && !isLogistic) ? '${activity.startTime} · Pour vous ✨' : activity.startTime;
    // Couleur d'accent de l'item : sur une activité logistic, on privilégie le
    // bleu institutionnel (rassurant, "j'ai prévu") plutôt que l'orange de
    // suggestion. Logistic l'emporte quand les deux flags sont actifs.
    final useAccentColor = suggested && !isLogistic;

    // Détermine les couleurs de fond/bordure : overlap > logistic > suggested > default
    final Color bg;
    final Color borderColor;
    if (overlapColors != null) {
      bg = overlapColors!.$1;
      borderColor = overlapColors!.$2;
    } else if (isLogistic) {
      // Slate doux + left-strip bleu → distinct visuellement, mais pas
      // effacé. Ne masque jamais l'info pratique (heure/lieu/durée/itinéraire).
      bg = const Color(0xFFF8FAFC); // slate-50
      borderColor = const Color(0xFFCBD5E1); // slate-300
    } else if (suggested) {
      bg = const Color(0xFFFFFBEB);
      borderColor = const Color(0xFFFDE68A);
    } else {
      bg = AppColors.surface;
      borderColor = AppColors.border;
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(children: [
            Container(
              width: 12, height: 12, margin: const EdgeInsets.only(top: 10),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: useAccentColor ? AppColors.accent : AppColors.primary,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: [BoxShadow(color: (useAccentColor ? AppColors.accent : AppColors.primary).withValues(alpha: 0.4), blurRadius: 4)],
              ),
            ),
            Expanded(child: Container(width: 2, color: AppColors.border, margin: const EdgeInsets.only(left: 5))),
          ]),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(timeLabel, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: useAccentColor ? AppColors.accent : (isLogistic ? AppColors.primary : AppColors.textSecondary))),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: () async {
                      if (isVirtualActivity(activity.id)) {
                        final docId = extractDocumentId(activity.id);
                        if (docId == null) return;
                        final docs = await ref.read(tripDocumentsProvider(activity.tripId).future);
                        final doc = docs.where((d) => d.id == docId).firstOrNull;
                        if (doc == null) return;
                        if (context.mounted) {
                          await openDocumentFormSheet(context, ref, existing: doc);
                        }
                      } else {
                        openActivityDetailSheet(context, ref, activity: activity);
                      }
                    },
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: bg,
                      // Border uniforme obligatoire pour pouvoir utiliser borderRadius
                      // (Flutter interdit les BorderSide de couleurs différentes + borderRadius).
                      // Le marqueur "activité virtuelle" / "logistique" est rendu comme un
                      // strip coloré enfant ci-dessous.
                      border: Border.all(color: borderColor),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Strip 4px à gauche : bleu primary pour logistic (signal "transit
                          // important, j'ai prévu"), gris pour les autres activités virtuelles
                          // (signal "vient d'un doc"). Une activité logistic virtuelle prend
                          // le bleu (priorité info-pratique).
                          if (isLogistic)
                            Container(width: 4, color: AppColors.primary)
                          else if (isVirtualActivity(activity.id))
                            Container(width: 4, color: AppColors.textSecondary),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(activity.title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                              if (activity.detail != null && activity.detail!.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(activity.detail!, style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                              ],
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  _Pill(
                                    label: activity.tag,
                                    color: useAccentColor ? AppColors.accent : AppColors.primary,
                                    bg: useAccentColor ? const Color(0xFFFEF3C7) : AppColors.primaryLight,
                                  ),
                                  if (activity.durationMinutes != null && activity.durationMinutes! > 0)
                                    _Pill(label: '⏱ ${formatDuration(activity.durationMinutes)}', color: AppColors.textSecondary, bg: const Color(0xFFF3F4F6)),
                                  if (activity.priceEstimate != null && activity.priceEstimate!.isNotEmpty)
                                    ConvertedPricePill(rawPrice: activity.priceEstimate, color: AppColors.textSecondary, bg: const Color(0xFFF3F4F6)),
                                ],
                              ),
                            ],
                          ),
                        ),
                        // Action de droite : pour les activités logistic AVEC coords, on
                        // rend un raccourci "Itinéraire" prominent — les déplacements
                        // sont anxiogènes pour un voyageur, on garde l'info pratique
                        // toujours à un tap. Sinon, fallback sur les icônes existantes
                        // (link pour virtual, lock pour passé, delete sinon).
                        if (isLogistic && activity.hasCoordinates)
                          IconButton(
                            onPressed: () => _openLogisticItinerary(context),
                            icon: const Icon(Icons.directions, size: 20),
                            color: AppColors.primary,
                            splashRadius: 20,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                            tooltip: 'Itinéraire',
                          )
                        else if (isVirtualActivity(activity.id))
                          Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.link, size: 16, color: AppColors.textSecondary),
                          )
                        else if (isActivityLocked(activity, ref.watch(unlockedPastActivitiesProvider)))
                          Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(Icons.lock_outline, size: 16, color: AppColors.textSecondary),
                          )
                        else
                          IconButton(
                            onPressed: () => _confirmDelete(context, ref),
                            icon: const Icon(Icons.delete_outline, size: 18),
                            color: AppColors.textSecondary,
                            splashRadius: 18,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                            tooltip: 'Supprimer',
                          ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Carte cliquable utilisée dans le dialog de choix du mode de planification
/// (Pilote auto / Co-pilote). Visuellement marquée avec emoji + couleur d'accent.
class _PlanningModeCard extends StatelessWidget {
  final String emoji;
  final String title;
  final String description;
  final Color color;
  final VoidCallback onTap;
  const _PlanningModeCard({
    required this.emoji,
    required this.title,
    required this.description,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color, width: 2),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 32)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: color),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.35),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 14, color: color),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  final Color bg;
  const _Pill({required this.label, required this.color, required this.bg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

class _AddTransportButton extends ConsumerStatefulWidget {
  final String tripId;
  final TripActivity fromActivity;
  final TripActivity toActivity;

  const _AddTransportButton({
    required this.tripId,
    required this.fromActivity,
    required this.toActivity,
  });

  @override
  ConsumerState<_AddTransportButton> createState() => _AddTransportButtonState();
}

class _AddTransportButtonState extends ConsumerState<_AddTransportButton> {
  bool _loading = false;

  Future<void> _generate() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final trip = await ref.read(tripByIdProvider(widget.tripId).future);
      final profile = await ref.read(userProfileProvider.future);
      final service = ref.read(aiSuggestionsServiceProvider);
      final suggestion = await service.generateTransportBetween(
        from: widget.fromActivity,
        to: widget.toActivity,
        destination: trip?.destination ?? '',
        travelerType: trip?.travelerType ?? profile?['traveler_type'] as String?,
      );
      if (!mounted) return;
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.background,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (_) => _PickNewTransportSheet(
          tripId: widget.tripId,
          fromActivity: widget.fromActivity,
          toActivity: widget.toActivity,
          suggestion: suggestion,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error, duration: const Duration(seconds: 4)),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 12,
              child: Column(
                children: [
                  Expanded(child: Container(width: 2, color: AppColors.border, margin: const EdgeInsets.only(left: 5))),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: InkWell(
                onTap: _loading ? null : _generate,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    border: Border.all(color: AppColors.border, style: BorderStyle.solid),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      if (_loading)
                        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        Icon(Icons.add, size: 16, color: AppColors.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _loading ? 'Je cherche les options…' : 'Ajouter un trajet',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.primary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PickNewTransportSheet extends ConsumerStatefulWidget {
  final String tripId;
  final TripActivity fromActivity;
  final TripActivity toActivity;
  final TransportSuggestion suggestion;

  const _PickNewTransportSheet({
    required this.tripId,
    required this.fromActivity,
    required this.toActivity,
    required this.suggestion,
  });

  @override
  ConsumerState<_PickNewTransportSheet> createState() => _PickNewTransportSheetState();
}

class _PickNewTransportSheetState extends ConsumerState<_PickNewTransportSheet> {
  String? _selectedMode;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selectedMode = widget.suggestion.defaultMode;
  }

  Future<void> _save() async {
    if (_selectedMode == null || widget.suggestion.options.isEmpty) return;
    final opt = widget.suggestion.options.firstWhere(
      (o) => o.mode == _selectedMode,
      orElse: () => widget.suggestion.options.first,
    );
    setState(() => _saving = true);
    try {
      await ref.read(supabaseProvider).from('trip_transports').insert({
        'trip_id': widget.tripId,
        'from_activity_id': widget.fromActivity.id,
        'to_activity_id': widget.toActivity.id,
        'selected_mode': opt.mode,
        'selected_duration_minutes': opt.durationMinutes,
        'selected_price_estimate': opt.priceEstimate,
        'options': widget.suggestion.options.map((o) => o.toJson()).toList(),
      });
      ref.invalidate(tripTransportsProvider(widget.tripId));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = widget.suggestion.options;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Ajouter un trajet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                      const SizedBox(height: 2),
                      Text(
                        '${widget.fromActivity.title} → ${widget.toActivity.title}',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                  color: AppColors.textSecondary,
                  tooltip: 'Fermer',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: options.isEmpty
                ? const Center(child: Text('Aucune option disponible.'))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: options.length,
                    itemBuilder: (_, i) {
                      final o = options[i];
                      final selected = _selectedMode == o.mode;
                      return GestureDetector(
                        onTap: () => setState(() => _selectedMode = o.mode),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: selected ? AppColors.primaryLight : AppColors.surface,
                            border: Border.all(color: selected ? AppColors.primary : AppColors.border, width: selected ? 1.5 : 1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Text(transportModeEmoji(o.mode), style: const TextStyle(fontSize: 24)),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(transportModeLabel(o.mode), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                                    const SizedBox(height: 2),
                                    Text('${formatDuration(o.durationMinutes)} · ${o.priceEstimate}', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                                    if (o.detail != null && o.detail!.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(o.detail!, style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontStyle: FontStyle.italic)),
                                    ],
                                  ],
                                ),
                              ),
                              if (selected)
                                Container(
                                  width: 24, height: 24,
                                  decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.primary),
                                  child: const Icon(Icons.check, size: 14, color: Colors.white),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            decoration: BoxDecoration(color: AppColors.surface, border: Border(top: BorderSide(color: AppColors.border))),
            child: SafeArea(
              top: false,
              child: ElevatedButton(
                onPressed: (_saving || options.isEmpty) ? null : _save,
                child: _saving
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Enregistrer le trajet'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TransportLeg extends ConsumerWidget {
  final TripTransport transport;
  final TripActivity fromActivity;
  final TripActivity toActivity;
  const _TransportLeg({required this.transport, required this.fromActivity, required this.toActivity});

  // Parse "HH:MM" → minutes depuis minuit (ou null)
  int? _parseTime(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  bool get _hasConflict {
    final fromStart = _parseTime(fromActivity.startTime);
    final toStart = _parseTime(toActivity.startTime);
    if (fromStart == null || toStart == null) return false;
    final fromDuration = fromActivity.durationMinutes ?? 0;
    final expectedArrival = fromStart + fromDuration + transport.selectedDurationMinutes;
    return toStart < expectedArrival;
  }

  Future<void> _openChangeSheet(BuildContext context, WidgetRef ref) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _TransportOptionsSheet(
        transport: transport,
        fromActivity: fromActivity,
        toActivity: toActivity,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final emoji = transportModeEmoji(transport.selectedMode);
    final label = transportModeLabel(transport.selectedMode);
    final duration = formatDuration(transport.selectedDurationMinutes);
    final price = transport.selectedPriceEstimate;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 12,
              child: Column(
                children: [
                  Expanded(child: Container(width: 2, color: AppColors.border, margin: const EdgeInsets.only(left: 5))),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: InkWell(
                onTap: () => _openChangeSheet(context, ref),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: _hasConflict ? const Color(0xFFFEF2F2) : const Color(0xFFF9FAFB),
                    border: Border.all(color: _hasConflict ? const Color(0xFFFCA5A5) : AppColors.border, style: BorderStyle.solid),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Text(emoji, style: const TextStyle(fontSize: 14)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '$label · ${duration.isEmpty ? '—' : duration} · $price',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_hasConflict) ...[
                        const SizedBox(width: 4),
                        const Tooltip(
                          message: 'Horaire serré : la prochaine activité démarre avant ton arrivée estimée.',
                          child: Text('⚠️', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right, size: 14, color: AppColors.textSecondary),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransportOptionsSheet extends ConsumerStatefulWidget {
  final TripTransport transport;
  final TripActivity fromActivity;
  final TripActivity toActivity;
  const _TransportOptionsSheet({
    required this.transport,
    required this.fromActivity,
    required this.toActivity,
  });

  @override
  ConsumerState<_TransportOptionsSheet> createState() => _TransportOptionsSheetState();
}

class _TransportOptionsSheetState extends ConsumerState<_TransportOptionsSheet> {
  String? _selectedMode;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selectedMode = widget.transport.selectedMode;
  }

  static const _travelModeMap = {
    'walk': 'walking',
    'bike': 'bicycling',
    'car': 'driving',
    'taxi': 'driving',
    'tuktuk': 'driving',
    'metro': 'transit',
    'bus': 'transit',
    'train': 'transit',
    'boat': 'transit',
    'plane': 'transit',
  };

  /// Seuil de bascule entre cas A (planification à distance, coords explicites)
  /// et cas B (utilisation in-situ, géoloc Google Maps). Si je suis à moins de
  /// 50 km de l'activité de départ, je suis "sur place" → guidage temps réel.
  static const _inSituThresholdKm = 50.0;

  Future<void> _openDirections() async {
    final from = widget.fromActivity;
    final to = widget.toActivity;
    final mode = _travelModeMap[_selectedMode ?? 'walk'] ?? 'walking';

    String destParam;
    if (to.hasCoordinates) {
      destParam = '${to.latitude},${to.longitude}';
    } else {
      destParam = Uri.encodeComponent('${to.title} ${to.detail ?? ''}'.trim());
    }

    // Choix de l'origine selon le contexte d'usage :
    // - Cas A (planification à distance, ex: prépa depuis la France pour un
    //   voyage à Lisbonne) : on force l'origine en coords explicites de
    //   l'activité de départ. Sans ça, Google Maps essaie de calculer un
    //   trajet France→Lisbonne en métro et échoue.
    // - Cas B (utilisation in-situ pendant le voyage, à <50 km de l'activité
    //   de départ) : on omet `origin=` pour que Google Maps utilise la géoloc
    //   temps réel et guide pas à pas.
    // Discriminant : distance Haversine entre `ma_position` GPS et l'activité
    // de départ (PAS la distance globale du voyage). Marche pour Bangkok →
    // Chiang Mai car ma_pos ≈ activité départ ≈ 0 km.
    // Edge cases (perm refusée / GPS off / pas de coords sur `from`) : on
    // retombe sur coords explicites par défaut.
    String? originParam;
    if (from.hasCoordinates) {
      try {
        final myPos = await LocationService.instance
            .getCurrentLocation()
            .timeout(const Duration(seconds: 2));
        if (myPos != null) {
          final distKm = haversineKm(
            myPos.latitude, myPos.longitude,
            from.latitude!, from.longitude!,
          );
          if (distKm < _inSituThresholdKm) {
            // Cas B : in-situ → laisse Google Maps utiliser la géoloc
            originParam = null;
          } else {
            // Cas A : à distance → coords explicites
            originParam = '${from.latitude},${from.longitude}';
          }
        } else {
          // Perm refusée / GPS off → coords explicites par défaut
          originParam = '${from.latitude},${from.longitude}';
        }
      } on TimeoutException {
        // Géoloc trop lente → on n'attend pas, coords explicites
        originParam = '${from.latitude},${from.longitude}';
      }
    } else {
      // Pas de coords sur l'activité de départ : fallback texte
      originParam = Uri.encodeComponent('${from.title} ${from.detail ?? ''}'.trim());
    }

    final originPart = originParam != null ? '&origin=$originParam' : '';
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1$originPart&destination=$destParam&travelmode=$mode',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d\'ouvrir Google Maps.')),
      );
    }
  }

  Future<void> _save() async {
    final opt = widget.transport.options.firstWhere(
      (o) => o.mode == _selectedMode,
      orElse: () => widget.transport.options.first,
    );
    setState(() => _saving = true);
    try {
      await ref.read(supabaseProvider).from('trip_transports').update({
        'selected_mode': opt.mode,
        'selected_duration_minutes': opt.durationMinutes,
        'selected_price_estimate': opt.priceEstimate,
      }).eq('id', widget.transport.id);
      ref.invalidate(tripTransportsProvider(widget.transport.tripId));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = widget.transport.options;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.55,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Mode de transport', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                      SizedBox(height: 2),
                      Text('Choisis comment rejoindre la prochaine activité.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                  color: AppColors.textSecondary,
                  tooltip: 'Fermer',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: options.length,
              itemBuilder: (_, i) {
                final o = options[i];
                final selected = _selectedMode == o.mode;
                return GestureDetector(
                  onTap: () => setState(() => _selectedMode = o.mode),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: selected ? AppColors.primaryLight : AppColors.surface,
                      border: Border.all(color: selected ? AppColors.primary : AppColors.border, width: selected ? 1.5 : 1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Text(transportModeEmoji(o.mode), style: const TextStyle(fontSize: 24)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(transportModeLabel(o.mode), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                              const SizedBox(height: 2),
                              Text('${formatDuration(o.durationMinutes)} · ${o.priceEstimate}', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                              if (o.detail != null && o.detail!.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(o.detail!, style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontStyle: FontStyle.italic)),
                              ],
                            ],
                          ),
                        ),
                        if (selected)
                          Container(
                            width: 24, height: 24,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.primary),
                            child: const Icon(Icons.check, size: 14, color: Colors.white),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            decoration: BoxDecoration(color: AppColors.surface, border: Border(top: BorderSide(color: AppColors.border))),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _openDirections,
                      icon: const Icon(Icons.navigation, size: 18),
                      label: const Text('Itinéraire'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        foregroundColor: AppColors.primary,
                        side: BorderSide(color: AppColors.primary),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _saving ? null : _save,
                      style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
                      child: _saving
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Text('Valider'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
