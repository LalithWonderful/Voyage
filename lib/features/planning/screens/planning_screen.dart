import 'dart:async';
import 'dart:developer' as developer;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyage/core/services/location_service.dart';
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
import 'package:voyage/features/planning/services/traveler_to_places_mapping.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';
import 'package:voyage/features/wallet/widgets/document_form_sheet.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';

/// Stop-words FR/EN courants à exclure des comparaisons de titres pour le filtre
/// anti-hallucination. Ces mots n'apportent aucun signal d'identité du lieu.
const _titleStopWords = <String>{
  'le', 'la', 'les', 'un', 'une', 'des', 'du', 'de', 'au', 'aux',
  'a', 'à', 'et', 'en', 'l', 'd', 's', 'the', 'of', 'and', 'in', 'at',
};

/// Tokenize un titre pour la comparaison fuzzy : lowercase, strip punctuation,
/// retire les stop-words et les tokens trop courts (<3 lettres). Conserve les
/// accents (la comparaison se fait token-à-token, exact match).
Set<String> _tokenizeForMatch(String s) {
  return s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-zà-ÿ0-9\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.length >= 3 && !_titleStopWords.contains(t))
      .toSet();
}

/// Vrai si le lieu (via son nom canonique Places) est manifestement
/// inapproprié pour le tag Gemini de la suggestion. Filtre les cas où
/// Gemini propose un lieu réel mais hors-contexte — ex: "Club 87 Nancy"
/// (club libertin) suggéré pour un déjeuner du dimanche midi.
///
/// Heuristique par mots-clés sur le name canonique. Pour une détection
/// vraiment fiable il faudrait parser les `types` Places (`night_club`,
/// `adult_entertainment`, etc.), ce qui demande une migration de la table
/// places_cache. Cette version regex couvre déjà les cas les plus crus.
bool _placesInappropriateForTag(String? canonicalName, String tag) {
  if (canonicalName == null || canonicalName.isEmpty) return false;
  final n = canonicalName.toLowerCase();

  // Lieux pour adultes : rejet inconditionnel — le voyageur ne les demande
  // jamais implicitement, et Gemini les confond souvent avec des restos/bars
  // par hasard de nom.
  if (RegExp(
    r'\b(sex[\s-]?shop|libertin(?:e|s)?|swing(?:ers?|ing)|erotic|nudist|adult\s+only)\b',
  ).hasMatch(n)) {
    return true;
  }

  // Tags repas : pas de night-club/cabaret/disco (Gemini propose souvent un
  // club du soir pour un déjeuner s'il connaît mal la ville).
  if (tag == 'Repas' || tag == 'Gastronomie') {
    if (RegExp(r'\b(night[\s-]?club|nightclub|cabaret|discoth[èe]que|disco)\b').hasMatch(n)) {
      return true;
    }
    // "Club X" en tête de nom (vs "Restaurant Le Club ..."). Évite d'attraper
    // les restos qui ont juste le mot "club" dans leur libellé.
    if (RegExp(r'^club\s').hasMatch(n)) return true;
  }

  return false;
}

