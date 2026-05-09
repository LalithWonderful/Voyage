import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/providers/currency_provider.dart';
import 'package:voyage/core/providers/offline_provider.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/models/trip_transport_model.dart';
import 'package:voyage/features/planning/services/activity_staleness_service.dart';
import 'package:voyage/features/planning/services/ai_suggestions_service.dart';
import 'package:voyage/features/planning/services/budget_service.dart';
import 'package:voyage/features/planning/services/document_to_activity.dart';
import 'package:voyage/features/planning/services/gemini_cache_service.dart';
import 'package:voyage/features/planning/services/geocoding_service.dart';
import 'package:voyage/features/planning/services/place_lookup_cache_service.dart';
import 'package:voyage/features/planning/services/places_cache_service.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';
import 'package:voyage/features/planning/services/places_service.dart';
import 'package:voyage/features/planning/services/routes_service.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';
import 'package:voyage/features/trips/services/trip_segment_sync_service.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';

/// Vrai si l'activité est sur un jour strictement antérieur à aujourd'hui.
/// Les activités d'aujourd'hui ne sont PAS considérées comme passées (le jour est
/// encore "en cours", on peut vouloir les éditer/annoter).
bool isActivityPast(TripActivity activity) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(activity.dayDate.year, activity.dayDate.month, activity.dayDate.day);
  return day.isBefore(today);
}

/// Vrai si l'heure de début de l'activité est déjà dépassée :
/// - jour strictement passé → true
/// - jour d'aujourd'hui + startTime < maintenant → true
/// - aujourd'hui + startTime dans le futur → false
/// - jour futur → false
///
/// Utilisé pour masquer les actions "forward-looking" type "Voir des alternatives"
/// qui n'ont pas de sens sur une activité déjà commencée (même si l'édition reste
/// possible pour corriger/annoter).
bool isActivityElapsed(TripActivity activity) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(activity.dayDate.year, activity.dayDate.month, activity.dayDate.day);
  if (day.isBefore(today)) return true;
  if (day.isAfter(today)) return false;
  // Aujourd'hui : compare l'heure
  final parts = activity.startTime.split(':');
  if (parts.length != 2) return false;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return false;
  final activityMin = h * 60 + m;
  final nowMin = now.hour * 60 + now.minute;
  return activityMin < nowMin;
}

/// IDs d'activités passées explicitement déverrouillées pour la session courante.
/// Non persisté : se réinitialise à chaque lancement de l'app, la protection des
/// souvenirs passés est active par défaut. L'utilisateur doit reconfirmer pour éditer.
final unlockedPastActivitiesProvider = StateProvider<Set<String>>((ref) => <String>{});

/// Vrai si l'activité doit être considérée comme verrouillée : passée ET pas dans
/// le set des activités déverrouillées pour cette session.
bool isActivityLocked(TripActivity activity, Set<String> unlocked) {
  return isActivityPast(activity) && !unlocked.contains(activity.id);
}

/// Activités d'un voyage avec fallback cache local (offline-first lecture).
/// Cf. `LocalTripsCacheService`. Si offline ET cache vide pour ce voyage
/// (l'user n'a pas consulté ce voyage avant la coupure réseau), on retourne
/// une liste vide silencieuse — l'écran affichera "Aucune activité" + le
/// bandeau offline. Plus user-friendly qu'une erreur tech en plein écran.
/// V6 (Lalith 2026-05-10 — Lot E TODO 3) — `tripActivitiesProvider`
/// retourne uniquement les activités au statut `planned` (= utilisable
/// par le planning principal). Les `stale` sont remontées séparément
/// via `staleActivitiesProvider`.
///
/// V6.1 (bug fix 2026-05-10) — fetch direct (pas de chaînage via un
/// provider interne) : `ref.invalidate(tripActivitiesProvider)` doit
/// déclencher un re-fetch Supabase, sinon les nouvelles activités
/// restent invisibles après un Save (cas observé : « Suggérer
/// planning » → 142 activités → planning blanc).
final tripActivitiesProvider = FutureProvider.family<List<TripActivity>, String>((ref, tripId) async {
  final client = ref.watch(supabaseProvider);
  final cache = await ref.watch(localTripsCacheServiceProvider.future);
  try {
    final data = await client
        .from('trip_activities')
        .select()
        .eq('trip_id', tripId)
        .order('day_date', ascending: true)
        .order('sort_order', ascending: true)
        .order('start_time', ascending: true);
    final rows = (data as List).whereType<Map<String, dynamic>>().toList();
    cache.writeActivities(tripId, rows);
    ref.read(isOfflineProvider.notifier).state = false;
    final all = rows.map((e) => TripActivity.fromJson(e)).toList();
    return all.where((a) => !a.isStale).toList();
  } catch (e) {
    ref.read(isOfflineProvider.notifier).state = true;
    final cached = cache.readActivities(tripId);
    return cached.where((a) => !a.isStale).toList();
  }
});

