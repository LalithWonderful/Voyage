/// Phase 4 / Tâche 4.2 — Données initiales `DayTemplate` pour
/// Singapour.
///
/// **Fichier de DONNÉES uniquement**, pas une intégration cachée.
/// Le pipeline production reste strictement intact :
/// - aucun branchement au sélecteur déterministe ;
/// - aucun consumer ;
/// - aucun usage du flag `useDayTemplates` (Phase 4.3+).
///
/// ## Rôle
///
/// Liste de 8 templates couvrant les **archétypes de journées**
/// d'un voyage Singapour standard 7-8j :
///
///   1. `arrival_day`              — atterrissage, intensité light
///   2. `marina_bay_day`           — iconique waterfront
///   3. `chinatown_civic_day`      — quartier patrimonial + civic
///   4. `sentosa_day`              — île resort, intensité intense
///   5. `orchard_botanic_day`      — parc + shopping
///   6. `little_india_kampong_day` — quartiers ethniques
///   7. `free_day`                 — journée libre
///   8. `departure_day`            — dernier jour, allégé
///
/// Les choix éditoriaux (intensité, mealStrategy, anchors
/// recommandés, complexes interdits) sont conformes à la spec
/// Tâche 4.2. Chaque template :
/// - passe `validate()` du modèle (Tâche 4.1) ;
/// - passe `validateAgainstDestination(buildSingaporeDestinationIntelligence())`
///   (zones existent, anchors existent) ;
/// - cible des `forbiddenComplexKeys` qui existent dans
///   `buildSingaporeSameComplexGroups()` (Tâche 2.2).
///
/// ## Découplage
///
/// Aucun import vers `DestinationBlueprint` / `MetroProfile` /
/// `places_first_pipeline.dart`. Le fichier ne dépend que de
/// `lib/models/day_template.dart` (Tâche 4.1). Les références
/// aux zones / anchors / complexes sont des **strings** validées
/// par les tests, pas des imports symboliques.
///
/// ## Seed local ré-importable
///
/// Par analogie avec :
///   - `buildSingaporeDestinationIntelligence()` (Tâche 1.2)
///   - `buildSingaporeSameComplexGroups()` (Tâche 2.2)
///
/// Aucun appel réseau, aucune dépendance Supabase. Une migration
/// SQL `day_templates.sql` (Tâche 4.1) attend ces données mais
/// le seed SQL n'est volontairement pas créé en 4.2 (cohérent
/// avec la convention Tâche 2.2 : option Dart-only privilégiée
/// tant que le loader runtime n'existe pas).
library;

import 'package:voyage/models/day_template.dart';

const String _kSingaporeDestinationKey = 'singapore';

