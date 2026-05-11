/// Phase 2 / Tâche 2.3 — Détecteur de complexe `ComplexMatcher`.
///
/// **Service pur, dormant.** Identifie si un lieu (par `placeId` et/ou
/// `name`) appartient à un `SameComplexGroup`. Aucun branchement au
/// pipeline en Tâche 2.3 ; le flag `useSameComplexDedup` reste OFF
/// et n'est consommé nulle part. Sera utilisé en Tâche 2.4 dans le
/// sélecteur déterministe.
///
/// ## Signature retenue
///
/// Paramètres nommés simples plutôt qu'un wrapper `ComplexMatchPlace`
/// ad hoc :
///
/// ```dart
/// String? matchComplex({
///   String? name,
///   String? placeId,
///   required List<SameComplexGroup> groups,
/// })
/// ```
///
/// **Justification** : le projet possède bien `PlaceInfo`
/// (`lib/features/planning/services/places_service.dart`) mais c'est
/// un modèle riche (photos, reviews, opening hours…). Coupler le
/// matcher à `PlaceInfo` introduirait une dépendance lourde pour
/// deux champs (`name`, `placeId`). Une signature à 2 paramètres
/// nommés reste appelable trivialement depuis n'importe quel modèle
/// candidat (`matchComplex(name: p.name, placeId: p.placeId, …)`).
///
/// Cohérent avec règle d'or 7 (*"Étendre l'existant plutôt que
/// dupliquer"*) : on ne crée pas un faux `Place` global.
///
/// ## Ordre de matching
///
/// 1. **`placeId` exact** (case-sensitive après trim, via
///    `SameComplexGroup.containsPlaceId`).
/// 2. **`name` exact normalisé** (via `normalizeComplexText` de
///    Tâche 2.1, égalité stricte).
/// 3. **Fuzzy `name` vs aliases** (similarité > 0.85, Levenshtein
///    normalisée).
///
/// Dès qu'une étape produit un résultat, on retourne. La fall-through
/// implicite : si `placeId` est null/vide on saute l'étape 1 ; si
/// `name` est null/vide on saute les étapes 2 et 3.
///
/// ## Tie-break commun aux 3 stratégies
///
/// Si plusieurs groupes matchent à la même étape avec le même score :
///   1. **plus haute `priority`** ;
///   2. **ordre lexicographique stable** par `complexKey` (asc).
///
/// Pour l'étape 3, le tri principal est par similarité décroissante
/// (la meilleure d'abord), puis tie-break ci-dessus.
///
/// ## Seuil fuzzy
///
/// `> 0.85` (strict, pas `>= 0.85`). Spec explicite. Calibré pour :
///   - accepter une coquille ou un `s` manquant (`Universal Studio →
///     Universal Studios`, similarité ≈ 0.96) ;
///   - rejeter un substring permissif (`Bay → Marina Bay Sands`,
///     similarité ≈ 0.19).
library;

import 'package:voyage/models/same_complex_group.dart';

/// Seuil strict de similarité fuzzy. Doit être **>** ce nombre.
const double kFuzzyComplexSimilarityThreshold = 0.85;

/// Stratégie ayant produit le match — utile pour debug en Tâche 2.4
/// (logging `same_complex_cap` rejections, audit produit).
enum ComplexMatchStrategy {
  /// Match exact sur `placeId` (étape 1).
  placeId,

  /// Match exact sur `name` normalisé vs aliases (étape 2).
  exactName,

  /// Match fuzzy sur aliases (étape 3).
  fuzzyAlias,
}

/// Résultat enrichi d'un match. Renvoyé par `matchComplexDetailed`.
/// Permet le diagnostic produit (quelle stratégie ? quel alias ?
/// quelle similarité ?) sans recalcul.
class ComplexMatchResult {
  /// `complexKey` du groupe matché.
  final String complexKey;

  /// Stratégie ayant produit le match.
  final ComplexMatchStrategy strategy;

  /// Alias normalisé ayant matché. `''` quand stratégie ==
  /// `placeId` (le match est sur l'id, pas un alias).
  final String matchedAlias;

  /// Similarité ∈ [0, 1]. `1.0` pour `placeId` et `exactName`,
  /// score réel pour `fuzzyAlias`.
  final double similarity;

  /// `priority` du groupe matché (snapshot à l'instant du match —
  /// utile pour journaliser sans recalcul).
  final int priority;

  const ComplexMatchResult({
    required this.complexKey,
    required this.strategy,
    required this.matchedAlias,
    required this.similarity,
    required this.priority,
  });
}

/// Similarité normalisée entre 2 chaînes via distance de
/// Levenshtein. Plage `[0, 1]` :
///   - `1.0` = chaînes identiques (après comparaison brute, sans
///     normalisation préalable — le caller s'occupe de la
///     normalisation s'il en veut une)
///   - `0.0` = aucune lettre commune sur la longueur max
///
/// Convention pour les chaînes vides :
///   - `('', '')` → `1.0` (deux vides = identiques)
///   - `('', 'x')` ou `('x', '')` → `0.0`
///
/// Implémentation Levenshtein DP 2-lignes (O(n × m) en temps,
/// O(min(n,m)) en mémoire). Aucune dépendance externe.
double normalizedStringSimilarity(String a, String b) {
  if (a == b) return 1.0;
  if (a.isEmpty || b.isEmpty) return 0.0;
  final dist = _levenshtein(a, b);
  final maxLen = a.length >= b.length ? a.length : b.length;
  return 1.0 - dist / maxLen;
}

