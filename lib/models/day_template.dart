/// Phase 4 / Tâche 4.1 — Modèle de données `DayTemplate`.
///
/// **Schéma + enums + validation + sérialisation JSON UNIQUEMENT.**
/// Cette tâche ne crée AUCUNE donnée Singapour (→ Tâche 4.2),
/// AUCUN assigner, AUCUN day builder template-first, et NE
/// branche RIEN au pipeline. Le feature flag `useDayTemplates`
/// reste OFF et n'est pas consommé.
///
/// ## Vision Phase 4+
///
/// Représente une journée structurée autour de :
///   - un **thème** (libellé éditorial) ;
///   - une **zone principale** (référence à `TouristZone.name` d'une
///     `DestinationIntelligence`) ;
///   - une **intensité** (`light` / `medium` / `intense`) ;
///   - des **anchors recommandés** (références à
///     `DestinationAnchor.name`) ;
///   - des **complexes interdits** (références à
///     `SameComplexGroup.complexKey`) ;
///   - une **stratégie repas** ;
///   - une **liste de slots** attendus (heure, durée, type) ;
///   - une **flexibilité** (0-100) qui modulera la souplesse du
///     futur day builder template-first vis-à-vis du template.
///
/// Remplacera conceptuellement le Day Builder greedy actuel
/// (V8.20+, `day_builder.dart`). Migration progressive : la phase
/// 4.1 pose juste la **forme** des données.
///
/// ## Convention JSON
///
/// `snake_case` pour cohérence avec `DestinationIntelligence`
/// (Tâche 1.1) et `SameComplexGroup` (Tâche 2.1). Enums sérialisés
/// via `.name` (camelCase Dart), strict-by-default sur
/// `fromJsonString` (FormatException sur valeur inconnue).
///
/// ## Validation
///
/// `validate()` retourne `List<String>` (vide = OK). Style cohérent
/// avec les autres modèles. Agrégation de toutes les erreurs en un
/// seul appel.
///
/// `validateAgainstDestination(di)` : validation croisée séparée,
/// car elle requiert une `DestinationIntelligence`. Reste découplée
/// pour permettre la validation pure du modèle sans contexte.
library;

import 'package:voyage/models/destination_intelligence.dart';

/// Intensité physique / cognitive de la journée. Drives le futur
/// pacing du day builder template-first (nombre de slots, durée
/// totale, temps de transition).
enum DayIntensity {
  /// Journée relax : ~3 slots, beaucoup de temps libre. Ex : jour
  /// d'arrivée, jour pluvieux, fin de voyage.
  light,

  /// Journée standard : ~4-5 slots, équilibre visite + transition.
  /// Default raisonnable pour la plupart des jours.
  medium,

  /// Journée chargée : ~5-6 slots, peu de temps tampon. Ex :
  /// Sentosa day complet, Old City compact.
  intense;

  String toJsonString() => name;

  static DayIntensity fromJsonString(String raw) {
    for (final v in values) {
      if (v.name == raw) return v;
    }
    throw FormatException('Unknown DayIntensity value: "$raw"');
  }
}

/// Stratégie repas du template. Drives le futur picker repas en
/// mode template-first.
enum MealStrategy {
  /// Restos sélectionnés depuis la zone principale.
  zoneRestaurants,

  /// Hawker centres / food courts (Singapour, Bangkok).
  hawkerCenters,

  /// Gastronomie haut de gamme (Tokyo, Paris, NYC).
  fineDining,

  /// Mix de plusieurs stratégies (default raisonnable).
  mixed;

  String toJsonString() => name;

  static MealStrategy fromJsonString(String raw) {
    for (final v in values) {
      if (v.name == raw) return v;
    }
    throw FormatException('Unknown MealStrategy value: "$raw"');
  }
}

/// Type attendu d'un slot. Sert au matching candidat → slot dans
/// le futur day builder template-first.
enum ExpectedSlotType {
  /// Anchor blueprint / metro anchor (must-see iconique).
  anchor,

  /// Visite culturelle / nature / shopping non iconique.
  visit,

  /// Repas (déjeuner / dîner).
  meal,

  /// Pause hôtel / promenade libre.
  rest,

  /// Transition longue (bus, métro inter-zone, ferry).
  transfer,

  /// Centre commercial / souk / market shopping.
  shopping,

  /// Point de vue panoramique (rooftop, observation deck).
  viewpoint,

  /// Show / spectacle nocturne (Wings of Time, Spectra).
  show,

  /// Plage libre, sans candidat imposé.
  freeTime;

  String toJsonString() => name;

  static ExpectedSlotType fromJsonString(String raw) {
    for (final v in values) {
      if (v.name == raw) return v;
    }
    throw FormatException('Unknown ExpectedSlotType value: "$raw"');
  }
}

