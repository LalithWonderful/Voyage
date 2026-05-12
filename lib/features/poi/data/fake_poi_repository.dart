/// POI-0.6 — Implémentation fake offline du contrat [PoiRepository].
///
/// Stockage 100 % en mémoire, injecté via le constructeur. Aucun appel
/// réseau, aucune base de données, aucun fichier.
///
/// Les jointures POI ↔ aliases ↔ tags sont résolues en mémoire par
/// scan linéaire (acceptable pour les jeux de test et les fixtures).
///
/// Usage typique :
/// ```dart
/// final repo = FakePoiRepository(
///   pois: singaporePois,
///   aliases: singaporeAliases,
///   tags: singaporeTags,
/// );
/// final results = await repo.searchPois(
///   destinationKey: 'singapore',
///   query: 'gardens',
/// );
/// ```
library;

import '../domain/poi.dart';
import '../domain/poi_alias.dart';
import '../domain/poi_repository.dart';
import '../domain/poi_tag.dart';

/// Repository fake offline basé sur des listes en mémoire.
class FakePoiRepository implements PoiRepository {
  final List<Poi> _pois;
  final List<PoiAlias> _aliases;
  final List<PoiTag> _tags;

  const FakePoiRepository({
    List<Poi> pois = const [],
    List<PoiAlias> aliases = const [],
    List<PoiTag> tags = const [],
  })  : _pois = pois,
        _aliases = aliases,
        _tags = tags;

  // ─── PoiRepository ───

  @override
  Future<List<Poi>> listPoisByDestination(String destinationKey) async {
    final matched = _pois
        .where((p) => p.destinationKey == destinationKey)
        .toList(growable: false);
    _sortPois(matched);
    return matched;
  }

  @override
  Future<Poi?> getPoiById(String poiId) async {
    for (final p in _pois) {
      if (p.poiId == poiId) return p;
    }
    return null;
  }

  @override
  Future<List<Poi>> getTopPoisForDestination(
    String destinationKey,
    int limit,
  ) async {
    final matched = _pois
        .where((p) => p.destinationKey == destinationKey)
        .toList(growable: false);
    _sortPois(matched);
    if (limit > 0 && matched.length > limit) {
      return matched.sublist(0, limit);
    }
    return matched;
  }

  @override
  Future<List<Poi>> getPoisByCategories(
    String destinationKey,
    List<PoiCategory> categories,
  ) async {
    if (categories.isEmpty) return [];
    final categorySet = categories.toSet();
    final matched = _pois
        .where((p) =>
            p.destinationKey == destinationKey && categorySet.contains(p.category))
        .toList(growable: false);
    _sortPois(matched);
    return matched;
  }

  @override
  Future<List<Poi>> searchPois({
    required String destinationKey,
    String? query,
    List<String>? tags,
    PoiCategory? category,
    bool mustSeeOnly = false,
    int? limit,
  }) async {
    // 1. Filtrage destination
    var candidates = _pois.where((p) => p.destinationKey == destinationKey);

    // 2. Filtrage query (nom + aliases)
    final normalizedQuery = _normalize(query);
    if (normalizedQuery != null && normalizedQuery.isNotEmpty) {
      // Pré-indexer les poiIds qui matchent par alias
      final aliasMatches = <String>{};
      for (final a in _aliases) {
        if (a.aliasNormalized.contains(normalizedQuery) ||
            a.alias.toLowerCase().contains(normalizedQuery)) {
          aliasMatches.add(a.poiId);
        }
      }

      candidates = candidates.where((p) {
        if (p.normalizedName.contains(normalizedQuery)) return true;
        if (p.name.toLowerCase().contains(normalizedQuery)) return true;
        if (aliasMatches.contains(p.poiId)) return true;
        return false;
      });
    }

    // 3. Filtrage tags (OR sur la liste)
    if (tags != null && tags.isNotEmpty) {
      final normalizedTags = tags.map((t) => t.toLowerCase().trim()).toSet();
      final poiIdsWithMatchingTags = <String>{};
      for (final t in _tags) {
        if (normalizedTags.contains(t.tag.toLowerCase().trim())) {
          poiIdsWithMatchingTags.add(t.poiId);
        }
      }
      candidates = candidates.where((p) => poiIdsWithMatchingTags.contains(p.poiId));
    }

    // 4. Filtrage catégorie
    if (category != null) {
      candidates = candidates.where((p) => p.category == category);
    }

    // 5. Filtrage must-see
    if (mustSeeOnly) {
      candidates = candidates.where((p) => p.isMustSee);
    }

    // 6. Matérialisation + tri déterministe
    final result = candidates.toList(growable: false);
    _sortPois(result);

    // 7. Limite
    if (limit != null && limit > 0 && result.length > limit) {
      return result.sublist(0, limit);
    }
    return result;
  }

  // ─── Helpers internes ───

  /// Trie les POIs par score éditorial décroissant (nulls en dernier),
  /// puis par nom croissant. Ordre strictement déterministe.
  static void _sortPois(List<Poi> pois) {
    pois.sort((a, b) {
      final scoreA = a.editorialScore ?? -1;
      final scoreB = b.editorialScore ?? -1;
      final scoreCmp = scoreB.compareTo(scoreA);
      if (scoreCmp != 0) return scoreCmp;
      return a.name.compareTo(b.name);
    });
  }

  /// Normalise une chaîne de recherche : lower-case, trim.
  /// Retourne `null` si l'entrée est null ou vide après trim.
  static String? _normalize(String? value) {
    if (value == null) return null;
    final trimmed = value.trim().toLowerCase();
    return trimmed.isEmpty ? null : trimmed;
  }
}