/// Vrai si le titre Gemini matche correctement le nom canonique Places.
/// Sinon c'est probablement une hallucination Gemini matchée fuzzy à un
/// lieu sans rapport.
///
/// Règle : ratio (tokens du titre Gemini présents dans le name canonique) /
/// (tokens significatifs du titre Gemini) ≥ 60%. Évite les faux positifs où
/// un seul mot générique ("café", "musée", "place", "comptoir") suffit à
/// matcher un lieu sans rapport.
///
/// Tolérant : si le name canonique n'est pas dispo (cache pré-migration ou
/// Places n'a pas trouvé le lieu), on retourne `true` pour ne pas bloquer
/// (back-compat avec les caches existants).
///
/// Exemples :
/// - "Le Petit Comptoir" (2 tokens) vs "Comptoir des Saveurs" (3 tokens, communs=1)
///   → 1/2 = 50% < 60% → rejet ✓
/// - "Le Petit Comptoir" vs "Petit Comptoir" → 2/2 = 100% → accept ✓
/// - "Galerie Myrtille Beck" (3) vs "Bijouterie Lefranc" (2) → 0/3 = 0% → rejet ✓
/// - "Place Stanislas" (2) vs "Place Stanislas" → 2/2 = 100% → accept ✓
/// - "Musée des Beaux-Arts" (3) vs "Musée d'Histoire Naturelle" (3, communs=1)
///   → 1/3 = 33% → rejet ✓
/// - "Brasserie Excelsior" (2) vs "Brasserie Excelsior Nancy" → 2/2 = 100% → accept ✓
/// - "Restaurant La Toque Blanche" (3) vs "Toque Blanche Bistrot" (3, communs=2)
///   → 2/3 = 66% > 60% → accept (cas légitime : variation de nom) ✓
bool _fuzzyTitleMatches(String geminiTitle, String? canonicalName) {
  if (canonicalName == null || canonicalName.trim().isEmpty) return true;
  final geminiTokens = _tokenizeForMatch(geminiTitle);
  final canonTokens = _tokenizeForMatch(canonicalName);
  if (geminiTokens.isEmpty || canonTokens.isEmpty) return true;

  var commonCount = 0;
  for (final t in geminiTokens) {
    if (canonTokens.contains(t)) {
      commonCount++;
      continue;
    }
    if (t.length >= 4) {
      // Inclusion partielle pour gérer pluriels / variantes : "galeries" ↔ "galerie",
      // "capu" ↔ "capucin". Réservée aux tokens longs.
      for (final c in canonTokens) {
        if (c.length >= 4 && (c.contains(t) || t.contains(c))) {
          commonCount++;
          break;
        }
      }
    }
  }
  return commonCount / geminiTokens.length >= 0.6;
}

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
    // Le menu retourne soit une SuggestionCategory (génération normale), soit la
    // chaîne sentinel 'test' (test Places-first debug, à supprimer après MVP),
    // soit null (annulé). On choisit AVANT de demander le mode pour que le test
    // puisse tourner sur un voyage qui n'a pas encore de planning_mode défini.
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
            // ⚠️ TEMPORAIRE — bouton de validation de la refonte Places-first.
            // À supprimer une fois la refonte intégrée au pipeline normal.
            ListTile(
              leading: const Text('🧪', style: TextStyle(fontSize: 24)),
              title: const Text('Test Places-first (debug)', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Lance les requêtes Places sans Gemini et logue les résultats'),
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
    // Génération normale — on demande le mode si pas encore choisi.
    final mode = await _askPlanningModeIfNeeded(context, ref, trip);
    if (mode == null || !context.mounted) return;
    await _generateSuggestions(context, ref, trip, category: result as SuggestionCategory, mode: mode);
  }

  /// ⚠️ TEMPORAIRE — sera retirée une fois la refonte Places-first branchée.
  /// Test isolé du flow Places (Nearby + Text Search) pour chaque intérêt du
  /// voyageur, à partir du centre géocodé du jour 1. Logue tout dans la
  /// console (`places_test`) et résume dans un snackbar.
  Future<void> _runPlacesNearbyTest(BuildContext context, WidgetRef ref, Trip trip) async {
    final messenger = ScaffoldMessenger.of(context);
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
        // Détail (top 3 par intérêt) seulement pour le 1er jour pour éviter
        // de noyer la console — la pool est la même par jour en mono-ville.
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
      debugPrint(
        '[places_test] === FIN GATHER : ${pool.length} jours × intérêts → $totalAfterFilters '
        'candidats cumulés (avec doublons inter-intérêts) ===',
      );

      // ─── ÉTAPE 4a.2 — preview prompts CoPilot (pas d'appel Gemini) ─────
      final groups = groupDaysByCenter(pool);
      debugPrint(
        '[places_test] === PROMPTS COPILOT (preview, pas d\'appel Gemini) ===',
      );
      debugPrint(
        '[places_test] ${groups.length} groupe(s) de jours par centre — donc autant de prompts Gemini à envoyer',
      );
      for (var g = 0; g < groups.length; g++) {
        final group = groups[g];
        final dayList = group.days.map((d) => d.toIso8601String().split('T').first).join(', ');
        final prompt = buildCoPilotPrompt(
          input: group,
          trip: trip,
          travelerProfile: travelerProfile,
        );
        final approxTokens = (prompt.length / 4).round();
        debugPrint(
          '[places_test] Groupe ${g + 1}/${groups.length} : centre ${group.center.source} '
          '(${group.center.latitude.toStringAsFixed(3)},${group.center.longitude.toStringAsFixed(3)}) | '
          'jours=$dayList | pool=${group.poolSize} lieux | prompt=${prompt.length} chars (~$approxTokens tokens)',
        );
        // On loggue les 50 premières lignes du prompt + 10 dernières — assez
        // pour voir l'entête et le format JSON attendu sans noyer la console.
        final lines = prompt.split('\n');
        if (lines.length <= 60) {
          for (final l in lines) {
            debugPrint('[prompt] $l');
          }
        } else {
          for (var i = 0; i < 50; i++) {
            debugPrint('[prompt] ${lines[i]}');
          }
          debugPrint('[prompt] … (${lines.length - 60} lignes omises) …');
          for (var i = lines.length - 10; i < lines.length; i++) {
            debugPrint('[prompt] ${lines[i]}');
          }
        }
      }
      final totalUnique = pool.fold<int>(0, (sum, d) => sum + d.uniqueCandidates);
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text(
            '✓ ${pool.length} jours · $totalUnique lieux uniques · $totalAfterFilters cumulés (voir console)',
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
      final interests = await ref.read(userInterestsProvider.future);
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

      // Préférences : trip-level si définies, sinon fallback profil utilisateur
      final effectiveTravelerType = trip.travelerType ?? profile?['traveler_type'] as String?;
      final effectiveInterests = (trip.interests != null && trip.interests!.isNotEmpty) ? trip.interests! : interests;

      // Hôtel d'ancrage GPS : celui qui couvre aujourd'hui (ou le premier si aucun ne colle)
      final anchorHotel = hotelForDay(hotels, DateTime.now());

      // Position GPS + distance vers la destination — pertinent UNIQUEMENT si le voyage
      // est en cours (today ∈ [start_date, end_date]). Sur un voyage dans 10 jours, la
      // position du voyageur (chez lui) n'a pas de sens, on skip la demande de permission.
      final nowTs = DateTime.now();
      final todayDate = DateTime(nowTs.year, nowTs.month, nowTs.day);
      final tripStart = DateTime(trip.startDate.year, trip.startDate.month, trip.startDate.day);
      final tripEnd = DateTime(trip.endDate.year, trip.endDate.month, trip.endDate.day);
      final isTripInProgress = !tripStart.isAfter(todayDate) && !tripEnd.isBefore(todayDate);

      UserLocation? userLocation;
      int? userToDestinationMin;
      if (isTripInProgress) {
        userLocation = await LocationService.instance.getCurrentLocation();
        if (userLocation != null) {
          final anchorQuery = anchorHotel?.metadata['address'] as String? ?? trip.destination;
          final geo = await ref.read(geocodingServiceProvider).geocode(anchorQuery);
          if (geo != null) {
            final km = haversineKm(userLocation.latitude, userLocation.longitude, geo.latitude, geo.longitude);
            userToDestinationMin = estimatedTravelMinutes(km);
          }
        }
      }

      // Convertit les hôtels du trip en HotelStay pour le prompt Gemini
      DateTime? parseMeta(dynamic v) => v is String ? DateTime.tryParse(v) : null;
      final hotelStays = hotels
          .map((h) => HotelStay(
                name: h.name,
                address: h.metadata['address'] as String?,
                checkIn: parseMeta(h.metadata['check_in']),
                checkOut: parseMeta(h.metadata['check_out']),
              ))
          .toList();

      debugPrint('[SUGGEST] Appel Gemini (trip=${trip.destination}, existing=${existing.length}, category=${category.name}, mode=${mode.name})');
      final service = ref.read(aiSuggestionsServiceProvider);
      final result = await service.suggestActivities(
        trip: trip,
        travelerType: effectiveTravelerType,
        interests: effectiveInterests,
        existingActivities: existing,
        hotels: hotelStays,
        userLat: userLocation?.latitude,
        userLng: userLocation?.longitude,
        userToDestinationTravelMin: userToDestinationMin,
        category: category,
        mode: mode,
      );
      debugPrint(
        '[SUGGEST] Réponse Gemini reçue (mode=${mode.name}, '
        'activités=${result.activities.length}, groupes=${result.groups.length}, '
        'trajets=${result.transports.length})',
      );

      // Normalisation pour le dedup : lowercase + strip emojis/ponctuation.
      // Permet de matcher "🏨 Départ · Maison rue du pigeonnier" vs
      // "Départ Maison rue pigeonnier" (même activité, 2 formulations).
      String norm(String s) => s
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-zà-ÿ0-9\s]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final existingTitles = existing.map((a) => norm(a.title)).toSet();
      // Filtre large pour toutes les activités "gestion hébergement" (retour à l'hôtel,
      // arrivée/départ = check-in/check-out). L'app les génère automatiquement depuis
      // les documents — Gemini ne doit pas les re-proposer, peu importe la formulation
      // (avec ou sans emoji 🏨, avec ou sans préfixe "·"). Regex sur mots entiers.
      final hotelActionsRe = RegExp(
        r'\b(retour|départ|depart|arrivée|arrivee|check[\s-]?in|check[\s-]?out)\b',
        caseSensitive: false,
      );
      bool isHotelReturn(String title) => hotelActionsRe.hasMatch(title);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final earliestMinToday = now.hour * 60 + now.minute + 30; // current + buffer

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

      // Groupe les activités existantes par jour pour le check de chevauchement
      final existingByDay = <String, List<TripActivity>>{};
      for (final a in existing) {
        final key = a.dayDate.toIso8601String().split('T').first;
        existingByDay.putIfAbsent(key, () => []).add(a);
      }

      /// Vrai si la suggestion chevauche une activité existante le même jour.
      /// Deux activités chevauchent si [s.start, s.end[ ∩ [e.start, e.end[ ≠ ∅.
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

      // Filtre "heure tardive déraisonnable" supprimé : le seuil dépend trop de la
      // destination (Metz ferme à 22h, Bangkok/Madrid/NYC tournent jusqu'au petit matin).
      // On laisse le prompt Gemini gérer via ses guidelines "adapte à la destination".
      // Si Gemini hallucine quand même, l'utilisateur peut simplement ne pas cocher
      // la suggestion dans la sheet de sélection.

      // Dedup INTRA-réponse Gemini : si Gemini renvoie 2 fois "Petit déjeuner Maison Lou",
      // on ne garde que la 1ère. Cette dedup vient avant celle contre l'existant.
      final seenInternal = <String>{};
      final uniqueInternal = <ActivitySuggestion>[];
      for (final s in result.activities) {
        final key = norm(s.title);
        if (seenInternal.add(key)) uniqueInternal.add(s);
      }

      // Validation catégorie stricte : Gemini glisse parfois un bar dans "Visites" ou
      // une visite dans "Restos" malgré l'override. On vérifie le tag retourné et on
      // rejette si incohérent avec la demande.
      const mealTags = {'repas', 'gastronomie', 'restaurant', 'resto'};
      bool isMealActivity(ActivitySuggestion s) {
        final t = s.tag.toLowerCase().trim();
        if (mealTags.contains(t)) return true;
        // Fallback par titre si Gemini a mis un tag bidon
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

      // ─── Branche mode coPilot ──────────────────────────────────────────
      // Gemini renvoie ici des `groups` (3 options/créneau) au lieu d'une
      // liste plate. On filtre option par option (mêmes garde-fous que le
      // mode auto), on valide chaque option contre Places, on drop les
      // groupes qui n'ont plus aucune option valide.
      if (mode == PlanningMode.coPilot) {
        final placesService = ref.read(placesCacheServiceProvider);
        final processedGroups = <SuggestionGroup>[];
        // Compteur d'apparitions par titre normalisé. Au-delà de 2 → on considère
        // que le lieu a déjà eu sa chance et on évite de spammer le voyageur.
        // Avant : on bloquait dès la 2e apparition, ce qui pénalise les villes
        // où Gemini ne connaît qu'une poignée de vrais lieux (vu à Nancy : ~5-7
        // lieux légitimes répétés sur 28 groupes — bloqués pour rien).
        const maxOccurrences = 2;
        final seenAcrossGroupsCount = <String, int>{};

        // Compteurs cumulés pour diagnostic — explique pourquoi un groupe finit
        // avec moins de 3 options (Gemini en sort moins, ou nos filtres en jettent).
        var totalRawOptions = 0;
        var rejectedByExisting = 0;
        var rejectedBySeenAcross = 0;
        var rejectedByHotelReturn = 0;
        var rejectedByPast = 0;
        var rejectedByOverlap = 0;
        var rejectedByCategory = 0;
        var rejectedByPlaces = 0;

        for (final group in result.groups) {
          totalRawOptions += group.options.length;
          // Mode coPilot — filtres volontairement permissifs : on laisse passer les
          // chevauchements horaires et le passé, parce que le voyageur veut pouvoir
          // importer une option même si elle conflicte avec une activité existante,
          // pour la déplacer ensuite dans le planning vers un autre jour/créneau libre.
          // En revanche on garde le dedup contre les activités déjà au planning et le
          // dedup inter-groupe (sinon le même titre apparaît 3× dans 3 groupes = bruit).
          final candidates = group.options.where((s) {
            if (existingTitles.contains(norm(s.title))) {
              rejectedByExisting++;
              debugPrint('[SUGGEST coPilot] ✗ existing: "${s.title}"');
              return false;
            }
            final occurrences = seenAcrossGroupsCount[norm(s.title)] ?? 0;
            if (occurrences >= maxOccurrences) {
              rejectedBySeenAcross++;
              debugPrint('[SUGGEST coPilot] ✗ seen-other-group ($occurrences déjà): "${s.title}"');
              return false;
            }
            if (isHotelReturn(s.title)) {
              rejectedByHotelReturn++;
              return false;
            }
            if (!matchesCategory(s)) {
              rejectedByCategory++;
              return false;
            }
            return true;
          }).toList();
          if (candidates.isEmpty) {
            debugPrint(
              '[SUGGEST coPilot] groupe "${group.slotLabel}" '
              '(${group.dayDate.toIso8601String().split('T').first}) DROP — toutes les options filtrées avant Places',
            );
            continue;
          }

          final validated = await Future.wait(candidates.map((s) async {
            if (s.tag == 'Hébergement') return s;
            try {
              final dayCity = trip.cityForDay(s.dayDate);
              final dayCityLower = dayCity.split(',').first.trim().toLowerCase();
              final info = await placesService.findInfo(title: s.title, destination: dayCity);
              final hasPlace = info.placeId != null && info.placeId!.isNotEmpty;
              final hasAddress = info.address != null && info.address!.trim().isNotEmpty;
              if (!hasPlace || !hasAddress) {
                debugPrint('[SUGGEST coPilot] ✗ Places no-place-or-address: "${s.title}"');
                return null;
              }
              if (!info.address!.toLowerCase().contains(dayCityLower)) {
                debugPrint('[SUGGEST coPilot] ✗ Places wrong-city: "${s.title}" → ${info.address}');
                return null;
              }
              // Anti-hallucination : si Places matche fuzzy à un lieu dont le nom
              // canonique n'a aucun mot en commun avec le titre Gemini, on rejette
              // (probablement un nom inventé par Gemini qui pointe sur un autre lieu).
              if (!_fuzzyTitleMatches(s.title, info.name)) {
                debugPrint('[SUGGEST coPilot] ✗ Places name-mismatch: "${s.title}" → name="${info.name}"');
                return null;
              }
              // Hors-contexte : le lieu existe mais n'a rien à faire dans cette
              // catégorie (ex: "Club 87 Nancy" club libertin suggéré pour repas).
              if (_placesInappropriateForTag(info.name, s.tag)) {
                debugPrint('[SUGGEST coPilot] ✗ Places inappropriate-for-tag (${s.tag}): "${s.title}" → name="${info.name}"');
                return null;
              }
              return s;
            } catch (_) {
              // Tolère un flake réseau Places pour ne pas pénaliser l'utilisateur
              return s;
            }
          }));
          final validOptions = validated.whereType<ActivitySuggestion>().toList();
          rejectedByPlaces += candidates.length - validOptions.length;
          if (validOptions.isEmpty) {
            debugPrint(
              '[SUGGEST coPilot] groupe "${group.slotLabel}" '
              '(${group.dayDate.toIso8601String().split('T').first}) DROP — toutes les options rejetées par Places',
            );
            continue;
          }
          if (validOptions.length < group.options.length) {
            debugPrint(
              '[SUGGEST coPilot] groupe "${group.slotLabel}" rabote ${group.options.length} → ${validOptions.length} options',
            );
          }
          for (final s in validOptions) {
            final k = norm(s.title);
            seenAcrossGroupsCount[k] = (seenAcrossGroupsCount[k] ?? 0) + 1;
          }
          processedGroups.add(group.copyWith(options: validOptions));
        }

        final keptOptions = processedGroups.fold<int>(0, (sum, g) => sum + g.options.length);
        debugPrint(
          '[SUGGEST coPilot] BILAN — Gemini: ${result.groups.length} groupes, $totalRawOptions options brutes ; '
          'rejetés: existing=$rejectedByExisting, seen-other=$rejectedBySeenAcross, hotel-return=$rejectedByHotelReturn, '
          'past=$rejectedByPast, overlap=$rejectedByOverlap, category=$rejectedByCategory, places=$rejectedByPlaces ; '
          'gardés: ${processedGroups.length} groupes, $keptOptions options',
        );

        closeDialog();
        if (!context.mounted) return;
        if (processedGroups.isEmpty) {
          messenger.showSnackBar(
            const SnackBar(content: Text('Aucune nouvelle suggestion — ton planning est déjà bien rempli.')),
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
            groups: processedGroups,
            travelerType: effectiveTravelerType,
            mode: PlanningMode.coPilot,
          ),
        );
        ref.invalidate(tripActivitiesProvider(tripId));
        ref.invalidate(tripTransportsProvider(tripId));
        return;
      }
      // ─── Fin branche coPilot ───────────────────────────────────────────

      final afterCategory = uniqueInternal.where(matchesCategory).toList();

      final rawCount = result.activities.length;
      final afterDup = afterCategory.where((s) => !existingTitles.contains(norm(s.title))).toList();
      final afterReturn = afterDup.where((s) => !isHotelReturn(s.title)).toList();
      final afterPast = afterReturn.where((s) => !isInPast(s)).toList();
      final afterOverlap = afterPast.where((s) => !hasTimeOverlap(s)).toList();

      // ── Validation Places API post-Gemini ──
      // Triple check :
      // 1. Le lieu existe vraiment sur Google Places (placeId non null)
      // 2. Il a une adresse formatée non vide (sinon "Voir sur Maps" plante)
      // 3. L'adresse contient le nom de la destination (sinon Gemini propose des trucs
      //    dans des villes voisines — vu en avril 2026 : Metz/Epinal proposés pour Nancy)
      // Les Hébergements ne sont pas validés (gérés par les docs perso du voyageur).
      // Appels faits en parallèle (Future.wait) pour limiter la latence.
      // Résultats cachés en DB par (titre, destination) → 0 coût sur les répétitions.
      final placesService = ref.read(placesCacheServiceProvider);
      final validationResults = await Future.wait(
        afterOverlap.map((s) async {
          if (s.tag == 'Hébergement') return (suggestion: s, valid: true, reason: 'hébergement-skip');
          try {
            // Pour un voyage multi-étapes, la ville à valider varie par jour.
            // Pour un voyage mono-ville, cityForDay retourne toujours `trip.destination`.
            final dayCity = trip.cityForDay(s.dayDate);
            final dayCityLower = dayCity.split(',').first.trim().toLowerCase();
            final info = await placesService.findInfo(
              title: s.title,
              destination: dayCity,
            );
            final hasPlace = info.placeId != null && info.placeId!.isNotEmpty;
            final hasAddress = info.address != null && info.address!.trim().isNotEmpty;
            if (!hasPlace || !hasAddress) {
              return (suggestion: s, valid: false, reason: 'no-place-or-address');
            }
            // City-match : l'adresse doit contenir la ville cible du jour.
            // Tolère "Nancy" vs "Nancy, France" ou "centre-ville Nancy".
            final inCity = info.address!.toLowerCase().contains(dayCityLower);
            if (!inCity) {
              return (suggestion: s, valid: false, reason: 'wrong-city ($dayCity attendu): ${info.address}');
            }
            // Anti-hallucination : token significatif du titre Gemini doit matcher
            // le nom canonique Places. Sinon Gemini a halluciné un nom et Places
            // l'a fuzzy-matché à un lieu sans rapport (ex: "Galerie Myrtille Beck"
            // → matché à une bijouterie).
            if (!_fuzzyTitleMatches(s.title, info.name)) {
              return (suggestion: s, valid: false, reason: 'name-mismatch (canonique: "${info.name}")');
            }
            // Hors-contexte : le lieu existe mais n'a rien à faire dans cette
            // catégorie (ex: club libertin suggéré pour un repas).
            if (_placesInappropriateForTag(info.name, s.tag)) {
              return (suggestion: s, valid: false, reason: 'inappropriate-for-tag ${s.tag} (canonique: "${info.name}")');
            }
            return (suggestion: s, valid: true, reason: 'ok');
          } catch (_) {
            // Erreur réseau = on garde (ne pas pénaliser l'utilisateur pour une API qui flake)
            return (suggestion: s, valid: true, reason: 'error-keep');
          }
        }),
      );
      final suggestions = validationResults.where((r) => r.valid).map((r) => r.suggestion).toList();
      // Log les rejets ville pour debug
      final wrongCity = validationResults.where((r) => r.reason.startsWith('wrong-city')).toList();
      if (wrongCity.isNotEmpty) {
        debugPrint('[SUGGEST] ${wrongCity.length} suggestions rejetées (mauvaise ville) :');
        for (final r in wrongCity) {
          debugPrint('  - "${r.suggestion.title}" → ${r.reason}');
        }
      }

      debugPrint(
        '[SUGGEST] brut=$rawCount, dedup-interne=${uniqueInternal.length}, '
        'après catégorie=${afterCategory.length}, après dedup-existant=${afterDup.length}, '
        'après retour=${afterReturn.length}, après passé=${afterPast.length}, '
        'après overlap=${afterOverlap.length}, après Places=${suggestions.length} '
        '(${afterOverlap.length - suggestions.length} hallucinations rejetées)',
      );

      closeDialog();
      if (!context.mounted) return;
      if (suggestions.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Aucune nouvelle suggestion — ton planning est déjà bien rempli.')),
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
          suggestions: suggestions,
          transportSuggestions: result.transports,
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
            Text('L\'IA prépare ton planning...', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
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
            Text('Laisse l\'IA construire un planning ou crée tes activités à la main.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.5)),
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
  final List<TransportSuggestion> transportSuggestions;
  final String? travelerType;
  /// Mode de planification utilisé pour la génération. Détermine le rendu UI :
  /// - auto : liste plate, tout coché par défaut, le voyageur décoche.
  /// - coPilot : sections par créneau avec 3 options, tout décoché par défaut, le voyageur coche.
  final PlanningMode mode;
  const _SuggestionsSheet({
    required this.tripId,
    this.suggestions = const [],
    this.groups = const [],
    this.transportSuggestions = const [],
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
      // Si l'hôtel a des dates, on vérifie que ce jour est bien dans sa période.
      // Sans dates, on accepte tous les jours du voyage (legacy).
      if (ci != null && co != null) {
        final inRange = !day.isBefore(DateTime(ci.year, ci.month, ci.day)) &&
            !day.isAfter(DateTime(co.year, co.month, co.day));
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

      // Stocke l'adresse de l'hôtel dans `detail` pour que "Voir sur Maps" puisse
      // l'utiliser directement (évite la recherche fuzzy sur le titre qui fait planter
      // l'app Maps sur un nom d'hébergement privé).
      final hotelAddress = dayHotel.metadata['address'] as String?;
      rows.add({
        'trip_id': widget.tripId,
        'day_date': day.toIso8601String().split('T').first,
        'start_time': returnTime,
        'title': 'Retour à ${dayHotel.name}',
        if (hotelAddress != null && hotelAddress.isNotEmpty) 'detail': hotelAddress,
        'tag': 'Hébergement',
        'duration_minutes': 15,
        'price_estimate': 'Gratuit',
        'suggested': true,
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

  /// Remplace le titre + l'adresse Gemini de chaque suggestion par les valeurs
  /// canoniques Google Places quand on les a en cache (déjà validées par le
  /// pipeline via le filtre fuzzy match nom canonique).
  ///
  /// Pourquoi : Gemini hallucine régulièrement le nom exact ou l'adresse d'un
  /// lieu. Si le pipeline a accepté la suggestion (= ratio fuzzy ≥60% avec le
  /// name Places), le LIEU est correct, mais le titre/adresse stockés en DB
  /// sont ceux que Gemini a inventés. Conséquences : "Voir sur Maps" pointe
  /// vers un mauvais lieu, Routes API utilise un placeId qui ne correspond
  /// pas au titre. En substituant titre + adresse par le canonique Places,
  /// l'activité devient cohérente bout-en-bout (affichage = navigation = trajet).
  ///
  /// Hébergement exclu : la fiche du voyageur (= sa résa) est la source de
  /// vérité, pas Places. Skip aussi quand Places n'a pas de match (info.name null).
  Future<List<ActivitySuggestion>> _enrichWithCanonicalPlaces(
    List<ActivitySuggestion> suggestions,
  ) async {
    final trip = ref.read(tripByIdProvider(widget.tripId)).valueOrNull;
    if (trip == null) return suggestions;
    final placesService = ref.read(placesCacheServiceProvider);

    final enriched = await Future.wait(suggestions.map((s) async {
      if (s.tag == 'Hébergement') return s;
      try {
        final dayCity = trip.cityForDay(s.dayDate);
        final info = await placesService.findInfo(title: s.title, destination: dayCity);
        final canonicalName = info.name?.trim();
        final canonicalAddress = info.address?.trim();
        if (canonicalName != null && canonicalName.isNotEmpty &&
            canonicalAddress != null && canonicalAddress.isNotEmpty) {
          if (canonicalName != s.title || canonicalAddress != s.detail) {
            developer.log(
              'Canonisation : "${s.title}" → "$canonicalName" / detail="$canonicalAddress"',
              name: 'planning',
            );
          }
          return ActivitySuggestion(
            dayDate: s.dayDate,
            startTime: s.startTime,
            title: canonicalName,
            detail: canonicalAddress,
            tag: s.tag,
            durationMinutes: s.durationMinutes,
            priceEstimate: s.priceEstimate,
            matchReason: s.matchReason,
          );
        }
      } catch (_) {}
      return s;
    }));
    return enriched;
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

  Future<void> _save() async {
    final rawSelections = _collectSelectedSuggestions();
    if (rawSelections.isEmpty) return;
    developer.log(
      '_save START — mode=${widget.mode.name}, selected=${rawSelections.length}',
      name: 'planning',
    );
    setState(() => _saving = true);
    try {
      // Avant l'insert, substituer titre + adresse Gemini par les valeurs
      // canoniques Places. Garantit que titre, adresse, placeId et trajets
      // Routes API pointent tous vers le même lieu réel (cohérence bout-en-bout).
      final selectedSuggestions = await _enrichWithCanonicalPlaces(rawSelections);
      final client = ref.read(supabaseProvider);
      final rows = selectedSuggestions.map((s) => s.toInsertJson(widget.tripId)).toList();
      developer.log('Insertion de ${rows.length} activité(s) dans trip_activities', name: 'planning');
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

      // Récupère les transports déjà en base pour éviter les doublons
      final existingTransportsData = await client
          .from('trip_transports')
          .select('from_activity_id, to_activity_id')
          .eq('trip_id', widget.tripId);
      final existingPairs = (existingTransportsData as List)
          .map((e) => '${e['from_activity_id']}|${e['to_activity_id']}')
          .toSet();

      // ─── Construction des transports pour chaque paire consécutive même jour ──
      // Stratégie hybride :
      // 1. Routes API (Google Maps) si on a les place_id des 2 activités → durées RÉELLES.
      // 2. Fallback Gemini (mode auto seulement) si Routes a échoué et que Gemini a fourni
      //    un bloc transport pour cette paire (durées hallucinées mais mieux que rien).
      // 3. Skip si ni Routes ni Gemini → pas de transport pour cette pair.
      String norm(String s) => s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
      final transportByKey = <String, TransportSuggestion>{};
      for (final t in widget.transportSuggestions) {
        transportByKey['${norm(t.fromTitle)}|${norm(t.toTitle)}'] = t;
      }

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
      // gros plannings. Chaque slot fait Places lookup (cache) + Routes API call (cache).
      final transportResults = await Future.wait(pairs.map((pair) async {
        final (a, b) = pair;
        final infoA = await placesService.findInfo(title: a.title, destination: destination);
        final infoB = await placesService.findInfo(title: b.title, destination: destination);

        List<TransportOption>? routesOptions;
        if (infoA.placeId != null &&
            infoA.placeId!.isNotEmpty &&
            infoB.placeId != null &&
            infoB.placeId!.isNotEmpty) {
          routesOptions = await routesService.computeOptions(
            fromPlaceId: infoA.placeId!,
            toPlaceId: infoB.placeId!,
          );
          developer.log(
            'Routes "${a.title}" → "${b.title}" : '
            '${routesOptions == null ? "ÉCHEC (null)" : "${routesOptions.length} options [${routesOptions.map((o) => o.mode).join(", ")}]"}',
            name: 'planning',
          );
        } else {
          developer.log(
            'Routes "${a.title}" → "${b.title}" : SKIP (placeId manquant — A=${infoA.placeId == null ? "null" : "ok"}, B=${infoB.placeId == null ? "null" : "ok"})',
            name: 'planning',
          );
        }

        final geminiSuggest = transportByKey['${norm(a.title)}|${norm(b.title)}'];

        List<TransportOption> finalOptions;
        String? defaultMode;
        if (routesOptions != null && routesOptions.isNotEmpty) {
          finalOptions = routesOptions;
          defaultMode = _pickDefaultMode(finalOptions, widget.travelerType);
        } else if (geminiSuggest != null && geminiSuggest.options.isNotEmpty) {
          finalOptions = geminiSuggest.options;
          defaultMode = geminiSuggest.defaultMode;
        } else {
          return null;
        }

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
                  return Column(
                    key: ValueKey(a.id),
                    children: [
                      _ActivityItem(activity: a, overlapColors: overlapColorByActivityId[a.id]),
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

    final reordered = [...dayActs];
    final item = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, item);

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

    // Applique les updates en DB
    for (final entry in updates.entries) {
      try {
        await client.from('trip_activities').update({'start_time': entry.value}).eq('id', entry.key);
      } catch (e) {
        developer.log('Erreur update time ${entry.key}: $e', name: 'planning');
      }
    }

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suggested = activity.suggested;
    final timeLabel = suggested ? '${activity.startTime} · Pour vous ✨' : activity.startTime;

    // Détermine les couleurs de fond/bordure : overlap > suggested > default
    final Color bg;
    final Color borderColor;
    if (overlapColors != null) {
      bg = overlapColors!.$1;
      borderColor = overlapColors!.$2;
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
                color: suggested ? AppColors.accent : AppColors.primary,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: [BoxShadow(color: (suggested ? AppColors.accent : AppColors.primary).withValues(alpha: 0.4), blurRadius: 4)],
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
                  Text(timeLabel, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: suggested ? AppColors.accent : AppColors.textSecondary)),
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
                      // Le marqueur "activité virtuelle" est rendu comme un strip coloré enfant ci-dessous.
                      border: Border.all(color: borderColor),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (isVirtualActivity(activity.id))
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
                                    color: suggested ? AppColors.accent : AppColors.primary,
                                    bg: suggested ? const Color(0xFFFEF3C7) : AppColors.primaryLight,
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
                        if (isVirtualActivity(activity.id))
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
                          _loading ? 'L\'IA cherche les options…' : 'Ajouter un trajet',
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

  Future<void> _openDirections() async {
    final from = widget.fromActivity;
    final to = widget.toActivity;
    final mode = _travelModeMap[_selectedMode ?? 'walk'] ?? 'walking';

    String originParam;
    String destParam;
    if (from.hasCoordinates) {
      originParam = '${from.latitude},${from.longitude}';
    } else {
      originParam = Uri.encodeComponent('${from.title} ${from.detail ?? ''}'.trim());
    }
    if (to.hasCoordinates) {
      destParam = '${to.latitude},${to.longitude}';
    } else {
      destParam = Uri.encodeComponent('${to.title} ${to.detail ?? ''}'.trim());
    }

    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&origin=$originParam&destination=$destParam&travelmode=$mode',
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
