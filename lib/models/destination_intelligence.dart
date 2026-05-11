/// Phase 1 / Tâche 1.1 — Modèle de données `DestinationIntelligence`.
///
/// Schéma + validation + sérialisation JSON UNIQUEMENT. Cette tâche
/// NE migre aucune donnée existante (Singapour, etc. → Tâche 1.2)
/// et NE branche RIEN au pipeline. Le feature flag
/// `useDestinationIntelligence` reste **non consommé**.
///
/// **Vision Phase 1+** : `DestinationIntelligence` remplacera
/// conceptuellement les briques actuelles :
///   - `DestinationBlueprint` (queries mustSee/experience)
///   - `MetroProfile` (zones, anchors, blockedAddressPatterns)
///   - `segment_city_canonicals` (canonical coords)
///   - règles transport (`isMegaCity` → `transportRules`)
///   - règles frontière (`blockedAddressPatterns` → `borderSensitivity`
///     + `allowedCountryCodes` / `blockedCountryCodes`)
///
/// Pour Phase 1.1, on définit juste la **forme** des données — pas de
/// branchement, pas de migration de contenu existant. Cohérent avec
/// la règle d'or 1 (*"Ne JAMAIS casser le pipeline existant"*) et
/// la règle d'or 7 (*"Si une tâche révèle qu'une abstraction
/// générique manque, STOP et signale-le"*).
///
/// ## Convention JSON
///
/// Toutes les clés JSON sont en `snake_case` pour cohérence avec les
/// modèles existants du projet (`activity_suggestion_model.dart`,
/// `trip_model.dart` : `day_date`, `start_time`, `check_in`,
/// `activity_kind`, etc.).
///
/// ## Validation
///
/// `DestinationIntelligence.validate()` retourne `List<String>` :
///   - vide → modèle valide
///   - non vide → liste des erreurs (toutes agrégées en un appel)
///
/// Approche choisie : retour de liste plutôt que `ArgumentError`.
/// Avantages :
///   - capture toutes les erreurs d'un coup (pas seulement la première)
///   - testable sans try/catch
///   - permet à un loader de remonter plusieurs erreurs à l'admin
library;

/// Niveau de sensibilité à la frontière géographique. Drives
/// l'agressivité du filter `blockedAddressPatterns` futur (cf.
/// V8.28b1 Singapour vs Johor).
///
/// - `low`     : pays continental sans frontière problématique
///   (ex: Rome — Italie centrale, aucun pays voisin tirant le pool).
/// - `medium`  : frontière proche mais peu d'attraction touristique
///   parasite (ex: Paris à 200 km de la Belgique).
/// - `high`    : frontière critique, le geocoder ou le radius peut
///   dériver vers le pays voisin (ex: Singapour 25 km au sud de Johor
///   Bahru ; Hong Kong 30 km de Shenzhen).
enum BorderSensitivity {
  low,
  medium,
  high;

  /// Sérialise en snake_case (= valeur enum Dart, déjà lowercase).
  String toJsonString() => name;

  /// Parse une valeur JSON. Strict : valeur inconnue → FormatException.
  static BorderSensitivity fromJsonString(String raw) {
    for (final v in values) {
      if (v.name == raw) return v;
    }
    throw FormatException('Unknown BorderSensitivity value: "$raw"');
  }
}

/// Type de voyage / forme de la destination. Drives les heuristiques
/// haut-niveau (cap distance transition, structure des journées,
/// fréquence des excursions).
///
/// - `cityBreak`    : voyage court 2-4j dans une ville moyenne.
/// - `megaCity`     : mégalopole dense ≥1M habitants, transport
///   urbain dominant, journées thématiques compactes (cf. V8.28d-fix
///   cap 5 km mégacité).
/// - `island`       : île tourisme étendue, transitions plus longues
///   tolérées (cf. Bali V8.28c `isMegaCity=false`).
/// - `multiRegion`  : pays / région avec plusieurs hubs (ex: Vietnam
///   nord+sud, Maroc Marrakech+Essaouira).
/// - `historicCity` : ville moyenne à patrimoine concentré (ex: Hoi
///   An, Lisbonne).
/// - `beachResort`  : station balnéaire, journées plage dominantes
///   (ex: Koh Samet).
enum TripMode {
  cityBreak,
  megaCity,
  island,
  multiRegion,
  historicCity,
  beachResort;

