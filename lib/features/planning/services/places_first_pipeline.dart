import 'dart:developer' as developer;
import 'package:voyage/features/planning/services/day_center_service.dart';
import 'package:voyage/features/planning/services/geocoding_service.dart';
import 'package:voyage/features/planning/services/interests_to_places_mapping.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';
import 'package:voyage/features/planning/services/traveler_to_places_mapping.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/wallet/models/document_model.dart';

/// Pool de candidats Places pour UN jour du voyage.
/// Une journée = un centre géographique (lat/lng calculé via day_center_service)
/// + une liste de candidats par intérêt voyageur.
///
/// La même `NearbyCandidate` peut apparaître dans plusieurs intérêts (ex: la
/// Place Stanislas matche à la fois "Culture" et "Spots populaires"). Le caller
/// est libre de dédupliquer pour la sélection finale.
class DayCandidates {
  final DateTime day;
  final DayCenter center;
  /// Clé = libellé d'intérêt voyageur ("Culture", "Gastronomie", ...).
  /// Valeur = candidats Places retenus pour cet intérêt après filtres.
  final Map<String, List<NearbyCandidate>> byInterest;

  const DayCandidates({
    required this.day,
    required this.center,
    required this.byInterest,
  });

  /// Tous les candidats du jour, dédupliqués par place_id, conservant pour
  /// chaque candidat la liste des intérêts qui l'ont matché (utile pour le
  /// prompt Gemini : "ce lieu peut servir Gastronomie ET Bons plans").
  Map<String, ({NearbyCandidate candidate, List<String> matchedInterests})> get allUnique {
    final out = <String, ({NearbyCandidate candidate, List<String> matchedInterests})>{};
    byInterest.forEach((interest, list) {
      for (final c in list) {
        final existing = out[c.placeId];
        if (existing == null) {
          out[c.placeId] = (candidate: c, matchedInterests: [interest]);
        } else {
          out[c.placeId] = (
            candidate: existing.candidate,
            matchedInterests: [...existing.matchedInterests, interest],
          );
        }
      }
    });
    return out;
  }

  int get totalCandidates => byInterest.values.fold(0, (sum, list) => sum + list.length);
  int get uniqueCandidates => allUnique.length;
}

/// Récolte les candidats Places pour CHAQUE jour du voyage. Brique de base
/// du flow Places-first (refonte du suggesteur 2026-04-25). Le pipeline
/// complet enchaîne ici puis :
/// 1. construit un prompt Gemini avec les pools de candidats par jour
/// 2. demande à Gemini d'organiser/sélectionner parmi cette liste
/// 3. construit les ActivitySuggestion finales depuis les place_id retournés
///
/// Logique par jour :
/// - Centre = `centerForDay()` (hôtel actif → ville segment → destination).
/// - Pour chaque intérêt du voyageur :
///   - Skip si exclu par le profil voyageur (ex: Famille → Nightlife).
///   - Merge types et textQueries (intérêt + profil).
///   - Fetch Nearby (par types) + Text Search (par mots-clés) en parallèle.
///   - Dédup par place_id, applique les filtres (rating ≥ global + spécifiques).
///
/// Latence : N jours × M intérêts × ≤5 calls Places, mais cache `places_search`
/// (gemini_cache) hit dès qu'un centre × types est répété (cas typique : mono-ville
/// long séjour, tous les jours partagent le même centre → 1er jour paie, suivants
/// gratuits). Centre arrondi à 3 décimales (~110 m) dans le cache key.
Future<List<DayCandidates>> gatherCandidatesForTrip({
  required Trip trip,
  required List<TripDocument> hotels,
  required GeocodingService geocoder,
  required PlacesNearbyService nearbyService,
  /// Si null, on prend `trip.interests`. Sinon on override (utile pour les
  /// tests ciblés ou un Suggérer "Restaurants uniquement").
  List<String>? interestsOverride,
}) async {
  final interests = interestsOverride ?? trip.interests ?? const <String>[];
  if (interests.isEmpty) {
    developer.log('Aucun intérêt sur ce voyage — pool vide', name: 'places_first');
    return [];
  }

  final travelerProfile = trip.travelerType != null
      ? travelerPlacesProfiles[trip.travelerType]
      : null;
  final searchRadius = travelerProfile?.searchRadiusMeters ?? defaultSearchRadiusMeters;

  // Itère sur les jours du voyage (inclus startDate, inclus endDate).
  final days = <DateTime>[];
  final start = DateTime(trip.startDate.year, trip.startDate.month, trip.startDate.day);
  final end = DateTime(trip.endDate.year, trip.endDate.month, trip.endDate.day);
  for (var d = start; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
    days.add(d);
  }
  developer.log(
    'Trip "${trip.title}" : ${days.length} jours, ${interests.length} intérêts, '
    'profil=${trip.travelerType ?? "default"}, radius=${searchRadius}m',
    name: 'places_first',
  );

  // Traitement parallèle par jour. Le cache places_search dédoublonne les
  // appels redondants quand plusieurs jours partagent le même centre.
  final results = await Future.wait(days.map((day) async {
    final center = await centerForDay(
      trip: trip,
      day: day,
      hotels: hotels,
      geocoder: geocoder,
    );
    if (center == null) {
      developer.log(
        'Jour ${_iso(day)} : centre non géocodable, skip',
        name: 'places_first',
      );
      return null;
    }

    final byInterest = <String, List<NearbyCandidate>>{};
    for (final interest in interests) {
      final query = interestPlacesQueries[interest];
      if (query == null) continue;
      // Veto profil voyageur (ex: Famille → Nightlife)
      if (travelerProfile != null && travelerProfile.excludedInterests.contains(interest)) {
        continue;
      }
      // Merge types et textQueries (intérêt + profil)
      final mergedTypes = <String>{
        ...query.includedTypes,
        if (travelerProfile != null) ...travelerProfile.additionalTypes,
      }.toList();
      final mergedTextQueries = <String>[
        ...query.textQueries,
        if (travelerProfile != null) ...travelerProfile.additionalTextQueries,
      ];

      final calls = <Future<List<NearbyCandidate>>>[];
      if (mergedTypes.isNotEmpty) {
        calls.add(nearbyService.searchNearby(
          latitude: center.latitude,
          longitude: center.longitude,
          includedTypes: mergedTypes,
          radius: searchRadius,
        ));
      }
      for (final tq in mergedTextQueries) {
        calls.add(nearbyService.searchText(
          textQuery: tq,
          latitude: center.latitude,
          longitude: center.longitude,
          radius: searchRadius,
        ));
      }
      final fetched = await Future.wait(calls);
      // Dédup par place_id
      final merged = <String, NearbyCandidate>{};
      for (final list in fetched) {
        for (final c in list) {
          merged[c.placeId] = c;
        }
      }
      // Filtres : rating global + filtres spécifiques de l'intérêt
      final filtered = merged.values.where((c) {
        final r = c.rating;
        if (r == null || r < placesGlobalMinRating) return false;
        return query.matchesFilters(c);
      }).toList();
      byInterest[interest] = filtered;
    }

    return DayCandidates(day: day, center: center, byInterest: byInterest);
  }));

  final pool = results.whereType<DayCandidates>().toList();
  final totalUnique = pool.fold<int>(0, (sum, d) => sum + d.uniqueCandidates);
  developer.log(
    'Récolte terminée : ${pool.length} jours, $totalUnique lieux uniques cumulés',
    name: 'places_first',
  );
  return pool;
}

String _iso(DateTime d) => d.toIso8601String().split('T').first;