/// Construit la liste des `DayTemplate` connus de Singapour.
/// Approche fonction (cohérente avec
/// `buildSingaporeDestinationIntelligence`). Retourne 8 templates.
List<DayTemplate> buildSingaporeDayTemplates() {
  return const <DayTemplate>[
    // ─── 1. arrival_day — journée d'arrivée allégée ───────────────────
    DayTemplate(
      templateKey: 'arrival_day',
      destinationKey: _kSingaporeDestinationKey,
      theme: 'Arrival day — settle in around Orchard',
      primaryZoneName: 'Orchard',
      intensity: DayIntensity.light,
      recommendedAnchorKeys: ['Orchard Road'],
      forbiddenComplexKeys: [],
      mealStrategy: MealStrategy.mixed,
      slots: [
        SlotSpec(
          slotKey: 'afternoon_soft_walk',
          startTime: '15:00',
          typicalDurationMinutes: 90,
          expectedType: ExpectedSlotType.visit,
        ),
        SlotSpec(
          slotKey: 'dinner',
          startTime: '19:00',
          typicalDurationMinutes: 90,
          expectedType: ExpectedSlotType.meal,
        ),
        SlotSpec(
          slotKey: 'evening_free_time',
          startTime: '20:30',
          typicalDurationMinutes: 60,
          expectedType: ExpectedSlotType.freeTime,
        ),
      ],
      flexibility: 80,
    ),

    // ─── 2. marina_bay_day — iconique waterfront ──────────────────────
    DayTemplate(
      templateKey: 'marina_bay_day',
      destinationKey: _kSingaporeDestinationKey,
      theme: 'Marina Bay & waterfront icons',
      primaryZoneName: 'Marina Bay',
      intensity: DayIntensity.medium,
      recommendedAnchorKeys: [
        'Gardens by the Bay',
        'Marina Bay Sands',
        'Merlion Park',
      ],
      forbiddenComplexKeys: ['sentosa'],
      mealStrategy: MealStrategy.mixed,
      slots: [
        SlotSpec(
          slotKey: 'morning_anchor',
          startTime: '09:30',
          typicalDurationMinutes: 180,
          expectedType: ExpectedSlotType.anchor,
        ),
        SlotSpec(
          slotKey: 'lunch',
          startTime: '12:30',
          typicalDurationMinutes: 90,
          expectedType: ExpectedSlotType.meal,
        ),
        SlotSpec(
          slotKey: 'afternoon_waterfront',
          startTime: '14:30',
          typicalDurationMinutes: 120,
          expectedType: ExpectedSlotType.visit,
        ),
        SlotSpec(
          slotKey: 'evening_viewpoint',
          startTime: '18:30',
          typicalDurationMinutes: 90,
          expectedType: ExpectedSlotType.viewpoint,
        ),
      ],
      flexibility: 60,
    ),

    // ─── 3. chinatown_civic_day — patrimoine + civic ──────────────────
    // Note : pas d'ArtScience Museum ici (appartient à Marina Bay).
    DayTemplate(
      templateKey: 'chinatown_civic_day',
      destinationKey: _kSingaporeDestinationKey,
      theme: 'Chinatown heritage & Civic District',
      primaryZoneName: 'Chinatown',
      intensity: DayIntensity.medium,
      recommendedAnchorKeys: [
        'Buddha Tooth Relic Temple',
        'Chinatown',
      ],
      forbiddenComplexKeys: ['sentosa', 'orchard_shopping'],
      mealStrategy: MealStrategy.hawkerCenters,
      slots: [
        SlotSpec(
          slotKey: 'morning_heritage',
          startTime: '09:30',
          typicalDurationMinutes: 120,
          expectedType: ExpectedSlotType.anchor,
        ),
        SlotSpec(
          slotKey: 'lunch_hawker',
          startTime: '12:30',
          typicalDurationMinutes: 90,
          expectedType: ExpectedSlotType.meal,
        ),
        SlotSpec(
          slotKey: 'afternoon_museum',
          startTime: '14:30',
          typicalDurationMinutes: 120,
          expectedType: ExpectedSlotType.visit,
        ),
        SlotSpec(
          slotKey: 'late_afternoon_walk',
          startTime: '17:00',
          typicalDurationMinutes: 60,
          expectedType: ExpectedSlotType.visit,
        ),
      ],
      flexibility: 65,
    ),

    // ─── 4. sentosa_day — île resort, intensive ────────────────────────
    DayTemplate(
      templateKey: 'sentosa_day',
      destinationKey: _kSingaporeDestinationKey,
      theme: 'Sentosa island day',
      primaryZoneName: 'Sentosa',
      intensity: DayIntensity.intense,
      recommendedAnchorKeys: ['Sentosa Island'],
      forbiddenComplexKeys: [
        'gardens_by_the_bay',
        'marina_bay_sands',
        'orchard_shopping',
      ],
      mealStrategy: MealStrategy.mixed,
      slots: [
        SlotSpec(
          slotKey: 'morning_sentosa_anchor',
          startTime: '09:30',
          typicalDurationMinutes: 180,
          expectedType: ExpectedSlotType.anchor,
        ),
        SlotSpec(
          slotKey: 'lunch',
          startTime: '12:30',
          typicalDurationMinutes: 90,
          expectedType: ExpectedSlotType.meal,
        ),
        SlotSpec(
          slotKey: 'afternoon_beach_or_attraction',
          startTime: '14:30',
          typicalDurationMinutes: 150,
          expectedType: ExpectedSlotType.visit,
        ),
        SlotSpec(
          slotKey: 'evening_show',
          startTime: '18:30',
          typicalDurationMinutes: 90,
          expectedType: ExpectedSlotType.show,
        ),
      ],
      flexibility: 50,
    ),

    // ─── 5. orchard_botanic_day — parc + shopping ─────────────────────
    DayTemplate(
      templateKey: 'orchard_botanic_day',
      destinationKey: _kSingaporeDestinationKey,
      theme: 'Botanic Gardens & Orchard shopping',
      primaryZoneName: 'Botanic Gardens',
      intensity: DayIntensity.medium,
      recommendedAnchorKeys: [
        'Singapore Botanic Gardens',
        'Orchard Road',
      ],
      forbiddenComplexKeys: ['sentosa', 'marina_bay_sands'],
      mealStrategy: MealStrategy.mixed,
      slots: [
        SlotSpec(
          slotKey: 'morning_garden',
          startTime: '09:00',
          typicalDurationMinutes: 150,
          expectedType: ExpectedSlotType.anchor,
        ),
        SlotSpec(
          slotKey: 'lunch',
          startTime: '12:30',
          typicalDurationMinutes: 90,
          expectedType: ExpectedSlotType.meal,
        ),
        SlotSpec(
          slotKey: 'afternoon_shopping',
          startTime: '14:30',
          typicalDurationMinutes: 150,
          expectedType: ExpectedSlotType.shopping,
        ),
        SlotSpec(
          slotKey: 'evening_free_time',
          startTime: '18:30',
          typicalDurationMinutes: 90,
          expectedType: ExpectedSlotType.freeTime,
        ),
      ],
      flexibility: 65,
    ),

    // ─── 6. little_india_kampong_day — quartiers ethniques ────────────
    DayTemplate(
      templateKey: 'little_india_kampong_day',
      destinationKey: _kSingaporeDestinationKey,
      theme: 'Kampong Glam & Little India ethnic quarters',
      primaryZoneName: 'Kampong Glam',
      intensity: DayIntensity.medium,
      recommendedAnchorKeys: [
        'Little India',
        'Kampong Glam / Arab Street',
      ],
      forbiddenComplexKeys: ['sentosa', 'marina_bay_sands'],
      mealStrategy: MealStrategy.hawkerCenters,
      slots: [
        SlotSpec(
          slotKey: 'morning_kampong_glam',
          startTime: '09:30',
          typicalDurationMinutes: 120,
          expectedType: ExpectedSlotType.visit,
        ),
        SlotSpec(
          slotKey: 'lunch_local',
          startTime: '12:30',
          typicalDurationMinutes: 90,
          expectedType: ExpectedSlotType.meal,
        ),
        SlotSpec(
          slotKey: 'afternoon_little_india',
          startTime: '14:30',
          typicalDurationMinutes: 120,
          expectedType: ExpectedSlotType.anchor,
        ),
        SlotSpec(
          slotKey: 'late_afternoon_market',
          startTime: '17:00',
          typicalDurationMinutes: 60,
          expectedType: ExpectedSlotType.visit,
        ),
      ],
      flexibility: 70,
    ),

    // ─── 7. free_day — journée volontairement allégée ─────────────────
    // Vérifie le contrat "listes vides acceptées" (bf54187).
    DayTemplate(
      templateKey: 'free_day',
      destinationKey: _kSingaporeDestinationKey,
      theme: 'Free day — unstructured exploration',
      primaryZoneName: 'Marina Bay',
      intensity: DayIntensity.light,
      recommendedAnchorKeys: [],
      forbiddenComplexKeys: [],
      mealStrategy: MealStrategy.mixed,
      slots: [
        SlotSpec(
          slotKey: 'late_morning_optional',
          startTime: '10:30',
          typicalDurationMinutes: 120,
          expectedType: ExpectedSlotType.freeTime,
        ),
        SlotSpec(
          slotKey: 'lunch',
          startTime: '12:30',
          typicalDurationMinutes: 90,
          expectedType: ExpectedSlotType.meal,
        ),
        SlotSpec(
          slotKey: 'afternoon_optional',
          startTime: '15:00',
          typicalDurationMinutes: 120,
          expectedType: ExpectedSlotType.freeTime,
        ),
      ],
      flexibility: 100,
    ),

    // ─── 8. departure_day — dernier jour allégé ───────────────────────
    DayTemplate(
      templateKey: 'departure_day',
      destinationKey: _kSingaporeDestinationKey,
      theme: 'Departure day — last walk and transfer',
      primaryZoneName: 'Orchard',
      intensity: DayIntensity.light,
      recommendedAnchorKeys: ['Orchard Road'],
      forbiddenComplexKeys: ['sentosa'],
      mealStrategy: MealStrategy.mixed,
      slots: [
        SlotSpec(
          slotKey: 'brunch',
          startTime: '10:00',
          typicalDurationMinutes: 90,
          expectedType: ExpectedSlotType.meal,
        ),
        SlotSpec(
          slotKey: 'last_walk_or_shopping',
          startTime: '11:30',
          typicalDurationMinutes: 120,
          expectedType: ExpectedSlotType.shopping,
        ),
        SlotSpec(
          slotKey: 'transfer_buffer',
          startTime: '15:00',
          typicalDurationMinutes: 90,
          expectedType: ExpectedSlotType.transfer,
        ),
      ],
      flexibility: 90,
    ),
  ];
}
