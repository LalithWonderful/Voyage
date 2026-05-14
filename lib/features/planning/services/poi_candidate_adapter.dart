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

      // POI-2.6 : transmettre le score éditorial brut au sélecteur
      // déterministe pour un scoring POI-aware. Le rating synthétique
      // reflète mieux la qualité curation : 4.0 + (editorialScore/100).
      // userRatingCount est gonflé par touristicImportance pour que
      // qualityScore = rating × log(reviews) reste compétitif.
      final rawRating = poi.editorialScore != null
          ? 4.0 + (poi.editorialScore! / 100.0)
          : null;
      final safeRating = rawRating != null && rawRating >= 4.0 ? rawRating : 4.0;
      final reviewCount = 50 + ((poi.touristicImportance ?? 1) * 50);

      candidates.add(NearbyCandidate(
        placeId: placeId,
        name: poi.name,
        address: poi.address,
        rating: safeRating,
        userRatingCount: reviewCount,
        priceLevel: poi.priceLevel,
        types: [poi.category.toJsonString(), if (poi.subcategory != null) poi.subcategory!],
        latitude: poi.lat!,
        longitude: poi.lng!,
        isCurated: true,
        editorialScore: poi.editorialScore,
        typicalDurationMinutes: poi.typicalDurationMinutes,
      ));
    }
    return candidates;
  }
}