  String toJsonString() => name;

  static TripMode fromJsonString(String raw) {
    for (final v in values) {
      if (v.name == raw) return v;
    }
    throw FormatException('Unknown TripMode value: "$raw"');
  }
}

/// Point géographique simple (lat/lng en degrés décimaux WGS-84).
class GeoPoint {
  final double lat;
  final double lng;

  const GeoPoint({required this.lat, required this.lng});

  /// Erreurs de validation (vide = OK).
  List<String> validate({String prefix = 'GeoPoint'}) {
    final errors = <String>[];
    if (lat < -90 || lat > 90 || lat.isNaN) {
      errors.add('$prefix.lat must be in [-90, 90], got $lat');
    }
    if (lng < -180 || lng > 180 || lng.isNaN) {
      errors.add('$prefix.lng must be in [-180, 180], got $lng');
    }
    return errors;
  }

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng};

  factory GeoPoint.fromJson(Map<String, dynamic> json) {
    final latRaw = json['lat'];
    final lngRaw = json['lng'];
    if (latRaw is! num) {
      throw const FormatException('GeoPoint.lat missing or not a number');
    }
    if (lngRaw is! num) {
      throw const FormatException('GeoPoint.lng missing or not a number');
    }
    return GeoPoint(lat: latRaw.toDouble(), lng: lngRaw.toDouble());
  }

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() => 'GeoPoint($lat, $lng)';
}

/// Zone touristique géographique au sein d'une destination. Une
/// `DestinationIntelligence` peut avoir plusieurs zones (ex: Singapour
/// = Marina Bay / Sentosa / Chinatown Civic / Orchard Botanic /
/// Kampong Glam Little India — héritage V8.28b1).
class TouristZone {
  /// Nom user-facing (ex: "Marina Bay"). Non vide.
  final String name;

  /// Centre canonique de la zone.
  final GeoPoint center;

  /// Rayon en km (> 0). Définit le périmètre logique de la zone pour
  /// le clustering / matching futur.
  final double radiusKm;

  /// Thème éditorial (ex: "waterfront_iconic", "religious_heritage").
  /// Snake_case par convention, non vide. Servira aux DayTemplates
  /// (Phase 4) pour grouper les anchors par thème de journée.
  final String theme;

  const TouristZone({
    required this.name,
    required this.center,
    required this.radiusKm,
    required this.theme,
  });

  List<String> validate({String prefix = 'TouristZone'}) {
    final errors = <String>[];
    if (name.trim().isEmpty) {
      errors.add('$prefix.name must be non-empty');
    }
    if (radiusKm <= 0 || radiusKm.isNaN) {
      errors.add('$prefix.radius_km must be > 0, got $radiusKm');
    }
    if (theme.trim().isEmpty) {
      errors.add('$prefix.theme must be non-empty');
    }
    errors.addAll(center.validate(prefix: '$prefix.center'));
    return errors;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'center': center.toJson(),
        'radius_km': radiusKm,
        'theme': theme,
      };

  factory TouristZone.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final centerRaw = json['center'];
    final radiusRaw = json['radius_km'];
    final theme = json['theme'];
    if (name is! String) {
      throw const FormatException('TouristZone.name must be a string');
    }
    if (centerRaw is! Map) {
      throw const FormatException(
          'TouristZone.center must be a GeoPoint object');
    }
    if (radiusRaw is! num) {
      throw const FormatException(
          'TouristZone.radius_km must be a number');
    }
    if (theme is! String) {
      throw const FormatException('TouristZone.theme must be a string');
    }
    return TouristZone(
      name: name,
      center: GeoPoint.fromJson(Map<String, dynamic>.from(centerRaw)),
      radiusKm: radiusRaw.toDouble(),
      theme: theme,
    );
  }
}