/// V6 (Lalith 2026-05-10 — Lot E TODO 3) — activités générées par
/// Lunao puis marquées `stale` après une mutation structurelle de
/// l'itinéraire. Affichées dans la section dédiée du planning, l'user
/// peut les restaurer individuellement ou les supprimer.
///
/// Fetch direct sur Supabase avec filtre `planning_status='stale'`
/// (utilise l'index composite `(trip_id, planning_status)`).
final staleActivitiesProvider = FutureProvider.family<List<TripActivity>, String>((ref, tripId) async {
  final client = ref.watch(supabaseProvider);
  try {
    final data = await client
        .from('trip_activities')
        .select()
        .eq('trip_id', tripId)
        .eq('planning_status', 'stale')
        .order('day_date', ascending: true);
    final rows = (data as List).whereType<Map<String, dynamic>>().toList();
    return rows.map((e) => TripActivity.fromJson(e)).toList();
  } catch (e) {
    // Best-effort : si offline, on retourne vide. Les stale ne sont
    // pas critiques (zone d'archives), inutile de bloquer le planning.
    return const [];
  }
});

final tripTransportsProvider = FutureProvider.family<List<TripTransport>, String>((ref, tripId) async {
  final client = ref.watch(supabaseProvider);
  final cache = await ref.watch(localTripsCacheServiceProvider.future);
  try {
    final data = await client.from('trip_transports').select().eq('trip_id', tripId);
    final rows = (data as List).whereType<Map<String, dynamic>>().toList();
    cache.writeTransports(tripId, rows);
    ref.read(isOfflineProvider.notifier).state = false;
    return rows.map((e) => TripTransport.fromJson(e)).toList();
  } catch (e) {
    ref.read(isOfflineProvider.notifier).state = true;
    return cache.readTransports(tripId);
  }
});

/// Calcul du budget d'un voyage : somme des prix estimés (activités + trajets
/// sélectionnés) convertis dans la devise de l'utilisateur, ventilé par jour +
/// total. Les prix non parsables ou en devise sans taux disponible sont comptés
/// comme "inconnus" via `unknownCount`.
final tripBudgetProvider = FutureProvider.family<TripBudget, String>((ref, tripId) async {
  final activities = await ref.watch(tripActivitiesProvider(tripId).future);
  final transports = await ref.watch(tripTransportsProvider(tripId).future);
  final userCurrency = ref.watch(userCurrencyProvider);
  final service = ref.watch(currencyServiceProvider);

  // Map activity.id → ISO day (pour rattacher un transport à une journée via son from_activity_id)
  final activityDayById = <String, String>{};
  for (final a in activities) {
    activityDayById[a.id] = a.dayDate.toIso8601String().split('T').first;
  }

  final byDay = <String, double>{};
  var total = 0.0;
  var unknownCount = 0;

  // Cache des taux pour éviter N appels réseau sur un voyage multi-devise
  final rateCache = <String, double?>{};
  Future<double?> rateTo(String from) async {
    if (from == userCurrency) return 1.0;
    if (rateCache.containsKey(from)) return rateCache[from];
    final r = await service.getRate(from, userCurrency);
    rateCache[from] = r;
    return r;
  }

  Future<void> addAmount(String? raw, String isoDay) async {
    final parsed = parseAmountForBudget(raw);
    if (parsed == null) {
      // "Gratuit"/"Free"/vide → on compte 0 (pas d'unknown), prix non parsable → unknown
      if (raw != null && raw.trim().isNotEmpty &&
          !RegExp(r'^(gratuit|free|offert|inclus)', caseSensitive: false).hasMatch(raw)) {
        unknownCount++;
      }
      return;
    }
    final rate = await rateTo(parsed.currency);
    if (rate == null) {
      unknownCount++;
      return;
    }
    final converted = parsed.amount * rate;
    byDay[isoDay] = (byDay[isoDay] ?? 0) + converted;
    total += converted;
  }

  for (final a in activities) {
    final iso = a.dayDate.toIso8601String().split('T').first;
    await addAmount(a.priceEstimate, iso);
  }
  for (final t in transports) {
    final iso = activityDayById[t.fromActivityId];
    if (iso == null) continue; // trajet orphelin, ignoré
    await addAmount(t.selectedPriceEstimate, iso);
  }

  return TripBudget(total: total, byDay: byDay, unknownCount: unknownCount);
});

