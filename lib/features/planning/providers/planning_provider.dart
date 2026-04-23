import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/features/auth/providers/auth_provider.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/models/trip_transport_model.dart';
import 'package:voyage/features/planning/services/ai_suggestions_service.dart';
import 'package:voyage/features/planning/services/document_to_activity.dart';
import 'package:voyage/features/planning/services/geocoding_service.dart';
import 'package:voyage/features/planning/services/places_cache_service.dart';
import 'package:voyage/features/planning/services/places_service.dart';
import 'package:voyage/features/trips/providers/trips_provider.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';

final tripActivitiesProvider = FutureProvider.family<List<TripActivity>, String>((ref, tripId) async {
  final client = ref.watch(supabaseProvider);
  final data = await client
      .from('trip_activities')
      .select()
      .eq('trip_id', tripId)
      .order('day_date', ascending: true)
      .order('sort_order', ascending: true)
      .order('start_time', ascending: true);
  return (data as List).map((e) => TripActivity.fromJson(e)).toList();
});

final tripTransportsProvider = FutureProvider.family<List<TripTransport>, String>((ref, tripId) async {
  final client = ref.watch(supabaseProvider);
  final data = await client.from('trip_transports').select().eq('trip_id', tripId);
  return (data as List).map((e) => TripTransport.fromJson(e)).toList();
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

final aiSuggestionsServiceProvider = Provider<AiSuggestionsService>((ref) {
  return AiSuggestionsService(ref.watch(supabaseProvider));
});

final placesServiceProvider = Provider<PlacesService>((ref) => PlacesService());

final geocodingServiceProvider = Provider<GeocodingService>((ref) => GeocodingService());

final placesCacheServiceProvider = Provider<PlacesCacheService>((ref) {
  return PlacesCacheService(
    ref.watch(supabaseProvider),
    ref.watch(placesServiceProvider),
  );
});

final activityPhotosProvider = FutureProvider.family<List<PlacePhoto>, TripActivity>((ref, activity) async {
  final info = await ref.watch(activityPlaceInfoProvider(activity).future);
  return info.photos;
});

/// Avis Google + horaires d'ouverture pour une activité (un seul appel Places Details, cached).
final activityDetailsProvider =
    FutureProvider.family<({List<PlaceReview> reviews, OpeningHours? openingHours}), TripActivity>((ref, activity) async {
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