/// Anchor touristique d'une destination = point d'intérêt iconique
/// avec ses queries Places associées et son importance éditoriale.
///
/// Remplacera conceptuellement les `mustSeeQueries`/`experienceQueries`
/// de `DestinationBlueprint` + les `TouristAnchor` de `MetroProfile`.
/// Non branché Phase 1.1.
class DestinationAnchor {
  /// Nom user-facing (ex: "Gardens by the Bay"). Non vide.
  final String name;

  /// Queries Places à exécuter pour trouver ce lieu. Au moins une
  /// non vide. Multiple permet d'avoir des variantes linguistiques
  /// (FR/EN) ou de désambiguïsation.
  final List<String> placeQueries;

  /// Importance éditoriale 1 (anecdotique) à 5 (must-see absolu).
  /// Drives le scoring boost futur et l'ordre de priorité quand
  /// le budget API est tight.
  final int importance;

  /// Durée recommandée de visite. Stocké en `Duration` Dart-side,
  /// sérialisé en `recommended_duration_minutes` int côté JSON.
  /// Doit être > 0.
  final Duration recommendedDuration;

  const DestinationAnchor({
    required this.name,
    required this.placeQueries,
    required this.importance,
    required this.recommendedDuration,
  });

  static const int minImportance = 1;
  static const int maxImportance = 5;

  List<String> validate({String prefix = 'DestinationAnchor'}) {
    final errors = <String>[];
    if (name.trim().isEmpty) {
      errors.add('$prefix.name must be non-empty');
    }
    if (placeQueries.isEmpty ||
        placeQueries.every((q) => q.trim().isEmpty)) {
      errors.add(
          '$prefix.place_queries must have at least one non-empty query');
    }
    if (importance < minImportance || importance > maxImportance) {
      errors.add(
          '$prefix.importance must be in [$minImportance, $maxImportance], '
          'got $importance');
    }
    if (recommendedDuration.inMinutes <= 0) {
      errors.add(
          '$prefix.recommended_duration_minutes must be > 0, '
          'got ${recommendedDuration.inMinutes}');
    }
    return errors;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'place_queries': placeQueries,
        'importance': importance,
        'recommended_duration_minutes': recommendedDuration.inMinutes,
      };

  factory DestinationAnchor.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final queriesRaw = json['place_queries'];
    final importanceRaw = json['importance'];
    final durationRaw = json['recommended_duration_minutes'];
    if (name is! String) {
      throw const FormatException(
          'DestinationAnchor.name must be a string');
    }
    if (queriesRaw is! List) {
      throw const FormatException(
          'DestinationAnchor.place_queries must be a list');
    }
    if (importanceRaw is! int) {
      throw const FormatException(
          'DestinationAnchor.importance must be an int');
    }
    if (durationRaw is! int) {
      throw const FormatException(
          'DestinationAnchor.recommended_duration_minutes must be an int');
    }
    final queries = queriesRaw.whereType<String>().toList();
    return DestinationAnchor(
      name: name,
      placeQueries: queries,
      importance: importanceRaw,
      recommendedDuration: Duration(minutes: durationRaw),
    );
  }
}

/// Règles de transport propres à la destination. Drives les caps
/// distances (cf. V8.28d-fix `_kMaxTransitionMegaCityKm`) et les
/// stratégies de fan-out métro (Tokyo / Paris / Londres).
class TransportRules {
  /// Cap distance max entre 2 slots consécutifs du même jour, en km.
  /// Doit être > 0. Cohérent avec
  /// `_kMaxTransitionMegaCityKm = 5.0` (mégacité) et
  /// `_kMaxTransitionPerPackKm = 10.0` (default).
  final double maxTransitionKm;

