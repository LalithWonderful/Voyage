/// Phase 3 / Tâche 3.1 — Service de validation de scope géographique.
///
/// **Service pur, dormant.** Vérifie si un lieu candidat appartient
/// au périmètre géographique d'une `DestinationIntelligence`.
/// Aucun branchement runtime au pipeline en Tâche 3.1 ; le flag
/// `useDestinationScope` reste OFF et n'est consommé nulle part.
///
/// Sera consommé en Tâche 3.2 (intégration sélecteur derrière flag)
/// puis 3.3 (tests cross-destinations). À terme, remplacera la
/// logique `blockedAddressPatterns` hardcodée par destination dans
/// le pipeline.
///
/// ## Signature retenue
///
/// ```dart
/// ScopeValidationResult validatePlaceInScope(
///   ScopeValidationPlace place,
///   DestinationIntelligence di,
/// )
/// ```
///
/// `ScopeValidationPlace` est un **adapter local** (cf. ci-dessous)
/// — pas de couplage à `PlaceInfo` riche ou `NearbyCandidate`.
/// Cohérent avec règle d'or 7 et avec le pattern Tâche 2.3
/// (`complex_matcher.dart` : paramètres nommés simples).
///
/// ## Stratégie de validation
///
/// Ordre des vérifications :
///
///   1. **`countryCode` explicite** (preuve forte) :
///      - normalisation uppercase
///      - blocked (priorité défensive) → reject `blockedCountry`, HIGH
///      - allowed → accept HIGH
///      - sinon → reject `outOfCountry`, HIGH
///
///   2. **Fallback `address`** (preuve heuristique) :
///      - normalisation lowercase + whitespace
///      - match contre les hints (table `_kCountryHints`)
///      - hint d'un pays bloqué → reject (`blockedCountry` ou
///        `blockedNeighborRegion`), MEDIUM
///      - hint d'un pays autorisé → accept MEDIUM
///
///   3. **Aucune preuve** :
///      - accept avec confidence LOW (cf. spec : "Ne pas rejeter
///        arbitrairement un lieu uniquement parce que la destination
///        est high sensitivity et que le countryCode manque").
///      - `borderSensitivity` est informationnel ; ne déclenche pas
///        de rejet sans preuve concrète.
///
/// ## Pourquoi pas de rejet agressif par border sensitivity ?
///
/// Beaucoup de candidats Google Places ont `countryCode` null /
/// adresse approximative. Rejeter chacun de ces candidats sur une
/// destination high-sensitivity exclurait des dizaines de vrais
/// lieux Singapour qui n'ont pas de countryCode fiable côté
/// Places. L'approche défensive est : laisser passer en LOW, et
/// laisser le caller (pipeline futur Tâche 3.2) appliquer un
/// downscoring softer plutôt qu'un hard reject.
///
/// ## Table de hints `_kCountryHints`
///
/// **Heuristique provisoire** (Tâche 3.1) : map `country_code →
/// liste de substring lowercase` pour matcher les adresses sans
/// `countryCode` explicite. Couvre les destinations utilisées
/// dans les tests + leurs voisines bloquées.
///
/// **Limites connues** :
/// - false positives (`Johor Park, Singapore` → match `johor` →
///   classifié à tort MY) — comportement déjà observé avec
///   `blockedAddressPatterns` legacy ; pas une régression.
/// - vocabulaire fini → ne couvre pas toutes les destinations.
///
/// **Évolution prévue** : remplacer cette table statique par une
/// extraction dynamique depuis `DestinationIntelligence` (champ
/// `blockedNeighborRegions` à ajouter en Tâche 3.2/3.3 si une
/// abstraction générique se révèle nécessaire). Aucune
/// modification de `DestinationIntelligence` en 3.1.
library;

import 'package:voyage/models/destination_intelligence.dart';

// ─── Modèles ──────────────────────────────────────────────────────────