/// Timeline complet du voyage = activités réelles + activités virtuelles générées à partir
/// des documents du wallet (vols, trains, tickets, hôtel check-in/out, location voiture).
/// Les virtuelles ont un id préfixé `doc:` pour être distinguées à l'affichage.
final planningTimelineProvider = FutureProvider.family<List<TripActivity>, String>((ref, tripId) async {
  final activities = await ref.watch(tripActivitiesProvider(tripId).future);
  final documents = await ref.watch(tripDocumentsProvider(tripId).future);
  final virtuals = documents.expand(virtualActivitiesFromDocument).toList();
  return [...activities, ...virtuals];
});

/// V6 (Lalith 2026-05-10 — Lot E TODO 1) — activités utilisateur dont
/// la date de jour ne correspond plus à aucun segment de l'itinéraire.
/// Cas typique : l'user a réordonné/raccourci son itinéraire et un
/// dîner ajouté manuellement le 26/06 se retrouve hors plage.
///
/// Source : `findOrphanedActivities` filtre les `suggested=true`
/// (déjà supprimées par `clearGeneratedActivitiesForTrip`) et les
/// virtuelles (id `doc:…`, gérées par `document_consistency`).
///
/// La liste alimente la bannière « Activités à replacer » dans le
/// planning. Vide la plupart du temps → bandeau caché.
final orphanedActivitiesProvider =
    FutureProvider.family<List<TripActivity>, String>((ref, tripId) async {
  final activities = await ref.watch(tripActivitiesProvider(tripId).future);
  final trip = await ref.watch(tripByIdProvider(tripId).future);
  if (trip == null) return const [];
  return findOrphanedActivities(
    activities: activities,
    segments: trip.itinerarySegments,
    tripStartDate: trip.startDate,
  );
});

final geminiCacheServiceProvider = Provider<GeminiCacheService>((ref) {
  return GeminiCacheService(ref.watch(supabaseProvider));
});

final routesServiceProvider = Provider<RoutesService>((ref) {
  return RoutesService(cache: ref.watch(geminiCacheServiceProvider));
});

final placesNearbyServiceProvider = Provider<PlacesNearbyService>((ref) {
  return PlacesNearbyService(cache: ref.watch(geminiCacheServiceProvider));
});

final aiSuggestionsServiceProvider = Provider<AiSuggestionsService>((ref) {
  return AiSuggestionsService(
    ref.watch(supabaseProvider),
    cache: ref.watch(geminiCacheServiceProvider),
  );
});

final placesServiceProvider = Provider<PlacesService>((ref) => PlacesService());

final geocodingServiceProvider = Provider<GeocodingService>((ref) => GeocodingService());

final placesCacheServiceProvider = Provider<PlacesCacheService>((ref) {
  return PlacesCacheService(
    ref.watch(supabaseProvider),
    ref.watch(placesServiceProvider),
  );
});

final placeLookupCacheServiceProvider = Provider<PlaceLookupCacheService>((ref) {
  return PlaceLookupCacheService(
    ref.watch(supabaseProvider),
    ref.watch(placesServiceProvider),
  );
});

final tripSegmentSyncServiceProvider = Provider<TripSegmentSyncService>((ref) {
  return TripSegmentSyncService(ref.watch(supabaseProvider));
});

final activityPhotosProvider = FutureProvider.family<List<PlacePhoto>, TripActivity>((ref, activity) async {
  final info = await ref.watch(activityPlaceInfoProvider(activity).future);
  return info.photos;
});

/// Avis Google + horaires d'ouverture pour une activité (un seul appel Places Details, cached).
final activityDetailsProvider =
    FutureProvider.family<({List<PlaceReview> reviews, OpeningHours? openingHours}), TripActivity>((ref, activity) async {
  // Idem que activityPlaceInfoProvider : pas d'avis/horaires pour les activités
  // d'hébergement (faux match Places avec des commerces homonymes).
  if (activity.tag == 'Hébergement') {
    return (reviews: const <PlaceReview>[], openingHours: null);
  }
  final cache = ref.watch(placesCacheServiceProvider);
  final trip = await ref.read(tripByIdProvider(activity.tripId).future);
  final info = await ref.watch(activityPlaceInfoProvider(activity).future);
  return cache.getDetails(
    title: activity.title,
    destination: trip?.destination ?? '',
    placeId: info.placeId,
  );
});