  /// Mode de transport dominant (ex: "public_transport", "walk",
  /// "taxi", "car"). Non vide. Cohérent avec
  /// `Trip.localTransportMode`.
  final String dominantMode;

  /// `true` si la destination a un réseau de métro utilisable pour
  /// les transitions intra-zones (Tokyo, Paris, NYC, Singapour…).
  final bool hasMetro;

  /// `true` si la logique "metro anchor fan-out" (V8.28d) s'applique
  /// — searchNearby autour de chaque TouristAnchor du MetroProfile
  /// quand le geocoder dérive vers un quartier résidentiel.
  final bool hasMetroAnchorLogic;

  const TransportRules({
    required this.maxTransitionKm,
    required this.dominantMode,
    required this.hasMetro,
    required this.hasMetroAnchorLogic,
  });

  List<String> validate({String prefix = 'TransportRules'}) {
    final errors = <String>[];
    if (maxTransitionKm <= 0 || maxTransitionKm.isNaN) {
      errors.add(
          '$prefix.max_transition_km must be > 0, got $maxTransitionKm');
    }
    if (dominantMode.trim().isEmpty) {
      errors.add('$prefix.dominant_mode must be non-empty');
    }
    return errors;
  }

  Map<String, dynamic> toJson() => {
        'max_transition_km': maxTransitionKm,
        'dominant_mode': dominantMode,
        'has_metro': hasMetro,
        'has_metro_anchor_logic': hasMetroAnchorLogic,
      };

  factory TransportRules.fromJson(Map<String, dynamic> json) {
    final maxTr = json['max_transition_km'];
    final mode = json['dominant_mode'];
    final metro = json['has_metro'];
    final metroLogic = json['has_metro_anchor_logic'];
    if (maxTr is! num) {
      throw const FormatException(
          'TransportRules.max_transition_km must be a number');
    }
    if (mode is! String) {
      throw const FormatException(
          'TransportRules.dominant_mode must be a string');
    }
    if (metro is! bool) {
      throw const FormatException(
          'TransportRules.has_metro must be a bool');
    }
    if (metroLogic is! bool) {
      throw const FormatException(
          'TransportRules.has_metro_anchor_logic must be a bool');
    }
    return TransportRules(
      maxTransitionKm: maxTr.toDouble(),
      dominantMode: mode,
      hasMetro: metro,
      hasMetroAnchorLogic: metroLogic,
    );
  }
}

/// Données complètes d'une destination : centre, frontières, zones,
/// anchors, transport. Top-level model de la Phase 1.
///
/// Pas branché au pipeline en Phase 1.1. Le feature flag
/// `useDestinationIntelligence` reste OFF par défaut.
class DestinationIntelligence {
  /// Clé canonique en lowercase (ex: "singapore", "tokyo", "hoi an").
  /// Cohérent avec `DestinationBlueprint.destinationKey`. Non vide.
  final String destinationKey;

  /// Centre canonique. Drives la résolution segment_city (futur
  /// remplaçant de `segment_city_canonicals.dart`).
  final GeoPoint canonicalCenter;

  /// Code pays ISO 3166-1 (alpha-2 ou alpha-3). Non vide. Uppercase
  /// recommandé. Cohérent avec `Trip.destinationCountryCode`.
  final String countryCode;

  /// Codes pays autorisés pour les candidats à inclure dans le
  /// planning (typiquement [countryCode]). Non vide.
  final List<String> allowedCountryCodes;

  /// Codes pays / régions à bloquer explicitement même si le radius
  /// les couvre. Cas Singapour : `["MY", "ID"]` (Johor + Bintan).
  /// Peut être vide pour les destinations sans frontière sensible.
  final List<String> blockedCountryCodes;

