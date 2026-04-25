import 'dart:convert';
import 'dart:developer' as developer;
import 'package:voyage/features/planning/models/activity_suggestion_model.dart';
import 'package:voyage/features/planning/services/ai_suggestions_service.dart';
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

/// Groupe de jours partageant le même centre (= mono-ville complète, ou un
/// segment d'une multi-villes). Un même `PlacesPromptInput` permet d'envoyer
/// UN SEUL prompt Gemini pour tous les jours du groupe au lieu de N prompts —
/// économie tokens × N et cohérence des choix entre jours.
class PlacesPromptInput {
  final DayCenter center;
  final List<DateTime> days;
  /// Pool de candidats agrégés sur tous les jours du groupe (en mono-ville la
  /// pool est identique tous les jours, donc fusionner ne change rien). Indexé
  /// par place_id, conserve la liste des intérêts qui matchent chaque candidat.
  final Map<String, ({NearbyCandidate candidate, List<String> matchedInterests})> pool;

  const PlacesPromptInput({
    required this.center,
    required this.days,
    required this.pool,
  });

  int get poolSize => pool.length;
}

/// Regroupe les jours du voyage par centre géographique (lat/lng arrondi
/// 3 décimales = ~110m). En mono-ville → 1 seul groupe. En multi-villes
/// (Nancy/Épinal) → 2 groupes. Économise les calls Gemini : 1 prompt par
/// groupe au lieu de 1 par jour.
List<PlacesPromptInput> groupDaysByCenter(List<DayCandidates> dayPool) {
  final groups = <String, ({DayCenter center, List<DateTime> days, Map<String, ({NearbyCandidate candidate, List<String> matchedInterests})> pool})>{};

  for (final day in dayPool) {
    final key = '${day.center.latitude.toStringAsFixed(3)},${day.center.longitude.toStringAsFixed(3)}';
    final dayUnique = day.allUnique;
    final existing = groups[key];
    if (existing == null) {
      groups[key] = (
        center: day.center,
        days: [day.day],
        pool: Map.from(dayUnique),
      );
    } else {
      existing.days.add(day.day);
      // Fusion : si un nouveau candidat apparaît pour ce centre on l'ajoute,
      // si un existant a de nouveaux intérêts matchés on les fusionne.
      dayUnique.forEach((placeId, entry) {
        final ex = existing.pool[placeId];
        if (ex == null) {
          existing.pool[placeId] = entry;
        } else {
          final mergedInterests = {...ex.matchedInterests, ...entry.matchedInterests}.toList();
          existing.pool[placeId] = (candidate: ex.candidate, matchedInterests: mergedInterests);
        }
      });
    }
  }
  return groups.values
      .map((g) => PlacesPromptInput(center: g.center, days: g.days, pool: g.pool))
      .toList();
}

/// Trie la pool par "qualité" (rating × log(userRatingCount)) et garde les
/// `maxPoolSize` meilleurs. Sert à borner les tokens envoyés à Gemini quand
/// la ville est très riche en lieux. 50 est un compromis raisonnable :
/// largement assez pour 6 jours × 4 créneaux × 3 options diverses.
List<MapEntry<String, ({NearbyCandidate candidate, List<String> matchedInterests})>> _trimPool(
  Map<String, ({NearbyCandidate candidate, List<String> matchedInterests})> pool, {
  int maxPoolSize = 50,
}) {
  final entries = pool.entries.toList();
  entries.sort((a, b) {
    final ra = a.value.candidate.rating ?? 0;
    final rb = b.value.candidate.rating ?? 0;
    final ca = a.value.candidate.userRatingCount ?? 0;
    final cb = b.value.candidate.userRatingCount ?? 0;
    // Score : on multiplie par log(count) pour favoriser les lieux avec un
    // bon rating ET un volume d'avis significatif (vs un 5★ avec 3 avis).
    double score(double r, int c) => r * (c <= 1 ? 1 : (1 + (c.bitLength.toDouble())));
    return score(rb, cb).compareTo(score(ra, ca));
  });
  return entries.take(maxPoolSize).toList();
}

