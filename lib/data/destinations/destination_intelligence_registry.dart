/// Phase 3 / Tâche 3.2 — Registry **sync** des
/// `DestinationIntelligence` connues localement.
///
/// **Pourquoi un nouveau fichier alors que
/// `DestinationIntelligenceLoader` existe déjà (Tâche 1.3) ?**
///
/// Le loader Tâche 1.3 est **async** (renvoie `Future<DI>` avec
/// fallback graceful, cache mémoire, support remote source
/// optionnel). Le pipeline `selectVisitsDeterministic` est
/// **sync** ; câbler l'async dans cette fonction nécessiterait
/// un refactor invasif (propagation de Future sur tous les
/// callers). La spec Tâche 3.2 autorise explicitement :
///
/// > *Si l'intégration async du loader est trop invasive, ne
/// > refactore pas massivement. Dans ce cas : utiliser les
/// > données locales Singapour directement via
/// > `buildSingaporeDestinationIntelligence()` dans une petite
/// > registry ; documenter que le loader async sera branché
/// > plus tard. Mais éviter un hack Singapour dans le pipeline :
/// > la registry doit être par destinationKey.*
///
/// Ce registry est donc :
/// - **sync** (lookup direct dans une map de builders) ;
/// - **par destinationKey** (pas de hardcode Singapour dans le
///   pipeline) ;
/// - **best-effort** (retourne `null` pour destination inconnue,
///   le caller doit gérer le cas) ;
/// - **aligné** avec `defaultLocalDestinationRegistry` de
///   `destination_intelligence_loader.dart` (même map de
///   builders, mais accès sync).
///
/// Le loader Tâche 1.3 reste la source canonique pour les usages
/// async (fallback graceful, remote source, etc.). Cette registry
/// est exclusivement pour les call sites sync (pipeline runtime).
///
/// Migration future : quand le pipeline supportera `async`, ce
/// fichier pourra être supprimé et remplacé par un appel
/// `loader.load(destinationKey)`.
library;

import 'package:voyage/data/destinations/singapore.dart';
import 'package:voyage/models/destination_intelligence.dart';

/// Lookup sync de la `DestinationIntelligence` locale pour une
/// destination donnée. Retourne `null` si :
/// - `destination` null / vide / whitespace
/// - destination inconnue dans la registry locale
///
/// Le caller (typiquement le pipeline avec flag
/// `useDestinationScope == true`) DOIT gérer le cas `null` —
/// soit en court-circuitant la dédup scope, soit en utilisant
/// les `blockedAddressPatterns` legacy.
///
/// Convention de normalisation cohérente avec
/// `_normalizeBlueprintKey` (cf. `destination_blueprints.dart`)
/// et avec `loadLocalComplexGroupsForDestination` Tâche 2.4 :
/// lowercase + trim + first-token-before-comma + aliases courants.
DestinationIntelligence? lookupLocalDestinationIntelligence(
    String? destination) {
  if (destination == null) return null;
  final firstToken =
      destination.toLowerCase().trim().split(',').first.trim();
  if (firstToken.isEmpty) return null;

  // Singapour : aliases cohérents avec `_normalizeBlueprintKey`.
  if (firstToken == 'singapore' ||
      firstToken == 'singapour' ||
      firstToken == 'singapura' ||
      firstToken == 'sg') {
    return buildSingaporeDestinationIntelligence();
  }

  // Phase 3 livre uniquement Singapour. Les destinations
  // suivantes (Bangkok, Tokyo, Paris, Hong Kong, Dubai, …)
  // seront ajoutées par tâches ultérieures, sans modification
  // du sélecteur.
  return null;
}