int _levenshtein(String a, String b) {
  // Optimisation : itérer sur la plus courte en colonnes pour
  // borner la mémoire à O(min(n, m)).
  if (a.length < b.length) {
    final tmp = a;
    a = b;
    b = tmp;
  }
  final n = a.length;
  final m = b.length;
  if (m == 0) return n;

  var previous = List<int>.generate(m + 1, (j) => j);
  final current = List<int>.filled(m + 1, 0);

  for (var i = 1; i <= n; i++) {
    current[0] = i;
    final ca = a.codeUnitAt(i - 1);
    for (var j = 1; j <= m; j++) {
      final cost = ca == b.codeUnitAt(j - 1) ? 0 : 1;
      final del = previous[j] + 1;
      final ins = current[j - 1] + 1;
      final sub = previous[j - 1] + cost;
      var best = del < ins ? del : ins;
      if (sub < best) best = sub;
      current[j] = best;
    }
    // swap
    for (var j = 0; j <= m; j++) {
      previous[j] = current[j];
    }
  }
  return previous[m];
}

/// Retourne le `complexKey` du groupe matchant `name`/`placeId`,
/// ou `null` si aucun. Cf. doc de tête pour l'ordre des étapes.
String? matchComplex({
  String? name,
  String? placeId,
  required List<SameComplexGroup> groups,
}) {
  final result = matchComplexDetailed(
    name: name,
    placeId: placeId,
    groups: groups,
  );
  return result?.complexKey;
}

/// Variante détaillée : retourne le résultat enrichi
/// (`ComplexMatchResult`) ou `null`.
ComplexMatchResult? matchComplexDetailed({
  String? name,
  String? placeId,
  required List<SameComplexGroup> groups,
}) {
  if (groups.isEmpty) return null;

  // ── 1. Match placeId exact ────────────────────────────────────────
  final trimmedPlaceId = placeId?.trim() ?? '';
  if (trimmedPlaceId.isNotEmpty) {
    final candidates =
        groups.where((g) => g.containsPlaceId(trimmedPlaceId)).toList();
    if (candidates.isNotEmpty) {
      final winner = _pickByPriorityThenKey(candidates);
      return ComplexMatchResult(
        complexKey: winner.complexKey,
        strategy: ComplexMatchStrategy.placeId,
        matchedAlias: '',
        similarity: 1.0,
        priority: winner.priority,
      );
    }
  }

  // ── 2-3. Étapes basées sur `name` ─────────────────────────────────
  final trimmedName = name?.trim() ?? '';
  if (trimmedName.isEmpty) return null;
  final normalizedName = normalizeComplexText(trimmedName);
  if (normalizedName.isEmpty) return null;

  // ── 2. Match exact normalisé ──────────────────────────────────────
  final exactCandidates = <_MatchAttempt>[];
  for (final g in groups) {
    for (final alias in g.aliases) {
      final na = normalizeComplexText(alias);
      if (na.isEmpty) continue; // défense : alias vide après
      // normalisation (théoriquement bloqué par validate(), mais le
      // matcher reste défensif).
      if (na == normalizedName) {
        exactCandidates.add(_MatchAttempt(g, na, 1.0));
      }
    }
  }
  if (exactCandidates.isNotEmpty) {
    final winner = _pickBestExact(exactCandidates);
    return ComplexMatchResult(
      complexKey: winner.group.complexKey,
      strategy: ComplexMatchStrategy.exactName,
      matchedAlias: winner.matchedAlias,
      similarity: 1.0,
      priority: winner.group.priority,
    );
  }

  // ── 3. Match fuzzy ────────────────────────────────────────────────
  final fuzzyCandidates = <_MatchAttempt>[];
  for (final g in groups) {
    for (final alias in g.aliases) {
      final na = normalizeComplexText(alias);
      if (na.isEmpty) continue;
      final sim = normalizedStringSimilarity(na, normalizedName);
      if (sim > kFuzzyComplexSimilarityThreshold) {
        fuzzyCandidates.add(_MatchAttempt(g, na, sim));
      }
    }
  }
  if (fuzzyCandidates.isEmpty) return null;

  final winner = _pickBestFuzzy(fuzzyCandidates);
  return ComplexMatchResult(
    complexKey: winner.group.complexKey,
    strategy: ComplexMatchStrategy.fuzzyAlias,
    matchedAlias: winner.matchedAlias,
    similarity: winner.similarity,
    priority: winner.group.priority,
  );
}

// ─── Helpers privés de tie-break ──────────────────────────────────────

class _MatchAttempt {
  final SameComplexGroup group;
  final String matchedAlias;
  final double similarity;
  const _MatchAttempt(this.group, this.matchedAlias, this.similarity);
}

/// Tri pour placeId : priority desc, puis complexKey asc.
SameComplexGroup _pickByPriorityThenKey(List<SameComplexGroup> list) {
  final sorted = [...list]..sort((a, b) {
      final p = b.priority.compareTo(a.priority);
      if (p != 0) return p;
      return a.complexKey.compareTo(b.complexKey);
    });
  return sorted.first;
}

/// Tri pour exact (similarité toujours 1.0) : priority desc, puis
/// complexKey asc.
_MatchAttempt _pickBestExact(List<_MatchAttempt> list) {
  final sorted = [...list]..sort((a, b) {
      final p = b.group.priority.compareTo(a.group.priority);
      if (p != 0) return p;
      return a.group.complexKey.compareTo(b.group.complexKey);
    });
  return sorted.first;
}

/// Tri pour fuzzy : similarité desc, puis priority desc, puis
/// complexKey asc.
_MatchAttempt _pickBestFuzzy(List<_MatchAttempt> list) {
  final sorted = [...list]..sort((a, b) {
      final s = b.similarity.compareTo(a.similarity);
      if (s != 0) return s;
      final p = b.group.priority.compareTo(a.group.priority);
      if (p != 0) return p;
      return a.group.complexKey.compareTo(b.group.complexKey);
    });
  return sorted.first;
}