/// Avis seuls (shim pour les appelants existants).
final activityReviewsProvider = FutureProvider.family<List<PlaceReview>, TripActivity>((ref, activity) async {
  final details = await ref.watch(activityDetailsProvider(activity).future);
  return details.reviews;
});

/// Horaires d'ouverture seuls.
final activityOpeningHoursProvider = FutureProvider.family<OpeningHours?, TripActivity>((ref, activity) async {
  final details = await ref.watch(activityDetailsProvider(activity).future);
  return details.openingHours;
});

/// Fetch Places info (photos + rating + price level) et cache tout en DB.
/// Si tout est déjà en cache DB, retourne direct sans appel Places.
final activityPlaceInfoProvider = FutureProvider.family<PlaceInfo, TripActivity>((ref, activity) async {
  // Les activités d'hébergement (check-in/out virtuels, "Retour à...") pointent sur
  // l'hébergement personnel du voyageur. Une recherche Places ferait un faux match
  // avec un commerce homonyme dans la ville (ex: "Maison LOU" matché à un resto "Loulou"
  // à Metz). On skip la recherche — les données affichables restent : titre, heure,
  // adresse du doc hôtel si renseignée.
  if (activity.tag == 'Hébergement') {
    return PlaceInfo.empty;
  }

  // CACHE HIT : toutes les données sont déjà en DB → on reconstruit PlaceInfo sans appel réseau
  final hasPhotosCache = activity.photoUrls.isNotEmpty;
  final hasRatingCache = activity.rating != null;
  if (hasPhotosCache && hasRatingCache) {
    return PlaceInfo(
      photos: activity.photoUrls.map((url) => PlacePhoto(url: url)).toList(),
      rating: activity.rating,
      ratingsCount: activity.ratingsCount,
      priceLevel: activity.priceLevel,
    );
  }

  // CACHE MISS : on passe par le cache partagé places_cache (puis Places si besoin)
  final cacheService = ref.watch(placesCacheServiceProvider);
  final trip = await ref.read(tripByIdProvider(activity.tripId).future);
  final info = await cacheService.findInfo(
    title: activity.title,
    destination: trip?.destination ?? '',
    latitude: activity.latitude,
    longitude: activity.longitude,
  );

  final client = ref.watch(supabaseProvider);
  final updates = <String, dynamic>{};
  if (info.rating != null && activity.rating != info.rating) {
    updates['rating'] = info.rating;
  }
  if (info.ratingsCount != null && activity.ratingsCount != info.ratingsCount) {
    updates['ratings_count'] = info.ratingsCount;
  }
  if (info.priceLevel != null && activity.priceLevel != info.priceLevel) {
    updates['price_level'] = info.priceLevel;
  }
  if (info.photos.isNotEmpty && activity.photoUrls.isEmpty) {
    updates['photo_urls'] = info.photos.map((p) => p.url).toList();
  }
  if (updates.isNotEmpty) {
    try {
      await client.from('trip_activities').update(updates).eq('id', activity.id);
      ref.invalidate(tripActivitiesProvider(activity.tripId));
    } catch (_) {}
  }
  return info;
});

/// Retourne la description de l'activité. Si aucune n'existe en base, la génère via Gemini
/// et la sauvegarde. Permet de ne payer le coût qu'une fois par activité.
final activityDescriptionProvider = FutureProvider.family<String, TripActivity>((ref, activity) async {
  // Pas de description pour les activités d'hébergement. Check PRIORITAIRE sur la
  // description cachée en DB : si une description a été mal générée précédemment
  // (faux match Places → Gemini avait décrit le mauvais lieu), on la masque.
  if (activity.tag == 'Hébergement') {
    return '';
  }
  // Si déjà présente, on la retourne direct
  if (activity.description != null && activity.description!.isNotEmpty) {
    return activity.description!;
  }
  final client = ref.watch(supabaseProvider);
  // Charge le voyage pour avoir la destination
  final tripData = await client.from('trips').select('destination').eq('id', activity.tripId).maybeSingle();
  final destination = tripData?['destination'] as String? ?? '';

  final service = ref.watch(aiSuggestionsServiceProvider);
  final description = await service.describeActivity(
    title: activity.title,
    detail: activity.detail,
    destination: destination,
    tag: activity.tag,
  );

  // Cache en DB (silencieux si échec — on renvoie la description quand même)
  try {
    await client.from('trip_activities').update({'description': description}).eq('id', activity.id);
    ref.invalidate(tripActivitiesProvider(activity.tripId));
  } catch (_) {}

  return description;
});
