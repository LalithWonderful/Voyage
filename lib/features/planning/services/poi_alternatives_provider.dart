import 'dart:developer' as developer;

import 'package:voyage/features/planning/data/destination_key_mapper.dart';
import 'package:voyage/features/planning/models/activity_suggestion_model.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/poi/domain/poi.dart';
import 'package:voyage/features/poi/domain/poi_repository.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

/// Fournit des alternatives à une activité depuis la base POI locale.
///
/// Aucun appel réseau. Pour les destinations couvertes, charge les POIs,
/// filtre et classe par pertinence, puis retourne des [ActivitySuggestion].
class PoiAlternativesProvider {
  final PoiRepository _repo;

  PoiAlternativesProvider(this._repo);

  /// Cherche des alternatives POI pour [current] dans le contexte de [trip].
  ///
  /// Retourne une liste vide si :
  /// - la destination n'est pas couverte
  /// - aucun POI n'est disponible
  /// - tous les POIs sont déjà dans le planning
  ///
  /// [allActivities] sert à exclure les titres déjà présents.
  Future<List<ActivitySuggestion>> suggestAlternatives({
    required TripActivity current,
    required Trip trip,
    required List<TripActivity> allActivities,
  }) async {
    final destinationKey = DestinationKeyMapper.map(trip.destination);
    if (destinationKey == null) {
      developer.log(
        '[alternatives] source=none reason=destination_not_covered '
        'destination="${trip.destination}"',
        name: 'planning',
      );
      return const [];
    }

    final pois = await _repo.listPoisByDestination(destinationKey);
    if (pois.isEmpty) {
      developer.log(
        '[alternatives] source=none reason=no_pois '
        'destinationKey=$destinationKey',
        name: 'planning',
      );
      return const [];
    }

    final excludedTitles = _normalizeTitles(allActivities);
    final currentNormalized = _normalize(current.title);

    final candidates = <_ScoredPoi>[];
    for (final poi in pois) {
      final poiNormalized = _normalize(poi.name);
      if (poiNormalized == currentNormalized) continue;
      if (excludedTitles.contains(poiNormalized)) continue;

      final score = _scorePoi(poi, current);
      candidates.add(_ScoredPoi(poi, score));
    }

    // Trier par score décroissant
    candidates.sort((a, b) => b.score.compareTo(a.score));

    final results = candidates
        .take(5)
        .map((s) => _poiToSuggestion(s.poi, current))
        .toList();

    developer.log(
      '[alternatives] source=poi destinationKey=$destinationKey '
      'count=${results.length} totalPois=${pois.length}',
      name: 'planning',
    );
    return results;
  }

  /// Score un POI par rapport à l'activité courante.
  ///
  /// Critères :
  /// - même catégorie : +50
  /// - editorialScore élevé : 0..100
  /// - touristicImportance élevé : 0..25 (×5)
  double _scorePoi(Poi poi, TripActivity current) {
    var score = 0.0;

    // Bonus catégorie compatible
    if (_categoryMatchesTag(poi.category, current.tag)) {
      score += 50.0;
    }

    // Score éditorial (0-100)
    score += (poi.editorialScore ?? 0).toDouble();

    // Importance touristique (1-5) → 0-25
    score += ((poi.touristicImportance ?? 1) * 5).toDouble();

    return score;
  }

  ActivitySuggestion _poiToSuggestion(Poi poi, TripActivity current) {
    return ActivitySuggestion(
      dayDate: current.dayDate,
      startTime: current.startTime,
      title: poi.name,
      detail: poi.address,
      tag: _poiCategoryToTag(poi.category),
      kind: ActivityKind.main,
      durationMinutes: poi.typicalDurationMinutes ?? current.durationMinutes,
      priceEstimate: _priceEstimateFromLevel(poi.priceLevel),
      matchReason: poi.isMustSee ? 'Incontournable' : 'Suggestion POI',
      latitude: poi.lat,
      longitude: poi.lng,
    );
  }

  static bool _categoryMatchesTag(PoiCategory category, String tag) {
    final tagLower = tag.toLowerCase();
    switch (category) {
      case PoiCategory.museum:
      case PoiCategory.monument:
        return tagLower == 'culture';
      case PoiCategory.park:
      case PoiCategory.nature:
        return tagLower == 'nature';
      case PoiCategory.beach:
        return tagLower == 'plage';
      case PoiCategory.food:
      case PoiCategory.market:
        return tagLower == 'gastronomie';
      case PoiCategory.shopping:
        return tagLower == 'shopping';
      case PoiCategory.nightlife:
        return tagLower == 'nightlife';
      case PoiCategory.wellness:
        return tagLower == 'wellness';
      case PoiCategory.viewpoint:
      case PoiCategory.photoSpot:
        return tagLower == 'spots populaires';
      case PoiCategory.localExperience:
        return tagLower == 'bons plans';
      default:
        return false;
    }
  }

  static String _poiCategoryToTag(PoiCategory category) {
    switch (category) {
      case PoiCategory.museum:
      case PoiCategory.monument:
        return 'Culture';
      case PoiCategory.park:
      case PoiCategory.nature:
        return 'Nature';
      case PoiCategory.beach:
        return 'Plage';
      case PoiCategory.food:
      case PoiCategory.market:
        return 'Gastronomie';
      case PoiCategory.shopping:
        return 'Shopping';
      case PoiCategory.nightlife:
        return 'Nightlife';
      case PoiCategory.wellness:
        return 'Wellness';
      case PoiCategory.viewpoint:
      case PoiCategory.photoSpot:
        return 'Spots populaires';
      case PoiCategory.neighborhood:
        return 'Hors circuit';
      case PoiCategory.localExperience:
        return 'Bons plans';
      default:
        return 'Activité';
    }
  }

  static String? _priceEstimateFromLevel(int? level) {
    switch (level) {
      case 0:
      case 1:
        return 'Gratuit';
      case 2:
        return '~10 €';
      case 3:
        return '~25 €';
      case 4:
        return '~50 €';
      default:
        return null;
    }
  }

  static Set<String> _normalizeTitles(List<TripActivity> activities) {
    return activities.map((a) => _normalize(a.title)).toSet();
  }

  static String _normalize(String s) {
    return s.toLowerCase().trim();
  }
}

class _ScoredPoi {
  final Poi poi;
  final double score;
  _ScoredPoi(this.poi, this.score);
}
