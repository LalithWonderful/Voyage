import 'package:voyage/features/poi/domain/poi_repository.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';

/// Adapte les POIs curatés en NearbyCandidate pour le pipeline planning.
/// Garantit : pas de coordonnées 0,0, pas de POI sans lat/lng, pas de doublons.
class PoiCandidateAdapter {
  final PoiRepository _repo;
  PoiCandidateAdapter(this._repo);

  Future<List<NearbyCandidate>> adaptForDestination(String destinationKey) async {
    final pois = await _repo.listPoisByDestination(destinationKey);
    final candidates = <NearbyCandidate>[];
    final seenPlaceIds = <String>{};

    for (final poi in pois) {
      // Skip POIs sans coordonnées valides (hard constraint POI-2.0)
      if (poi.lat == null || poi.lng == null) continue;
      if (poi.lat!.isNaN || poi.lng!.isNaN) continue;

      final placeId = poi.googlePlaceId ?? 'poi:${poi.poiId}';

      // Dédoublonnage strict : un POI ne devient qu'un seul candidat
      if (!seenPlaceIds.add(placeId)) continue;

      candidates.add(NearbyCandidate(
        placeId: placeId,
        name: poi.name,
        address: poi.address,
        rating: poi.editorialScore != null ? poi.editorialScore! / 20.0 : null,
        priceLevel: poi.priceLevel,
        types: [poi.category.toJsonString(), if (poi.subcategory != null) poi.subcategory!],
        latitude: poi.lat!,
        longitude: poi.lng!,
      ));
    }
    return candidates;
  }
}
