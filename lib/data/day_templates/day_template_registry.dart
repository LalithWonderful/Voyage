/// Phase 4 / Tâche 4.5 — Registry **sync** des `DayTemplate`
/// connus localement, par destinationKey.
///
/// Mirror du pattern :
/// - `loadLocalComplexGroupsForDestination` (Tâche 2.4)
/// - `lookupLocalDestinationIntelligence` (Tâche 3.2)
///
/// Permet au pipeline (sync) d'obtenir la liste des templates
/// d'une destination sans passer par un loader async.
///
/// **Phase 4 livre uniquement Singapour.** Les destinations
/// suivantes (Bangkok, Tokyo, etc.) seront ajoutées par tâches
/// ultérieures sans modification du pipeline.
///
/// ## Normalisation
///
/// Lowercase + trim + first-token-before-comma + aliases courants
/// (`singapour`, `singapura`, `sg`). Cohérent avec les autres
/// registries locaux.
library;

import 'package:voyage/data/day_templates/singapore_templates.dart';
import 'package:voyage/models/day_template.dart';

/// Résout la liste des `DayTemplate` connus pour une destination
/// donnée. Retourne `[]` si la destination est null, vide, ou
/// inconnue.
///
/// Le caller (typiquement le pipeline avec flag
/// `useDayTemplates == true`) doit gérer le cas liste vide en
/// fallback sur le pipeline legacy.
List<DayTemplate> loadLocalDayTemplatesForDestination(
    String? destinationKey) {
  if (destinationKey == null) return const <DayTemplate>[];
  final firstToken = destinationKey
      .toLowerCase()
      .trim()
      .split(',')
      .first
      .trim();
  if (firstToken.isEmpty) return const <DayTemplate>[];

  // Singapour : aliases cohérents avec _normalizeBlueprintKey.
  if (firstToken == 'singapore' ||
      firstToken == 'singapour' ||
      firstToken == 'singapura' ||
      firstToken == 'sg') {
    return buildSingaporeDayTemplates();
  }

  return const <DayTemplate>[];
}