/// Spécification d'un slot du template. Heure + durée + type
/// attendu. Pas de candidat assigné — c'est le day builder
/// template-first qui matchera plus tard.
class SlotSpec {
  /// Identifiant technique du slot dans le template
  /// (`morning_anchor`, `lunch`, `afternoon_visit`,
  /// `evening_show`, etc.). Non vide, snake_case recommandé.
  /// Permet de référencer un slot dans des règles futures
  /// (priorité, dépendances inter-slots).
  final String slotKey;

  /// Heure de début au format `HH:mm` 24h **strict avec leading
  /// zero** (ex: `09:00`, `13:30`, `19:45`). Cohérent avec le
  /// format de `ActivitySuggestion.startTime`.
  final String startTime;

  /// Durée nominale en minutes. > 0 et ≤ 720 (12h, garde-fou
  /// raisonnable contre un template aberrant).
  final int typicalDurationMinutes;

  /// Type attendu du slot. Drives le scoring du futur day
  /// builder template-first (anchor > visit > meal > rest).
  final ExpectedSlotType expectedType;

  const SlotSpec({
    required this.slotKey,
    required this.startTime,
    required this.typicalDurationMinutes,
    required this.expectedType,
  });

  /// Regex stricte `HH:mm` 24h. Refuse `9:00` (manque leading
  /// zero), `25:00`, `12:99`, chaîne vide.
  static final RegExp _hhmmRegExp =
      RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$');

  static const int maxTypicalDurationMinutes = 720;

  List<String> validate({String prefix = 'SlotSpec'}) {
    final errors = <String>[];
    if (slotKey.trim().isEmpty) {
      errors.add('$prefix.slot_key must be non-empty');
    } else if (slotKey != slotKey.trim() ||
        RegExp(r'\s').hasMatch(slotKey)) {
      errors.add('$prefix.slot_key must not contain whitespace, '
          'got "$slotKey"');
    }
    if (!_hhmmRegExp.hasMatch(startTime)) {
      errors.add(
          '$prefix.start_time must be HH:mm 24h format with leading '
          'zero, got "$startTime"');
    }
    if (typicalDurationMinutes <= 0) {
      errors.add('$prefix.typical_duration_minutes must be > 0, got '
          '$typicalDurationMinutes');
    } else if (typicalDurationMinutes > maxTypicalDurationMinutes) {
      errors.add('$prefix.typical_duration_minutes must be <= '
          '$maxTypicalDurationMinutes, got $typicalDurationMinutes');
    }
    return errors;
  }

  Map<String, dynamic> toJson() => {
        'slot_key': slotKey,
        'start_time': startTime,
        'typical_duration_minutes': typicalDurationMinutes,
        'expected_type': expectedType.toJsonString(),
      };

  factory SlotSpec.fromJson(Map<String, dynamic> json) {
    final slotKey = json['slot_key'];
    if (slotKey is! String) {
      throw const FormatException('SlotSpec.slot_key must be a string');
    }
    final startTime = json['start_time'];
    if (startTime is! String) {
      throw const FormatException(
          'SlotSpec.start_time must be a string');
    }
    final durationRaw = json['typical_duration_minutes'];
    if (durationRaw is! int) {
      throw const FormatException(
          'SlotSpec.typical_duration_minutes must be an int');
    }
    final typeRaw = json['expected_type'];
    if (typeRaw is! String) {
      throw const FormatException(
          'SlotSpec.expected_type must be a string');
    }
    return SlotSpec(
      slotKey: slotKey,
      startTime: startTime,
      typicalDurationMinutes: durationRaw,
      expectedType: ExpectedSlotType.fromJsonString(typeRaw),
    );
  }
}

/// Gabarit de journée thématique pour une destination. Immutable.
///
/// Identifié par `(destinationKey, templateKey)` (cf. PK SQL Tâche
/// 4.1). Cohérent avec `SameComplexGroup` (Tâche 2.1).
class DayTemplate {
  /// Identifiant technique du template, lowercase snake_case
  /// recommandé. Pas d'espaces, non vide. Ex : `marina_bay_day`,
  /// `sentosa_day`, `arrival_day`.
  final String templateKey;

  /// Destination parente. Cohérent avec
  /// `DestinationIntelligence.destinationKey` (Tâche 1.1) et
  /// `SameComplexGroup.destinationKey` (Tâche 2.1). Non vide,
  /// lowercase recommandé.
  final String destinationKey;

  /// Libellé éditorial du thème (ex: `"Marina Bay & waterfront
  /// icons"`, `"Sentosa island day"`). Non vide. Pas de format
  /// imposé — c'est un titre humain.
  final String theme;

