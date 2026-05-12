/// POI-0.6 — Contrat de repository POI.
///
/// Interface abstraite définissant comment l'application Lunao lit les
/// données POI. Aucune dépendance Supabase, aucun appel réseau.
///
/// L'implémentation concrète (Fake ou Supabase) est injectée par le
/// caller. Cette abstraction permet de tester la consommation des POI
/// sans infrastructure live.
///
/// ## Méthodes MVP (POI-0.6)
///
/// - [listPoisByDestination] : liste tous les POIs d'une destination.
/// - [getPoiById] : récupère un POI par son UUID.
/// - [searchPois] : recherche filtrée par nom, alias, tags, catégorie,
///   must-see, avec limite.
///
/// ## Méthodes futures (POI-0.7+)
///
/// - Lecture des aliases, tags, source links, quality flags par POI.
/// - Recherche géographique (bbox, radius).
/// - Pagination (cursor-based).
library;

import 'poi.dart';

/// Contrat de lecture pour la base de connaissances POI.
abstract class PoiRepository {
  /// Retourne tous les POIs de la destination [destinationKey].
  ///
  /// Ordre : déterministe (par score éditorial décroissant, puis nom).
  /// Destination inconnue → liste vide (pas d'exception).
  Future<List<Poi>> listPoisByDestination(String destinationKey);

  /// Retourne le POI correspondant à [poiId], ou `null` si inconnu.
  Future<Poi?> getPoiById(String poiId);

  /// Recherche filtrée de POIs.
  ///
  /// Paramètres :
  /// - [destinationKey] (requis) : destination cible.
  /// - [query] (optionnel) : chaîne recherchée dans le nom, le
  ///   normalized_name et les aliases du POI. Insensible à la casse.
  /// - [tags] (optionnel) : liste de tags ; un POI match s'il possède
  ///   au moins un des tags listés.
  /// - [category] (optionnel) : filtre par catégorie exacte.
  /// - [mustSeeOnly] (défaut `false`) : ne retourne que les must-see.
  /// - [limit] (optionnel) : nombre max de résultats.
  ///
  /// Ordre : déterministe (score éditorial décroissant, puis nom).
  /// Aucun résultat → liste vide.
  Future<List<Poi>> searchPois({
    required String destinationKey,
    String? query,
    List<String>? tags,
    PoiCategory? category,
    bool mustSeeOnly = false,
    int? limit,
  });
}