/// Adapter local minimal pour le validator. Évite tout couplage à
/// `PlaceInfo` (Google Places) ou `NearbyCandidate` (pipeline).
/// Le caller construit cette structure à partir de son modèle.
class ScopeValidationPlace {
  /// Nom user-facing du lieu, facultatif.
  final String? name;

  /// Adresse complète (typiquement `formattedAddress` Google) —
  /// utilisée en fallback quand `countryCode` est absent.
  final String? address;

  /// Code pays ISO 3166-1 alpha-2 si connu. Normalisé uppercase
  /// par le validator. Quand disponible, **preuve forte** —
  /// court-circuite le fallback adresse.
  final String? countryCode;

  /// Coordonnées WGS-84. Non utilisées en 3.1 (réservées pour
  /// extensions futures : check vs `di.canonicalCenter` + radius,
  /// matching par zone, etc.).
  final double? lat;
  final double? lng;

  const ScopeValidationPlace({
    this.name,
    this.address,
    this.countryCode,
    this.lat,
    this.lng,
  });
}

/// Raisons de rejet possibles. `null` si accept.
enum ScopeRejectionReason {
  /// `countryCode` explicite ne figure ni dans `allowed` ni dans
  /// `blocked` (typiquement un pays tiers non lié à la destination).
  outOfCountry,

  /// `countryCode` explicite figure dans `blockedCountryCodes` de
  /// la destination (ex: Singapour + MY).
  blockedCountry,

  /// Adresse contient un hint pointant vers un pays / région
  /// bloqué (ex: "Johor Bahru" dans une adresse Singapour).
  /// Sémantiquement plus précis que `blockedCountry` pour les
  /// matchs par adresse — utile pour les futurs logs / metrics.
  blockedNeighborRegion,

  /// Pas encore utilisé en Tâche 3.1 ; réservé pour le cas où
  /// `countryCode` est présent mais inconnu / mal formé. Pour
  /// l'instant ces cas tombent en `outOfCountry`.
  unknownCountry,
}

/// Confiance du verdict.
enum ScopeConfidence {
  /// Aucune preuve concrète (ni `countryCode`, ni adresse
  /// reconnaissable). Le verdict est un default safe.
  low,

  /// Match heuristique (adresse contient un hint connu).
  medium,

  /// `countryCode` explicite renseigné (ISO 3166-1 alpha-2).
  high,
}

/// Résultat structuré d'une validation.
class ScopeValidationResult {
  /// `true` si le lieu est considéré dans le scope de la destination.
  final bool isInScope;

  /// Raison du rejet si `!isInScope`, sinon `null`.
  final ScopeRejectionReason? rejectionReason;

  /// Niveau de confiance du verdict (cf. enum).
  final ScopeConfidence confidence;

  /// Indice ayant déclenché le verdict (string court, debug-friendly).
  /// Exemples : `"SG"` (countryCode), `"johor bahru"` (address hint),
  /// `null` si default safe.
  final String? matchedEvidence;

  const ScopeValidationResult({
    required this.isInScope,
    this.rejectionReason,
    required this.confidence,
    this.matchedEvidence,
  });

  @override
  String toString() => 'ScopeValidationResult('
      'isInScope=$isInScope, '
      'reason=${rejectionReason?.name ?? "none"}, '
      'confidence=${confidence.name}, '
      'evidence=$matchedEvidence)';
}

// ─── Table de hints (heuristique provisoire) ──────────────────────────

/// Cf. doc de tête. Substrings lowercase à matcher dans une adresse.
const Map<String, List<String>> _kCountryHints = {
  'SG': ['singapore'],
  'MY': ['malaysia', 'johor bahru', 'johor', 'kuala lumpur'],
  'ID': ['indonesia', 'bintan', 'batam'],
  'CN': ['china', 'shenzhen', 'guangdong'],
  'AE': ['united arab emirates', 'dubai', 'abu dhabi', 'sharjah', 'ajman'],
  'IT': ['italy', 'rome', 'roma'],
  'VA': ['vatican', 'vatican city'],
  'TH': ['thailand', 'bangkok'],
  'JP': ['japan', 'tokyo'],
  'FR': ['france', 'paris'],
  'HK': ['hong kong', 'hongkong'],
};

