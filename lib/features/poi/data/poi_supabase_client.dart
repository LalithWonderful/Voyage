/// POI-0.7 — Adapter minimal injectable pour Supabase/PostgREST.
///
/// Interface pure Dart qui masque le client Supabase réel. Permet de
/// tester [SupabasePoiRepository] offline avec un fake client sans
/// importer `supabase_flutter` ni effectuer d'appels réseau.
///
/// L'API est intentionnellement proche de PostgREST (`.from()`, `.select()`,
/// `.eq()`, `.ilike()`, `.or()`, `.inFilter()`, `.order()`, `.limit()`)
/// pour que l'implémentation live soit un thin wrapper autour de
/// `supabase_flutter`.
library;

/// Client Supabase abstrait pour le domaine POI.
abstract class PoiSupabaseClient {
  /// Retourne un query builder pour la table [table].
  PoiSupabaseQuery from(String table);
}

/// Query builder PostgREST minimal pour le domaine POI.
abstract class PoiSupabaseQuery {
  /// Colonnes à sélectionner (`['*']` par défaut).
  PoiSupabaseQuery select([List<String> columns]);

  /// Filtre `column = value`.
  PoiSupabaseQuery eq(String column, dynamic value);

  /// Filtre `column ILIKE pattern` (`%` comme wildcard).
  PoiSupabaseQuery ilike(String column, String pattern);

  /// Filtre OR sous format `col.op.val,col.op.val`.
  /// Exemple : `'name.ilike.%query%,normalized_name.ilike.%query%'`.
  PoiSupabaseQuery or(String conditions);

  /// Filtre `column IN (values)`.
  PoiSupabaseQuery inFilter(String column, List<dynamic> values);

  /// Tri par colonne.
  PoiSupabaseQuery order(String column, {bool ascending = true});

  /// Limite de résultats.
  PoiSupabaseQuery limit(int count);

  /// Exécute la requête et retourne toutes les lignes.
  Future<List<Map<String, dynamic>>> execute();

  /// Exécute la requête et retourne la première ligne, ou `null`.
  Future<Map<String, dynamic>?> maybeSingle();
}
