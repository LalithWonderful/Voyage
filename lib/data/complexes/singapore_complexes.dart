/// Phase 2 / Tâche 2.2 — Données initiales Singapour pour
/// `SameComplexGroup`.
///
/// **Fichier de DONNÉES uniquement**, pas une intégration cachée. Le
/// pipeline production reste strictement intact :
/// - aucun branchement au sélecteur déterministe ;
/// - aucun matcher consommant ces groupes (Tâche 2.3) ;
/// - aucun usage du flag `useSameComplexDedup` (Tâche 2.4).
///
/// ## Rôle
///
/// Décrit les "complexes touristiques" connus de Singapour — groupes
/// d'entrées Google Places différentes mais sémantiquement le même
/// complexe pour un voyageur. Permettra à terme (Tâche 2.3 +
/// Tâche 2.4) d'éliminer les doublons sémantiques dans le sélecteur :
///
/// **Exemple concret problématique observé V8.28b1.x** :
/// dans un même jour à Singapour, le sélecteur pouvait sortir à la
/// fois `Universal Studios Singapore`, `Resorts World Sentosa` et
/// `S.E.A. Aquarium` — 3 places_id Google distincts mais 3 attractions
/// du même complexe Sentosa. La dédup `iconic` / `name_clusters`
/// existante ne les attrapait pas.
///
/// ## Source et conventions
///
/// - Source : spec Tâche 2.2 du plan de refonte ; aliases sélectionnés
///   par produit pour couvrir les noms commerciaux + variations
///   linguistiques les plus fréquentes côté Google Places.
/// - Aucun appel réseau effectué pour construire ces données.
/// - `placeIds` volontairement **vides** dans toutes les entrées
///   (cf. spec : *"La Tâche 2.3 utilisera d'abord le matching par
///   alias"*). Une enrichissement futur via résolution Google Places
///   pourra remplir `placeIds` sans changer la structure.
///
/// ## Seed local ré-importable
///
/// Ce fichier est conçu comme un seed Dart local appelable
/// directement par les tests et plus tard par le loader de complexes
/// (Tâche 2.3+) — par analogie avec
/// `lib/data/destinations/singapore.dart` (Tâche 1.2) et son
/// `buildSingaporeDestinationIntelligence()`.
///
/// ## Caps `max_per_day` / `max_per_trip` par groupe
///
/// Choix produit par groupe :
/// - `sentosa`, `gardens_by_the_bay`, `marina_bay_sands` :
///   `1/2/priority 5` — iconiques, un seul slot/jour, retour
///   possible 1× sur le voyage.
/// - `chinatown_heritage` : `2/3/priority 4` — quartier patrimonial
///   où plusieurs petits lieux (temple + heritage centre + street)
///   peuvent coexister sur la même journée.
/// - `clarke_quay_riverside`, `orchard_shopping` : `1/2/priority 3` —
///   thèmes secondaires (riverside / shopping), pas iconiques au
///   niveau Sentosa mais structurants.
library;

import 'package:voyage/models/same_complex_group.dart';

const String _kSingaporeDestinationKey = 'singapore';

/// Construit la liste des `SameComplexGroup` connus de Singapour.
///
/// Approche fonction (vs constante const) cohérente avec
/// `buildSingaporeDestinationIntelligence()` (Tâche 1.2).
///
/// Chaque groupe passe `validate()` (vérifié par les tests
/// `test/data/complexes/singapore_complexes_test.dart`).
List<SameComplexGroup> buildSingaporeSameComplexGroups() {
  return const <SameComplexGroup>[
    // ─── 1. Sentosa — île-resort iconique ─────────────────────────────
    SameComplexGroup(
      complexKey: 'sentosa',
      destinationKey: _kSingaporeDestinationKey,
      aliases: [
        'Sentosa Island',
        'Universal Studios Singapore',
        'Resorts World Sentosa',
        'Madame Tussauds Singapore',
        'Singapore Oceanarium',
        'SkyLine Luge Sentosa',
        'Wings of Time',
        'Adventure Cove Waterpark',
        'S.E.A. Aquarium',
      ],
      maxPerDay: 1,
      maxPerTrip: 2,
      priority: 5,
    ),

    // ─── 2. Gardens by the Bay — complexe horticole/architectural ─────
    SameComplexGroup(
      complexKey: 'gardens_by_the_bay',
      destinationKey: _kSingaporeDestinationKey,
      aliases: [
        'Gardens by the Bay',
        'Supertree Grove',
        'Flower Dome',
        'Cloud Forest',
        'OCBC Skyway',
        'Floral Fantasy',
      ],
      maxPerDay: 1,
      maxPerTrip: 2,
      priority: 5,
    ),

    // ─── 3. Marina Bay Sands — complexe hôtel/casino/observation ──────
    SameComplexGroup(
      complexKey: 'marina_bay_sands',
      destinationKey: _kSingaporeDestinationKey,
      aliases: [
        'Marina Bay Sands',
        'SkyPark Observation Deck',
        'ArtScience Museum',
        'Spectra Light Show',
        'The Shoppes at Marina Bay Sands',
      ],
      maxPerDay: 1,
      maxPerTrip: 2,
      priority: 5,
    ),

    // ─── 4. Chinatown Heritage — quartier patrimonial ─────────────────
    // Note : maxPerDay = 2 (contrairement aux 3 précédents) car
    // Chinatown peut légitimement accueillir plusieurs petits lieux
    // dans la même journée (temple + heritage centre + street market).
    SameComplexGroup(
      complexKey: 'chinatown_heritage',
      destinationKey: _kSingaporeDestinationKey,
      aliases: [
        'Buddha Tooth Relic Temple',
        'Chinatown Heritage Centre',
        'Sri Mariamman Temple',
        'Pagoda Street',
        'Chinatown Street Market',
      ],
      maxPerDay: 2,
      maxPerTrip: 3,
      priority: 4,
    ),

    // ─── 5. Clarke Quay & Riverside — vie nocturne / quais ────────────
    SameComplexGroup(
      complexKey: 'clarke_quay_riverside',
      destinationKey: _kSingaporeDestinationKey,
      aliases: [
        'Clarke Quay',
        'Boat Quay',
        'Robertson Quay',
      ],
      maxPerDay: 1,
      maxPerTrip: 2,
      priority: 3,
    ),

    // ─── 6. Orchard Shopping — corridor commercial ────────────────────
    SameComplexGroup(
      complexKey: 'orchard_shopping',
      destinationKey: _kSingaporeDestinationKey,
      aliases: [
        'Orchard Road',
        'ION Orchard',
        'Ngee Ann City',
        'Takashimaya',
        'Paragon',
      ],
      maxPerDay: 1,
      maxPerTrip: 2,
      priority: 3,
    ),
  ];
}