  /// Phase 3 / Tâche 3.2 — régions, villes, quartiers, zones
  /// frontalières ou indices textuels à bloquer dans les adresses
  /// / noms des candidats. **Générique par destination** ;
  /// consommée par `ScopeValidator` quand le flag
  /// `useDestinationScope` est ON.
  ///
  /// Granularité plus fine que `blockedCountryCodes` (ISO 3166-1).
  /// Permet de bloquer :
  /// - villes voisines à l'intérieur d'un même pays bloqué
  ///   (`johor bahru`, `johor` pour Singapour) ;
  /// - villes voisines à l'intérieur d'un pays **autorisé** (cas
  ///   Dubai : émirat de Dubai vs `abu dhabi`, `sharjah`, `ajman`
  ///   tous AE) — résout le point ouvert Tâche 3.1.
  ///
  /// **Convention** : chaque entrée est une string lowercase, sans
  /// trailing whitespace, idéalement déjà normalisée façon
  /// `address.toLowerCase()`. Le matching s'effectue via
  /// `String.contains` (substring case-insensitive) — cohérent avec
  /// le filtre `isCandidateAddressBlocked` legacy de
  /// `places_first_pipeline.dart`.
  ///
  /// Default `[]` : la destination ne déclare aucune zone bloquée
  /// fine (la plupart des cas). Champ ajouté en Tâche 3.2 sans
  /// breaking change : les anciens JSON sans cette clé sont
  /// désérialisés avec une liste vide.
  final List<String> blockedNeighborRegions;

  final BorderSensitivity borderSensitivity;
  final TripMode tripMode;

  /// Zones thématiques (≥1 attendu).
  final List<TouristZone> zones;

  /// Anchors iconiques (≥1 attendu).
  final List<DestinationAnchor> anchors;

  final TransportRules transportRules;

  const DestinationIntelligence({
    required this.destinationKey,
    required this.canonicalCenter,
    required this.countryCode,
    required this.allowedCountryCodes,
    required this.blockedCountryCodes,
    required this.borderSensitivity,
    required this.tripMode,
    required this.zones,
    required this.anchors,
    required this.transportRules,
    // Phase 3 / Tâche 3.2 — default `[]` pour non-breaking sur les
    // appelants existants (Tâche 1.2 Singapour).
    this.blockedNeighborRegions = const <String>[],
  });

  /// Valide tous les champs et sous-modèles. Retourne la liste des
  /// erreurs (vide si tout est OK). Pas d'exception levée — un
  /// loader peut décider de logger, throw, ou skip selon le contexte.
  List<String> validate() {
    final errors = <String>[];
    if (destinationKey.trim().isEmpty) {
      errors.add('destination_key must be non-empty');
    }
    errors.addAll(canonicalCenter.validate(prefix: 'canonical_center'));
    if (countryCode.trim().isEmpty) {
      errors.add('country_code must be non-empty');
    }
    if (allowedCountryCodes.isEmpty) {
      errors.add('allowed_country_codes must have at least one entry');
    }
    if (zones.isEmpty) {
      errors.add('zones must have at least one entry');
    }
    if (anchors.isEmpty) {
      errors.add('anchors must have at least one entry');
    }
    for (var i = 0; i < zones.length; i++) {
      errors.addAll(zones[i].validate(prefix: 'zones[$i]'));
    }
    for (var i = 0; i < anchors.length; i++) {
      errors.addAll(anchors[i].validate(prefix: 'anchors[$i]'));
    }
    // Phase 3 / Tâche 3.2 — blockedNeighborRegions :
    //   - liste optionnelle (peut être vide) ;
    //   - aucune entrée vide après trim ;
    //   - pas de doublons après normalisation lowercase + trim.
    final seenRegions = <String>{};
    for (var i = 0; i < blockedNeighborRegions.length; i++) {
      final raw = blockedNeighborRegions[i];
      final normalized = raw.trim().toLowerCase();
      if (normalized.isEmpty) {
        errors.add('blocked_neighbor_regions[$i] must be non-empty');
        continue;
      }
      if (!seenRegions.add(normalized)) {
        errors.add(
            'blocked_neighbor_regions[$i] duplicates a previous entry '
            '("$normalized")');
      }
    }
    errors.addAll(transportRules.validate(prefix: 'transport_rules'));
    return errors;
  }