  /// Référence textuelle à une `TouristZone.name` de la DI parente.
  /// Le matching exact n'est pas requis par `validate()` du
  /// modèle ; il est vérifié par `validateAgainstDestination(di)`
  /// quand le caller fournit la DI.
  final String primaryZoneName;

  final DayIntensity intensity;

  /// Noms / clés d'anchors à privilégier ce jour. Référence aux
  /// `DestinationAnchor.name` de la DI parente. Peut être vide
  /// (template "free day" sans anchor imposé).
  final List<String> recommendedAnchorKeys;

  /// `SameComplexGroup.complexKey` à éviter ce jour (ex:
  /// `["sentosa"]` pour un template "Marina Bay" qui ne doit
  /// pas dériver vers Sentosa). Peut être vide.
  final List<String> forbiddenComplexKeys;

  final MealStrategy mealStrategy;

  /// Liste des slots du template. ≥ 1 attendu.
  final List<SlotSpec> slots;

  /// Niveau de flexibilité 0-100 :
  ///   - 0 : template rigide (le day builder ne dévie pas).
  ///   - 50 : default raisonnable.
  ///   - 100 : très flexible (template suggestif uniquement).
  final int flexibility;

  static const int minFlexibility = 0;
  static const int maxFlexibility = 100;
  static const int defaultFlexibility = 50;

  const DayTemplate({
    required this.templateKey,
    required this.destinationKey,
    required this.theme,
    required this.primaryZoneName,
    required this.intensity,
    required this.recommendedAnchorKeys,
    required this.forbiddenComplexKeys,
    required this.mealStrategy,
    required this.slots,
    this.flexibility = defaultFlexibility,
  });

  /// Validation pure du modèle. Agrège toutes les erreurs en un
  /// appel. Cf. `validateAgainstDestination` pour la validation
  /// croisée avec une DI.
  List<String> validate() {
    final errors = <String>[];

    if (templateKey.trim().isEmpty) {
      errors.add('template_key must be non-empty');
    } else if (templateKey != templateKey.trim() ||
        RegExp(r'\s').hasMatch(templateKey)) {
      errors.add('template_key must not contain whitespace, '
          'got "$templateKey"');
    }

    if (destinationKey.trim().isEmpty) {
      errors.add('destination_key must be non-empty');
    }

    if (theme.trim().isEmpty) {
      errors.add('theme must be non-empty');
    }

    if (primaryZoneName.trim().isEmpty) {
      errors.add('primary_zone_name must be non-empty');
    }

    if (flexibility < minFlexibility || flexibility > maxFlexibility) {
      errors.add(
          'flexibility must be in [$minFlexibility, $maxFlexibility], '
          'got $flexibility');
    }

    if (slots.isEmpty) {
      errors.add('slots must have at least one entry');
    }

    for (var i = 0; i < slots.length; i++) {
      errors.addAll(slots[i].validate(prefix: 'slots[$i]'));
    }

    // Doublons recommendedAnchorKeys après normalisation simple.
    final seenAnchors = <String>{};
    for (var i = 0; i < recommendedAnchorKeys.length; i++) {
      final raw = recommendedAnchorKeys[i];
      if (raw.trim().isEmpty) {
        errors.add('recommended_anchor_keys[$i] must be non-empty');
        continue;
      }
      final norm = raw.trim().toLowerCase();
      if (!seenAnchors.add(norm)) {
        errors.add(
            'recommended_anchor_keys[$i] duplicates a previous entry '
            '("$norm")');
      }
    }

    // Doublons forbiddenComplexKeys après normalisation simple.
    final seenForbidden = <String>{};
    for (var i = 0; i < forbiddenComplexKeys.length; i++) {
      final raw = forbiddenComplexKeys[i];
      if (raw.trim().isEmpty) {
        errors.add('forbidden_complex_keys[$i] must be non-empty');
        continue;
      }
      final norm = raw.trim().toLowerCase();
      if (!seenForbidden.add(norm)) {
        errors.add(
            'forbidden_complex_keys[$i] duplicates a previous entry '
            '("$norm")');
      }
    }

    // Doublons slotKey après normalisation simple.
    final seenSlotKeys = <String>{};
    for (var i = 0; i < slots.length; i++) {
      final raw = slots[i].slotKey;
      if (raw.trim().isEmpty) continue; // déjà signalé par SlotSpec.validate
      final norm = raw.trim().toLowerCase();
      if (!seenSlotKeys.add(norm)) {
        errors.add('slots[$i].slot_key duplicates a previous slot '
            '("$norm")');
      }
    }

    return errors;
  }

  /// `true` si `validate()` retourne une liste vide.
  bool get isValid => validate().isEmpty;

