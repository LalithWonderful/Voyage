/// POI-0.9 — Providers Riverpod de lecture POI.
///
/// Couche de consommation du [PoiRepository] via Riverpod.
/// Aucune UI, aucune carte, aucun moteur planning.
///
/// Tous les providers sont des `FutureProvider` qui délèguent au
/// [PoiRepository] injecté. Ils peuvent être consommés par des widgets
/// (`ConsumerWidget`, `Consumer`) ou par d'autres providers.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/poi.dart';
import '../domain/poi_repository.dart';
import 'poi_repository_provider.dart';

/// Paramètres de recherche POI.
///
/// Immutable et comparable (== / hashCode) pour que Riverpod `family`
/// puisse cacher correctement les requêtes identiques.
class PoiSearchParams {
  final String destinationKey;
  final String? query;
  final List<String>? tags;
  final PoiCategory? category;
  final bool mustSeeOnly;
  final int? limit;

  const PoiSearchParams({
    required this.destinationKey,
    this.query,
    this.tags,
    this.category,
    this.mustSeeOnly = false,
    this.limit,
  });

  @override
  bool operator ==(Object other) =>
      other is PoiSearchParams &&
      other.destinationKey == destinationKey &&
      other.query == query &&
      _listEq(other.tags, tags) &&
      other.category == category &&
      other.mustSeeOnly == mustSeeOnly &&
      other.limit == limit;

  @override
  int get hashCode => Object.hash(
        destinationKey,
        query,
        tags == null ? null : Object.hashAll(tags!),
        category,
        mustSeeOnly,
        limit,
      );

  static bool _listEq(List<String>? a, List<String>? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'PoiSearchParams($destinationKey, query=$query, tags=$tags, '
      'category=$category, mustSee=$mustSeeOnly, limit=$limit)';
}

// ─── Providers de lecture ───

/// Retourne tous les POIs de la destination [destinationKey].
final poisByDestinationProvider =
    FutureProvider.family<List<Poi>, String>(
  (ref, destinationKey) async {
    final repo = ref.watch(poiRepositoryProvider);
    return repo.listPoisByDestination(destinationKey);
  },
  name: 'poisByDestinationProvider',
);

/// Retourne le POI correspondant à [poiId], ou `null`.
final poiByIdProvider = FutureProvider.family<Poi?, String>(
  (ref, poiId) async {
    final repo = ref.watch(poiRepositoryProvider);
    return repo.getPoiById(poiId);
  },
  name: 'poiByIdProvider',
);

/// Recherche filtrée de POIs.
final poiSearchProvider =
    FutureProvider.family<List<Poi>, PoiSearchParams>(
  (ref, params) async {
    final repo = ref.watch(poiRepositoryProvider);
    return repo.searchPois(
      destinationKey: params.destinationKey,
      query: params.query,
      tags: params.tags,
      category: params.category,
      mustSeeOnly: params.mustSeeOnly,
      limit: params.limit,
    );
  },
  name: 'poiSearchProvider',
);

/// Retourne les [limit] POIs les mieux notés de la destination.
final topPoisProvider =
    FutureProvider.family<List<Poi>, ({String destinationKey, int limit})>(
  (ref, params) async {
    final repo = ref.watch(poiRepositoryProvider);
    return repo.getTopPoisForDestination(params.destinationKey, params.limit);
  },
  name: 'topPoisProvider',
);