/// Construit le prompt Gemini pour un groupe de jours en mode CoPilot.
/// Gemini reçoit la pool de candidats RÉELS (avec ID court P0/P1/.../P49),
/// le contexte voyage, et doit retourner pour chaque jour les créneaux et
/// les 3 options choisies — UNIQUEMENT parmi la pool fournie. Aucune
/// invention possible.
String buildCoPilotPrompt({
  required PlacesPromptInput input,
  required Trip trip,
  required TravelerPlacesProfile? travelerProfile,
}) {
  final entries = _trimPool(input.pool);
  // Lignes du catalogue : "P0: Nom — adresse [types] ★rating (N avis) — match: Culture, Bons plans"
  final catalogLines = <String>[];
  for (var i = 0; i < entries.length; i++) {
    final c = entries[i].value.candidate;
    final interests = entries[i].value.matchedInterests.join(', ');
    final addr = c.address ?? '';
    final typesShort = c.types.take(3).join(', ');
    catalogLines.add(
      'P$i: ${c.name} — $addr [$typesShort] ★${c.rating} (${c.userRatingCount ?? 0} avis) — match: $interests',
    );
  }
  final dayLines = input.days.map(_iso).join(', ');
  final hasKids = trip.travelers.any((t) => t.age < 13);
  final travelers = trip.travelers.isEmpty
      ? 'solo'
      : trip.travelers.map((t) => '${t.name} (${t.age} ans)').join(', ');

  final profileBlock = travelerProfile == null
      ? ''
      : '\nProfil voyageur "${trip.travelerType}" : ${travelerProfile.rule ?? "—"}'
          '${travelerProfile.maxActivityMinutes != null ? "\nDurée max par activité : ${travelerProfile.maxActivityMinutes} min." : ""}'
          '${travelerProfile.maxConsecutiveDistanceMeters != null ? "\nDistance max entre 2 activités du même jour : ${travelerProfile.maxConsecutiveDistanceMeters}m." : ""}';

  return '''
Tu es un expert en voyages. Tu dois SÉLECTIONNER (pas inventer) des activités pour un voyageur, en t'appuyant UNIQUEMENT sur la liste de lieux RÉELS ci-dessous (tous vérifiés sur Google Places).

🚫 RÈGLE ABSOLUE : tu ne peux UTILISER QUE les lieux du catalogue, identifiés par leur référence (P0, P1, ...). Tu n'as PAS le droit d'en inventer d'autres ou de modifier les noms. Si la pool ne contient pas un type de lieu pour un créneau (ex: pas de bar pour "Soirée"), saute ce créneau.

Voyage :
- Destination : ${trip.destination}
- Voyageurs : $travelers${hasKids ? ' (enfants présents)' : ''}
- Centres d'intérêt : ${trip.interests?.join(', ') ?? "non précisés"}$profileBlock

Jours à organiser : $dayLines (${input.days.length} jour${input.days.length > 1 ? 's' : ''}).

Catalogue de lieux disponibles autour du centre du jour (${input.center.source}, ${entries.length} lieux retenus) :
${catalogLines.join('\n')}

Pour CHAQUE jour ci-dessus :
- Identifie 2 à 4 créneaux pertinents (ex: "Matin", "Déjeuner", "Après-midi", "Soirée").
- Pour CHAQUE créneau, propose **EXACTEMENT 3 options** parmi le catalogue (par ref P0, P1, ...).
- Les 3 options d'un même créneau doivent être de la MÊME intention (ex: 3 musées pour un matin culture, 3 restos pour un déjeuner) mais variées en gamme/quartier/ambiance.
- Varie les choix entre les jours : pas la même option à chaque jour. Si la pool est petite, accepte de répéter MAX 2 fois la même option à travers tous les créneaux du voyage.
- Pour chaque option, donne un `match_reason` (1 phrase) qui explique pourquoi elle convient à CE voyageur sur CE créneau.
- Choisis une heure de début réaliste pour le créneau (matin 9-10h, déjeuner 12-13h, après-midi 14-16h, soirée 19-21h, à adapter aux horaires d'ouverture probables du type de lieu).

Format OBLIGATOIRE — UNIQUEMENT ce JSON, sans balises, sans texte autour :
{
  "days": [
    {
      "date": "YYYY-MM-DD",
      "slots": [
        {
          "label": "Matin",
          "start_time": "10:00",
          "options": [
            {"ref": "P0", "duration_minutes": 90, "price_estimate": "~12€", "match_reason": "Matche ton intérêt 'Culture' + créneau matin tranquille"},
            {"ref": "P5", "duration_minutes": 60, "price_estimate": "Gratuit", "match_reason": "..."},
            {"ref": "P12", "duration_minutes": 120, "price_estimate": "~25€", "match_reason": "..."}
          ]
        }
      ]
    }
  ]
}
''';
}

