/// POI-0.7 — Implémentation [PoiRepository] via un [PoiSupabaseClient].
///
/// Read-only. Traduit les appels haut-niveau du domaine en requêtes
/// PostgREST bas-niveau via l'adapter injectable.
///
/// Aucune dépendance `supabase_flutter` directe. Le client concret
/// (live ou fake) est fourni par le caller.
library;

import '../domain/poi.dart';
import '../domain/poi_repository.dart';
import 'poi_supabase_client.dart';

/// Implémentation Supabase du contrat [PoiRepository].
class SupabasePoiRepository implements PoiRepository {
  final PoiSupabaseClient _client;

  const SupabasePoiRepository(this._client);

  @override
  Future<List<Poi>> listPoisByDestination(String destinationKey) async {
    final rows = await _client
        .from('pois')
        .select()
        .eq('destination_key', destinationKey)
        .order('editorial_score', ascending: false)
        .order('name', ascending: true)
        .execute();
    return rows.map((r) => Poi.fromJson(r)).toList();
  }

  @override
  Future<Poi?> getPoiById(String poiId) async {
    final row = await _client
        .from('pois')
        .select()
        .eq('poi_id', poiId)
        .maybeSingle();
    return row == null ? null : Poi.fromJson(row);
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
    // ─── 1. Résoudre les poi_ids candidats par recherche texte ───
    Set<String>? candidateIds;
    final normalizedQuery = _normalize(query);

    if (normalizedQuery != null) {
      final pattern = '%$normalizedQuery%';

      // a) Recherche sur name / normalized_name
      final nameRows = await _client
          .from('pois')
          .select(['poi_id'])
          .eq('destination_key', destinationKey)
          .or(
            'name.ilike.$pattern,normalized_name.ilike.$pattern',
          )
          .execute();

      // b) Recherche sur aliases
      final aliasRows = await _client
          .from('poi_aliases')
          .select(['poi_id'])
          .ilike('alias_normalized', pattern)
          .execute();

      candidateIds = {
        ...nameRows.map((r) => r['poi_id'] as String),
        ...aliasRows.map((r) => r['poi_id'] as String),
      };

      if (candidateIds.isEmpty) return [];
    }

    // ─── 2. Résoudre les poi_ids par tags (OR) ───
    if (tags != null && tags.isNotEmpty) {
      final tagRows = await _client
          .from('poi_tags')
          .select(['poi_id'])
          .inFilter('tag', tags)
          .execute();
      final tagPoiIds = tagRows.map((r) => r['poi_id'] as String).toSet();

      if (tagPoiIds.isEmpty) return [];

      if (candidateIds != null) {
        candidateIds = candidateIds.intersection(tagPoiIds);
        if (candidateIds.isEmpty) return [];
      } else {
        candidateIds = tagPoiIds;
      }
    }

    // ─── 3. Requête principale sur pois ───
    var mainQuery = _client
        .from('pois')
        .select()
        .eq('destination_key', destinationKey);

    if (category != null) {
      mainQuery = mainQuery.eq('category', category.toJsonString());
    }
    if (mustSeeOnly) {
      mainQuery = mainQuery.eq('is_must_see', true);
    }
    if (candidateIds != null) {
      mainQuery = mainQuery.inFilter('poi_id', candidateIds.toList());
    }

    final rows = await mainQuery
        .order('editorial_score', ascending: false)
        .order('name', ascending: true)
        .execute();

    var results = rows.map((r) => Poi.fromJson(r)).toList();

    // ─── 4. Limite ───
    if (limit != null && limit > 0 && results.length > limit) {
      results = results.sublist(0, limit);
    }
    return results;
  }

  // ─── Helpers ───

  static String? _normalize(String? value) {
    if (value == null) return null;
    final trimmed = value.trim().toLowerCase();
    return trimmed.isEmpty ? null : trimmed;
  }
}