  /// Validation croisée avec une `DestinationIntelligence` donnée.
  /// Vérifie :
  ///   - `destinationKey` matche `di.destinationKey`
  ///   - `primaryZoneName` existe dans `di.zones.name` (match
  ///     insensible à la casse + trim)
  ///   - chaque `recommendedAnchorKeys` matche un
  ///     `DestinationAnchor.name` (match insensible à la casse +
  ///     trim) — autorise des références "lisibles" plutôt que
  ///     des clés techniques.
  ///
  /// **Ne vérifie PAS `forbiddenComplexKeys`** : `SameComplexGroup`
  /// n'est pas dans la DI et n'est pas forcément disponible au
  /// site d'appel. Le validateur de complexes sera ajouté quand
  /// le caller fournira aussi la liste de groupes.
  List<String> validateAgainstDestination(DestinationIntelligence di) {
    final errors = <String>[];

    if (destinationKey.trim() != di.destinationKey.trim()) {
      errors.add(
          'destination_key "$destinationKey" does not match DI '
          'destinationKey "${di.destinationKey}"');
    }

    final zoneNames = di.zones
        .map((z) => z.name.trim().toLowerCase())
        .toSet();
    if (!zoneNames.contains(primaryZoneName.trim().toLowerCase())) {
      errors.add(
          'primary_zone_name "$primaryZoneName" is not a known zone '
          'in DI (zones: ${di.zones.map((z) => z.name).toList()})');
    }

    final anchorNames = di.anchors
        .map((a) => a.name.trim().toLowerCase())
        .toSet();
    for (var i = 0; i < recommendedAnchorKeys.length; i++) {
      final raw = recommendedAnchorKeys[i];
      if (raw.trim().isEmpty) continue; // déjà signalé par validate()
      if (!anchorNames.contains(raw.trim().toLowerCase())) {
        errors.add(
            'recommended_anchor_keys[$i] "$raw" is not a known anchor '
            'in DI');
      }
    }

    return errors;
  }

  Map<String, dynamic> toJson() => {
        'template_key': templateKey,
        'destination_key': destinationKey,
        'theme': theme,
        'primary_zone_name': primaryZoneName,
        'intensity': intensity.toJsonString(),
        'recommended_anchor_keys': recommendedAnchorKeys,
        'forbidden_complex_keys': forbiddenComplexKeys,
        'meal_strategy': mealStrategy.toJsonString(),
        'slots': slots.map((s) => s.toJson()).toList(),
        'flexibility': flexibility,
      };

  factory DayTemplate.fromJson(Map<String, dynamic> json) {
    final templateKey = json['template_key'];
    if (templateKey is! String) {
      throw const FormatException(
          'DayTemplate.template_key must be a string');
    }
    final destinationKey = json['destination_key'];
    if (destinationKey is! String) {
      throw const FormatException(
          'DayTemplate.destination_key must be a string');
    }
    final theme = json['theme'];
    if (theme is! String) {
      throw const FormatException('DayTemplate.theme must be a string');
    }
    final primaryZoneName = json['primary_zone_name'];
    if (primaryZoneName is! String) {
      throw const FormatException(
          'DayTemplate.primary_zone_name must be a string');
    }
    final intensityRaw = json['intensity'];
    if (intensityRaw is! String) {
      throw const FormatException(
          'DayTemplate.intensity must be a string');
    }
    final mealRaw = json['meal_strategy'];
    if (mealRaw is! String) {
      throw const FormatException(
          'DayTemplate.meal_strategy must be a string');
    }
    final slotsRaw = json['slots'];
    if (slotsRaw is! List) {
      throw const FormatException('DayTemplate.slots must be a list');
    }
    final anchorsRaw = json['recommended_anchor_keys'];
    final forbiddenRaw = json['forbidden_complex_keys'];
    final flexibilityRaw = json['flexibility'];

    return DayTemplate(
      templateKey: templateKey,
      destinationKey: destinationKey,
      theme: theme,
      primaryZoneName: primaryZoneName,
      intensity: DayIntensity.fromJsonString(intensityRaw),
      recommendedAnchorKeys: anchorsRaw is List
          ? anchorsRaw.whereType<String>().toList()
          : const <String>[],
      forbiddenComplexKeys: forbiddenRaw is List
          ? forbiddenRaw.whereType<String>().toList()
          : const <String>[],
      mealStrategy: MealStrategy.fromJsonString(mealRaw),
      slots: slotsRaw
          .whereType<Map>()
          .map((s) => SlotSpec.fromJson(Map<String, dynamic>.from(s)))
          .toList(),
      flexibility:
          flexibilityRaw is int ? flexibilityRaw : defaultFlexibility,
    );
  }
}
