/// Phase 2 / Tâche 2.4 — Structure de journal pour les rejets
/// `same_complex_cap` du sélecteur déterministe.
///
/// **Class minimale, immutable**, sans logique. Sert uniquement de
/// payload de log appendé à une liste optionnelle passée par
/// `selectVisitsDeterministic`. Aucune dépendance UI, aucune
/// persistence — purement de la debug data en mémoire.
///
/// ## Quand est-elle créée ?
///
/// Uniquement quand `useSameComplexDedup == true` ET qu'un
/// candidat est rejeté parce qu'il appartient à un complexe déjà
/// saturé (cap jour ou cap voyage).
///
/// ## Reasons possibles
///
/// Constantes string publiques sous `SameComplexRejection.reason*` :
///   - `same_complex_cap_day`  : `count_jour >= max_per_day`
///   - `same_complex_cap_trip` : `count_trip >= max_per_trip`
///
/// Le `reason` est aussi loggé via `debugPrint`/`print` pour les
/// observabilités côté pipeline.
library;

/// Événement de rejet d'un candidat au cap `SameComplexGroup`.
class SameComplexRejection {
  /// Titre du candidat rejeté (`NearbyCandidate.name`).
  final String candidateTitle;

  /// `complex_key` du groupe ayant déclenché le rejet.
  final String complexKey;

  /// Raison du rejet. Voir constantes `reasonCapDay`/`reasonCapTrip`.
  final String reason;

  /// Jour concerné (raison `cap_day`) ou jour d'évaluation
  /// (raison `cap_trip`). Null toléré si le contexte ne fournit
  /// pas la date.
  final DateTime? dayDate;

  /// Compteur courant **avant** le rejet : nombre de fois où le
  /// complexe a déjà été pris (jour ou voyage, selon `reason`).
  final int currentCount;

  /// Cap configuré dans le `SameComplexGroup` (`maxPerDay` ou
  /// `maxPerTrip`).
  final int maxAllowed;

  const SameComplexRejection({
    required this.candidateTitle,
    required this.complexKey,
    required this.reason,
    required this.currentCount,
    required this.maxAllowed,
    this.dayDate,
  });

  static const String reasonCapDay = 'same_complex_cap_day';
  static const String reasonCapTrip = 'same_complex_cap_trip';

  @override
  String toString() => 'SameComplexRejection('
      'title=$candidateTitle, '
      'complex=$complexKey, '
      'reason=$reason, '
      'day=${dayDate?.toIso8601String().split("T").first ?? "?"}, '
      'count=$currentCount/$maxAllowed)';
}