/// Parse la réponse Gemini d'un prompt CoPilot et reconstitue les
/// `SuggestionGroup` consommables par le pipeline existant. Les options
/// sont reconstruites depuis la pool (titre canonique Places, adresse,
/// rating) — Gemini ne fait que choisir des refs, pas de strings à valider.
List<SuggestionGroup> parseCoPilotResponse({
  required String rawJson,
  required PlacesPromptInput input,
}) {
  // Index P0/P1/.../Pn → candidat. Doit reproduire l'ordre de _trimPool
  // utilisé dans le prompt.
  final entries = _trimPool(input.pool);
  final byRef = <String, NearbyCandidate>{};
  for (var i = 0; i < entries.length; i++) {
    byRef['P$i'] = entries[i].value.candidate;
  }

  final cleaned = _stripCodeFences(rawJson).trim();
  dynamic parsed;
  try {
    parsed = jsonDecode(cleaned);
  } catch (e) {
    developer.log('parseCoPilotResponse : JSON invalide — $e', name: 'places_first');
    return [];
  }
  if (parsed is! Map) return [];
  final daysJson = parsed['days'] as List? ?? const [];

  final groups = <SuggestionGroup>[];
  for (final dayJson in daysJson) {
    if (dayJson is! Map) continue;
    final dateStr = dayJson['date'] as String?;
    if (dateStr == null) continue;
    final date = DateTime.tryParse(dateStr);
    if (date == null) continue;
    final slots = dayJson['slots'] as List? ?? const [];
    for (final slotJson in slots) {
      if (slotJson is! Map) continue;
      final slotLabel = (slotJson['label'] as String?)?.trim() ?? 'Créneau';
      final slotStart = (slotJson['start_time'] as String?)?.trim() ?? '';
      final optionsJson = slotJson['options'] as List? ?? const [];

      final options = <ActivitySuggestion>[];
      for (final optJson in optionsJson) {
        if (optJson is! Map) continue;
        final ref = (optJson['ref'] as String?)?.trim();
        if (ref == null) continue;
        final candidate = byRef[ref];
        if (candidate == null) {
          developer.log('Réf inconnue "$ref" dans la réponse Gemini — skip', name: 'places_first');
          continue;
        }
        // Tag déduit du primary type Places (heuristique simple, à raffiner)
        final tag = _tagFromPrimaryType(candidate.types.isNotEmpty ? candidate.types.first : '');
        options.add(ActivitySuggestion(
          dayDate: date,
          startTime: slotStart,
          title: candidate.name,
          detail: candidate.address,
          tag: tag,
          durationMinutes: (optJson['duration_minutes'] as num?)?.toInt(),
          priceEstimate: (optJson['price_estimate'] as String?)?.trim(),
          matchReason: (optJson['match_reason'] as String?)?.trim(),
        ));
      }
      if (options.isEmpty) continue;
      groups.add(SuggestionGroup(
        dayDate: date,
        slotLabel: slotLabel,
        startTime: slotStart,
        options: options,
      ));
    }
  }
  return groups;
}

/// Mappe le primary type Places vers un tag Voyage compréhensible par l'UI
/// (cf. tags utilisés dans le pipeline existant : Repas, Visite, Culture, etc.).
String _tagFromPrimaryType(String primaryType) {
  if (primaryType.isEmpty) return 'Activité';
  if (primaryType.contains('restaurant') ||
      primaryType == 'cafe' ||
      primaryType == 'bakery' ||
      primaryType == 'meal_delivery' ||
      primaryType == 'meal_takeaway' ||
      primaryType == 'food_court') {
    return 'Repas';
  }
  if (primaryType.contains('museum') ||
      primaryType == 'art_gallery' ||
      primaryType == 'library' ||
      primaryType == 'historical_landmark' ||
      primaryType == 'historical_place') {
    return 'Culture';
  }
  if (primaryType == 'park' ||
      primaryType == 'national_park' ||
      primaryType == 'botanical_garden' ||
      primaryType == 'zoo' ||
      primaryType == 'aquarium' ||
      primaryType == 'beach') {
    return 'Nature';
  }
  if (primaryType == 'bar' ||
      primaryType == 'night_club' ||
      primaryType == 'pub' ||
      primaryType.contains('bar')) {
    return 'Nightlife';
  }
  if (primaryType.contains('shop') ||
      primaryType.contains('store') ||
      primaryType == 'shopping_mall' ||
      primaryType == 'market') {
    return 'Shopping';
  }
  if (primaryType == 'spa' || primaryType == 'beauty_salon' || primaryType == 'gym') {
    return 'Wellness';
  }
  if (primaryType == 'church' || primaryType == 'place_of_worship') {
    return 'Culture';
  }
  if (primaryType == 'tourist_attraction' || primaryType == 'landmark') {
    return 'Visite';
  }
  if (primaryType == 'amusement_park' || primaryType == 'amusement_center') {
    return 'Loisir';
  }
  if (primaryType == 'stadium' || primaryType == 'sports_complex') {
    return 'Sport';
  }
  return 'Activité';
}

