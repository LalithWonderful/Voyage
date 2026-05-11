/// Phase 2 / Tâche 2.4 — Registry minimale de complexes par
/// destination.
///
/// **Service pur, dormant** (consommé uniquement quand le flag
/// `useSameComplexDedup` est ON). Aucun appel réseau. Aucune
/// dépendance Supabase. Sert de pont entre `trip.destination`
/// (raw user-facing) et la liste de `SameComplexGroup` connue
/// pour cette destination.
///
/// ## Rôle
///
/// Le sélecteur déterministe ne doit pas hardcoder
/// `buildSingaporeSameComplexGroups()` ; il appelle cette fonction
/// avec `trip.destination` et reçoit la liste correspondante (ou
/// `[]` si destination inconnue).
///
/// **Phase 2 livre uniquement Singapour.** Les destinations
/// suivantes seront ajoutées par tâches ultérieures, sans avoir
/// besoin de modifier le sélecteur.
///
/// ## Normalisation
///
/// Cohérente avec `_normalizeBlueprintKey` de
/// `lib/features/planning/data/destination_blueprints.dart` :
///   - lowercase + trim
///   - premier token avant virgule
///   - aliases `singapour`, `singapura`, `sg` reconnus
///
/// Pas de normalisation lourde (accents Vietnamese, etc.) — la
/// Tâche 2.4 cible Singapour. Étendre au besoin.
library;

import 'package:voyage/data/complexes/singapore_complexes.dart';
import 'package:voyage/models/same_complex_group.dart';

/// Résout la liste des `SameComplexGroup` connus pour une
/// destination donnée. Retourne `[]` si la destination est null,
/// vide, ou inconnue.
///
/// Le sélecteur peut appeler cette fonction systématiquement —
/// si aucun groupe n'est connu, aucune dédup complexe ne
/// s'applique (comportement identique au flag OFF).
List<SameComplexGroup> loadLocalComplexGroupsForDestination(
    String? destination) {
  if (destination == null) return const <SameComplexGroup>[];
  final firstToken =
      destination.toLowerCase().trim().split(',').first.trim();
  if (firstToken.isEmpty) return const <SameComplexGroup>[];

  // Singapour : aliases cohérents avec `_normalizeBlueprintKey`.
  if (firstToken == 'singapore' ||
      firstToken == 'singapour' ||
      firstToken == 'singapura' ||
      firstToken == 'sg') {
    return buildSingaporeSameComplexGroups();
  }

  return const <SameComplexGroup>[];
}