  /// True si `validate()` retourne une liste vide.
  bool get isValid => validate().isEmpty;

  Map<String, dynamic> toJson() => {
        'destination_key': destinationKey,
        'canonical_center': canonicalCenter.toJson(),
        'country_code': countryCode,
        'allowed_country_codes': allowedCountryCodes,
        'blocked_country_codes': blockedCountryCodes,
        'blocked_neighbor_regions': blockedNeighborRegions,
        'border_sensitivity': borderSensitivity.toJsonString(),
        'trip_mode': tripMode.toJsonString(),
        'zones': zones.map((z) => z.toJson()).toList(),
        'anchors': anchors.map((a) => a.toJson()).toList(),
        'transport_rules': transportRules.toJson(),
      };

  factory DestinationIntelligence.fromJson(Map<String, dynamic> json) {
    final destKey = json['destination_key'];
    if (destKey is! String) {
      throw const FormatException(
          'DestinationIntelligence.destination_key must be a string');
    }
    final centerRaw = json['canonical_center'];
    if (centerRaw is! Map) {
      throw const FormatException(
          'DestinationIntelligence.canonical_center must be an object');
    }
    final countryCode = json['country_code'];
    if (countryCode is! String) {
      throw const FormatException(
          'DestinationIntelligence.country_code must be a string');
    }
    final allowedRaw = json['allowed_country_codes'];
    if (allowedRaw is! List) {
      throw const FormatException(
          'DestinationIntelligence.allowed_country_codes must be a list');
    }
    final blockedRaw = json['blocked_country_codes'];
    final borderRaw = json['border_sensitivity'];
    if (borderRaw is! String) {
      throw const FormatException(
          'DestinationIntelligence.border_sensitivity must be a string');
    }
    final tripModeRaw = json['trip_mode'];
    if (tripModeRaw is! String) {
      throw const FormatException(
          'DestinationIntelligence.trip_mode must be a string');
    }
    final zonesRaw = json['zones'];
    if (zonesRaw is! List) {
      throw const FormatException(
          'DestinationIntelligence.zones must be a list');
    }
    final anchorsRaw = json['anchors'];
    if (anchorsRaw is! List) {
      throw const FormatException(
          'DestinationIntelligence.anchors must be a list');
    }
    final transportRaw = json['transport_rules'];
    if (transportRaw is! Map) {
      throw const FormatException(
          'DestinationIntelligence.transport_rules must be an object');
    }

    // Phase 3 / Tâche 3.2 — clé optionnelle, default `[]` pour
    // backward-compat (JSON pré-3.2 ne contient pas cette clé).
    final neighborsRaw = json['blocked_neighbor_regions'];
    return DestinationIntelligence(
      destinationKey: destKey,
      canonicalCenter:
          GeoPoint.fromJson(Map<String, dynamic>.from(centerRaw)),
      countryCode: countryCode,
      allowedCountryCodes: allowedRaw.whereType<String>().toList(),
      blockedCountryCodes: blockedRaw is List
          ? blockedRaw.whereType<String>().toList()
          : const <String>[],
      blockedNeighborRegions: neighborsRaw is List
          ? neighborsRaw.whereType<String>().toList()
          : const <String>[],
      borderSensitivity: BorderSensitivity.fromJsonString(borderRaw),
      tripMode: TripMode.fromJsonString(tripModeRaw),
      zones: zonesRaw
          .whereType<Map>()
          .map((z) => TouristZone.fromJson(Map<String, dynamic>.from(z)))
          .toList(),
      anchors: anchorsRaw
          .whereType<Map>()
          .map((a) =>
              DestinationAnchor.fromJson(Map<String, dynamic>.from(a)))
          .toList(),
      transportRules:
          TransportRules.fromJson(Map<String, dynamic>.from(transportRaw)),
    );
  }
}