String _stripCodeFences(String text) {
  var t = text.trim();
  final fence = RegExp(r'^```(?:json)?\s*|\s*```$', multiLine: true);
  t = t.replaceAll(fence, '').trim();
  return t;
}

/// Orchestre le flow Places-first pour le mode CoPilot bout-en-bout :
/// 1. Récolte les candidats Places pour chaque jour (`gatherCandidatesForTrip`).
/// 2. Pré-filtre les candidats dont le nom matche déjà une activité au planning
///    (= déjà choisie par le voyageur, pas la peine de la reproposer).
/// 3. Groupe les jours par centre géographique (`groupDaysByCenter`).
/// 4. Pour chaque groupe : prompt Gemini → parser → SuggestionGroup.
/// 5. Concatène tous les SuggestionGroup et retourne pour la sheet.
///
/// Appelle Gemini en parallèle sur les groupes (typiquement 1-3 groupes
/// pour la majorité des voyages). Cache via `gemini_cache` action
/// `places_first_copilot` (clé = hash du prompt) → re-runs gratuits.
Future<List<SuggestionGroup>> runCoPilotPlacesFirst({
  required Trip trip,
  required List<TripDocument> hotels,
  required GeocodingService geocoder,
  required PlacesNearbyService nearbyService,
  required AiSuggestionsService aiService,
  /// Titres normalisés des activités déjà au planning. Pré-filtre la pool
  /// pour éviter de reproposer ce que le voyageur a déjà coché.
  Set<String> existingTitlesNormalized = const {},
}) async {
  final pool = await gatherCandidatesForTrip(
    trip: trip,
    hotels: hotels,
    geocoder: geocoder,
    nearbyService: nearbyService,
  );
  if (pool.isEmpty) {
    developer.log('CoPilot Places-first : pool vide, rien à proposer', name: 'places_first');
    return [];
  }

  // Pré-filtre : retire de chaque DayCandidates les candidats dont le name
  // matche un titre déjà au planning. Évite de reproposer.
  if (existingTitlesNormalized.isNotEmpty) {
    String norm(String s) => s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
    for (final day in pool) {
      day.byInterest.forEach((interest, list) {
        list.removeWhere((c) => existingTitlesNormalized.contains(norm(c.name)));
      });
    }
  }

  final groups = groupDaysByCenter(pool);
  developer.log(
    'CoPilot Places-first : ${groups.length} groupe(s) → autant de prompts Gemini',
    name: 'places_first',
  );

  final travelerProfile = trip.travelerType != null
      ? travelerPlacesProfiles[trip.travelerType]
      : null;

  // Appels Gemini en parallèle, un par groupe. Chaque échec individuel
  // ne casse pas les autres (try/catch isolé par groupe).
  final results = await Future.wait(groups.map((group) async {
    final prompt = buildCoPilotPrompt(
      input: group,
      trip: trip,
      travelerProfile: travelerProfile,
    );
    try {
      final raw = await aiService.generateRaw(
        prompt: prompt,
        cacheAction: 'places_first_copilot',
        cacheKey: prompt.hashCode.toString(),
        temperature: 0.6,
      );
      return parseCoPilotResponse(rawJson: raw, input: group);
    } catch (e) {
      developer.log(
        'CoPilot Places-first : Gemini exception sur groupe ${group.center.source} : $e',
        name: 'places_first',
      );
      return <SuggestionGroup>[];
    }
  }));

  final merged = results.expand((g) => g).toList();
  developer.log(
    'CoPilot Places-first : ${merged.length} SuggestionGroup au total',
    name: 'places_first',
  );
  return merged;
}
