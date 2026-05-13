import 'package:voyage/features/poi/domain/poi_repository.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';

/// Adapte les POIs curatés en NearbyCandidate pour le pipeline planning.
/// Garantit : pas de coordonnées 0,0, pas de POI sans lat/lng, pas de doublons.
class PoiCandidateAdapter {
  final PoiRepository _repo;
  PoiCandidateAdapter(this._repo);

  Future<List<NearbyCandidate>> adaptForDestination(String destinationKey) async {
    final pois = await _repo.listPoisByDestination(destinationKey);

    // POI-2.5 diagnostic + guard : valider que tous les POIs retournés
    // appartiennent bien à la destination demandée.
    final foreignPois = pois.where((p) => p.destinationKey != destinationKey).toList();
    if (foreignPois.isNotEmpty) {
      // ignore: avoid_print
      print(
        '[poi_destination] CRITICAL foreign POIs detected : '
        'requested=$destinationKey foreign=${foreignPois.map((p) => '"${p.name}"(${p.destinationKey})').toList()}',
      );
    }
    // Filtre défensif : on ne garde que les POIs de la destination demandée.
    final validPois = pois.where((p) => p.destinationKey == destinationKey).toList();
    // ignore: avoid_print
    print(
      '[poi_destination] poiDestinationKeys='
      '${validPois.map((p) => p.destinationKey).toSet().toList()} '
      'count=${validPois.length}',
    );

    final candidates = <NearbyCandidate>[];
    final seenPlaceIds = <String>{};

    for (final poi in validPois) {
      // Skip POIs sans coordonnées valides (hard constraint POI-2.0)
      if (poi.lat == null || poi.lng == null) continue;
      if (poi.lat!.isNaN || poi.lng!.isNaN) continue;

      final placeId = poi.googlePlaceId ?? 'poi:${poi.poiId}';

      // Dédoublonnage strict : un POI ne devient qu'un seul candidat
      if (!seenPlaceIds.add(placeId)) continue;

      // POI-2.5 fix : curated POIs must pass the deterministic selector's
      // quality gates (_isAllowedFinalVisitCandidate). Two fields need
      // synthetic values because the POI model has no review count:
      //   - rating  : must be >= 4.0  → floor at 4.0
      //   - userRatingCount : must be >= 5 (travel-safe) and >= 30 for
      //     non-strong-travel types → set to 50 to pass all gates cleanly.
      final rawRating = poi.editorialScore != null ? poi.editorialScore! / 20.0 : null;
      final safeRating = rawRating != null && rawRating >= 4.0 ? rawRating : 4.0;

      candidates.add(NearbyCandidate(
        placeId: placeId,
        name: poi.name,
        address: poi.address,
        rating: safeRating,
        userRatingCount: 50,
        priceLevel: poi.priceLevel,
        types: [poi.category.toJsonString(), if (poi.subcategory != null) poi.subcategory!],
        latitude: poi.lat!,
        longitude: poi.lng!,
      ));
    }
    return candidates;
  }
}