// ─── API publique ─────────────────────────────────────────────────────

/// Valide qu'un lieu appartient au périmètre géographique d'une
/// `DestinationIntelligence`. Cf. doc de tête pour la stratégie.
ScopeValidationResult validatePlaceInScope(
  ScopeValidationPlace place,
  DestinationIntelligence di,
) {
  // ── 1. countryCode explicite (preuve forte) ───────────────────────
  final rawCode = place.countryCode?.trim();
  if (rawCode != null && rawCode.isNotEmpty) {
    final code = rawCode.toUpperCase();
    final blocked = di.blockedCountryCodes
        .map((c) => c.toUpperCase().trim())
        .toSet();
    final allowed = di.allowedCountryCodes
        .map((c) => c.toUpperCase().trim())
        .toSet();
    if (blocked.contains(code)) {
      return ScopeValidationResult(
        isInScope: false,
        rejectionReason: ScopeRejectionReason.blockedCountry,
        confidence: ScopeConfidence.high,
        matchedEvidence: code,
      );
    }
    if (allowed.contains(code)) {
      return ScopeValidationResult(
        isInScope: true,
        confidence: ScopeConfidence.high,
        matchedEvidence: code,
      );
    }
    // Code explicite mais ni allowed ni blocked → out_of_country.
    return ScopeValidationResult(
      isInScope: false,
      rejectionReason: ScopeRejectionReason.outOfCountry,
      confidence: ScopeConfidence.high,
      matchedEvidence: code,
    );
  }

  // ── 2. Fallback adresse (preuve heuristique) ──────────────────────
  final rawAddress = place.address?.trim();
  if (rawAddress != null && rawAddress.isNotEmpty) {
    final normalized = rawAddress.toLowerCase().replaceAll(
        RegExp(r'\s+'), ' ');
    final blocked = di.blockedCountryCodes
        .map((c) => c.toUpperCase().trim())
        .toSet();
    final allowed = di.allowedCountryCodes
        .map((c) => c.toUpperCase().trim())
        .toSet();

    // Vérification blocked en priorité défensive.
    for (final code in blocked) {
      final hints = _kCountryHints[code] ?? const <String>[];
      for (final hint in hints) {
        if (normalized.contains(hint)) {
          return ScopeValidationResult(
            isInScope: false,
            // `blockedNeighborRegion` est sémantiquement plus
            // précis pour les matchs adresse (vs `blockedCountry`
            // réservé aux countryCode explicite).
            rejectionReason:
                ScopeRejectionReason.blockedNeighborRegion,
            confidence: ScopeConfidence.medium,
            matchedEvidence: hint,
          );
        }
      }
    }
    // Vérification allowed (preuve heuristique d'appartenance).
    for (final code in allowed) {
      final hints = _kCountryHints[code] ?? const <String>[];
      for (final hint in hints) {
        if (normalized.contains(hint)) {
          return ScopeValidationResult(
            isInScope: true,
            confidence: ScopeConfidence.medium,
            matchedEvidence: hint,
          );
        }
      }
    }
  }

  // ── 3. Aucune preuve concrète ─────────────────────────────────────
  // Default safe : accept en LOW (cf. doc de tête).
  // `borderSensitivity` ne change pas le verdict — uniquement la
  // confidence reportée reste LOW pour signaler au caller futur
  // qu'un downscoring soft est approprié sur destinations
  // high-sensitivity.
  return ScopeValidationResult(
    isInScope: true,
    confidence: ScopeConfidence.low,
    matchedEvidence: null,
  );
}
